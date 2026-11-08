//! Bounded vertical screenshot stitching. The caller owns capture and scrolling.
mod calibration;
mod png;
use calibration::{CalibratedSession, ContentRect};

use std::ffi::{CStr, c_char};
use std::fs::{self, File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{Duration, Instant};

const MAX_WIDTH: usize = 4096;
const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;
const MAX_PIXELS: usize = 100_000_000;
const MAX_DURATION: Duration = Duration::from_secs(120);
static NEXT_ID: AtomicU64 = AtomicU64::new(0);
type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Progress {
    pub width: u32,
    pub height: u32,
    /// 0 accepted, 1 unchanged, 2 reconnect required, 3 limit reached.
    pub disposition: i32,
}

struct Frame {
    pixels: Vec<u8>,
    signature: Vec<u8>,
    width: usize,
    height: usize,
}

impl Frame {
    fn from_view(view: &FrameView<'_>, signature: Vec<u8>) -> Self {
        let mut pixels = Vec::with_capacity(view.width * view.height * 4);
        for row in 0..view.height {
            pixels.extend_from_slice(view.row(row));
        }
        Self {
            pixels,
            signature,
            width: view.width,
            height: view.height,
        }
    }
    fn view(&self) -> FrameView<'_> {
        FrameView {
            bytes: &self.pixels,
            width: self.width,
            height: self.height,
            stride: self.width * 4,
        }
    }
}

struct FrameView<'a> {
    bytes: &'a [u8],
    width: usize,
    height: usize,
    stride: usize,
}

impl<'a> FrameView<'a> {
    fn new(bytes: &'a [u8], width: usize, height: usize, stride: usize) -> Result<Self> {
        if !(16..=MAX_WIDTH).contains(&width) || !(32..=8192).contains(&height) {
            return Err("Select a region 16–4096 pixels wide and at least 32 pixels tall.".into());
        }
        let row = width.checked_mul(4).ok_or("Invalid pixel width.")?;
        let tight_size = row.checked_mul(height).ok_or("Invalid frame size.")?;
        if tight_size > MAX_FRAME_BYTES {
            return Err("This region is too large for scrolling capture. Select a smaller region (maximum 32 MiB per frame).".into());
        }
        if stride < row {
            return Err("The frame row stride is shorter than its width.".into());
        }
        let required = stride
            .checked_mul(height - 1)
            .and_then(|v| v.checked_add(row))
            .ok_or("Invalid frame stride.")?;
        if required > bytes.len() {
            return Err("The frame data is incomplete.".into());
        }
        Ok(Self {
            bytes,
            width,
            height,
            stride,
        })
    }
    fn row(&self, y: usize) -> &[u8] {
        &self.bytes[y * self.stride..y * self.stride + self.width * 4]
    }
    fn signature(&self) -> Vec<u8> {
        let mut result = Vec::with_capacity(self.height * 32);
        for y in 0..self.height {
            let row = self.row(y);
            for x in sample_columns(self.width) {
                let p = &row[x * 4..x * 4 + 4];
                result.push(((29 * p[0] as u32 + 150 * p[1] as u32 + 77 * p[2] as u32) >> 8) as u8);
            }
        }
        result
    }
}

fn sample_columns(width: usize) -> impl Iterator<Item = usize> {
    // Avoid scrollbars at the extreme edges, but inspect most of the content.
    (0..32).map(move |i| (width * (5 * 31 + i * 90) / (100 * 31)).min(width - 1))
}

fn signature_error(a: &[u8], b: &[u8], shift: usize, height: usize, coarse: bool) -> f64 {
    let overlap = height - shift;
    let count = if coarse { 24.min(overlap) } else { overlap };
    let mut sum = 0u64;
    for r in 0..count {
        let y = if coarse {
            r * (overlap - 1) / (count - 1).max(1)
        } else {
            r
        };
        for x in 0..32 {
            sum += a[(y + shift) * 32 + x].abs_diff(b[y * 32 + x]) as u64;
        }
    }
    sum as f64 / (count * 32) as f64
}

fn pixel_match(a: FrameView<'_>, b: &FrameView<'_>, shift: usize) -> bool {
    let overlap = a.height - shift;
    let rows = 64.min(overlap);
    let mut differences = 0u64;
    let mut mismatches = 0usize;
    let mut samples = 0usize;
    let mut informative = [0usize; 3];
    for r in 0..rows {
        let y = r * (overlap - 1) / (rows - 1).max(1);
        let ar = a.row(y + shift);
        let br = b.row(y);
        for x in sample_columns(a.width) {
            let p = x * 4;
            let diff: u32 = (0..3).map(|c| ar[p + c].abs_diff(br[p + c]) as u32).sum();
            differences += diff as u64;
            mismatches += usize::from(diff > 36);
            samples += 1;
            let neighbor = ((x + 1).min(a.width - 1)) * 4;
            let edge: u32 = (0..3)
                .map(|c| ar[p + c].abs_diff(ar[neighbor + c]) as u32)
                .sum();
            let vertical_edge = if y + shift + 1 < a.height {
                let next = a.row(y + shift + 1);
                (0..3).map(|c| ar[p + c].abs_diff(next[p + c]) as u32).sum()
            } else {
                0
            };
            if edge.max(vertical_edge) > 24 {
                informative[(r * 3 / rows).min(2)] += 1;
            }
        }
    }
    differences as f64 / (samples * 3) as f64 <= 2.5
        && mismatches * 100 <= samples * 2
        && informative.iter().all(|count| *count >= 3)
}

/// Returns only a forward displacement supported by a unique image match.
fn displacement(previous: &Frame, next: &FrameView<'_>, signature: &[u8]) -> Option<usize> {
    let h = previous.height;
    let min_overlap = (h / 3).max(24);
    let mut candidates: Vec<(usize, f64)> = (1..=h - min_overlap)
        .map(|d| {
            (
                d,
                signature_error(&previous.signature, signature, d, h, true),
            )
        })
        .collect();
    candidates.sort_unstable_by(|a, b| a.1.total_cmp(&b.1));
    // Repeated/blank content often has many equally plausible offsets; reject it.
    let candidate = candidates.first()?.0;
    let best = signature_error(&previous.signature, signature, candidate, h, false);
    if best > 2.5 {
        return None;
    }
    for (other, coarse_score) in candidates.iter().skip(1).take(15) {
        if other.abs_diff(candidate) <= 2 {
            continue;
        }
        if *coarse_score > 12.0 {
            continue;
        }
        let score = signature_error(&previous.signature, signature, *other, h, false);
        if score < best + 0.75 {
            return None;
        }
    }
    pixel_match(previous.view(), next, candidate).then_some(candidate)
}

pub struct Session {
    file: File,
    scratch: PathBuf,
    previous: Option<Frame>,
    height: usize,
    started: Instant,
    finished: bool,
    failed: bool,
}

impl Session {
    pub fn new(directory: &Path) -> Result<Self> {
        fs::create_dir_all(directory)
            .map_err(|e| format!("Cannot create capture directory: {e}"))?;
        let nonce = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let scratch = directory.join(format!("appshot-{}-{nonce}.bgra", std::process::id()));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&scratch)
            .map_err(|e| format!("Cannot create scrolling capture: {e}"))?;
        Ok(Self {
            file,
            scratch,
            previous: None,
            height: 0,
            started: Instant::now(),
            finished: false,
            failed: false,
        })
    }
    fn progress(&self, disposition: i32) -> Progress {
        Progress {
            width: self.previous.as_ref().map_or(0, |f| f.width as u32),
            height: self.height as u32,
            disposition,
        }
    }
    pub fn append(
        &mut self,
        bytes: &[u8],
        width: usize,
        height: usize,
        stride: usize,
    ) -> Result<Progress> {
        if self.finished || self.failed {
            return Err("The scrolling capture is no longer active.".into());
        }
        let view = FrameView::new(bytes, width, height, stride)?;
        if self.started.elapsed() >= MAX_DURATION {
            return Ok(self.progress(3));
        }
        let signature = view.signature();
        let added = match &self.previous {
            None => height,
            Some(previous) => {
                if width != previous.width || height != previous.height {
                    return Err(
                        "The capture dimensions changed. Start a new scrolling capture.".into(),
                    );
                }
                if signature_error(&previous.signature, &signature, 0, height, false) <= 0.5 {
                    return Ok(self.progress(1));
                }
                match displacement(previous, &view, &signature) {
                    Some(delta) => delta,
                    None => return Ok(self.progress(2)),
                }
            }
        };
        let new_height = self
            .height
            .checked_add(added)
            .ok_or("Capture height overflow.")?;
        if width
            .checked_mul(new_height)
            .is_none_or(|pixels| pixels > MAX_PIXELS)
        {
            return Ok(self.progress(3));
        }
        // Copy into the retained tight frame once, then append its new rows in
        // one write instead of making a system call for every scanline.
        let replacement = Frame::from_view(&view, signature);
        let old_bytes = self.height as u64 * width as u64 * 4;
        if let Err(e) = self
            .file
            .write_all(&replacement.pixels[(height - added) * width * 4..])
        {
            let _ = self.file.set_len(old_bytes);
            let _ = self.file.seek(SeekFrom::End(0));
            self.failed = true;
            return Err(format!("Could not write scrolling capture: {e}"));
        }
        self.previous = Some(replacement);
        self.height = new_height;
        Ok(self.progress(0))
    }
    pub fn finish(&mut self, destination: &Path) -> Result<Progress> {
        if self.finished {
            return Err("The scrolling capture is no longer active.".into());
        }
        let width = self
            .previous
            .as_ref()
            .ok_or("No frames were captured yet.")?
            .width;
        if destination.exists() {
            return Err("The output file already exists. Choose another name.".into());
        }
        // A failed append may have left a partial tail. Only committed rows
        // can be finalized; failure to truncate must never publish an image.
        if self.failed {
            self.file
                .set_len(self.height as u64 * width as u64 * 4)
                .map_err(|e| format!("Could not restore the last accepted rows: {e}"))?;
        }
        self.file.flush().map_err(|e| e.to_string())?;
        self.file
            .seek(SeekFrom::Start(0))
            .map_err(|e| e.to_string())?;
        let temporary = destination.with_file_name(format!(
            ".appshot-{}-{}.partial",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let result: Result<()> = (|| {
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(|e| e.to_string())?;
            png::encode(
                &mut self.file,
                &mut output,
                width as u32,
                self.height as u32,
            )?;
            output.sync_all().map_err(|e| e.to_string())?;
            // Publish atomically without overwriting a file another process created.
            fs::hard_link(&temporary, destination)
                .map_err(|e| format!("Could not publish the PNG: {e}"))?;
            Ok(())
        })();
        let _ = fs::remove_file(&temporary);
        result?;
        self.finished = true;
        let _ = fs::remove_file(&self.scratch);
        Ok(self.progress(0))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.scratch);
    }
}

enum StitchSession {
    Strict(Session),
    Calibrated(CalibratedSession),
}
impl StitchSession {
    fn append(
        &mut self,
        bytes: &[u8],
        width: usize,
        height: usize,
        stride: usize,
    ) -> Result<Progress> {
        match self {
            Self::Strict(session) => session.append(bytes, width, height, stride),
            Self::Calibrated(session) => session.append(bytes, width, height, stride),
        }
    }
    fn finish(&mut self, destination: &Path) -> Result<Progress> {
        match self {
            Self::Strict(session) => session.finish(destination),
            Self::Calibrated(session) => session.finish(destination),
        }
    }
}
pub struct SXStitcher {
    session: Mutex<StitchSession>,
}

unsafe fn error_message(out: *mut c_char, capacity: usize, message: &str) {
    if out.is_null() || capacity == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let count = bytes.len().min(capacity - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), count);
        *out.add(count) = 0;
    }
}

fn guarded<T>(error: *mut c_char, capacity: usize, work: impl FnOnce() -> Result<T>) -> Option<T> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)) {
        Ok(Ok(value)) => Some(value),
        Ok(Err(message)) => {
            unsafe {
                error_message(error, capacity, &message);
            }
            None
        }
        Err(_) => {
            unsafe {
                error_message(
                    error,
                    capacity,
                    "The scrolling image processor failed safely. Start a new capture.",
                );
            }
            None
        }
    }
}

unsafe fn path_from_c<'a>(path: *const c_char) -> Result<&'a Path> {
    if path.is_null() {
        return Err("Missing file path.".into());
    }
    let text = unsafe { CStr::from_ptr(path) }
        .to_str()
        .map_err(|_| "Invalid file path.")?;
    if text.is_empty() {
        return Err("Missing file path.".into());
    }
    Ok(Path::new(text))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_create(
    directory: *const c_char,
    error: *mut c_char,
    capacity: usize,
) -> *mut SXStitcher {
    guarded(error, capacity, || {
        let session = Session::new(unsafe { path_from_c(directory)? })?;
        Ok(Box::into_raw(Box::new(SXStitcher {
            session: Mutex::new(StitchSession::Strict(session)),
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_create_calibrated(
    directory: *const c_char,
    error: *mut c_char,
    capacity: usize,
) -> *mut SXStitcher {
    guarded(error, capacity, || {
        let session = CalibratedSession::new(unsafe { path_from_c(directory)? })?;
        Ok(Box::into_raw(Box::new(SXStitcher {
            session: Mutex::new(StitchSession::Calibrated(session)),
        })))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// 1 verified, 0 still checking, -1 invalid state. Output coordinates are input pixels.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_content_rect(
    handle: *mut SXStitcher,
    rect: *mut ContentRect,
) -> i32 {
    if handle.is_null() || rect.is_null() {
        return -1;
    }
    let Ok(session) = (unsafe { &*handle }).session.lock() else {
        return -1;
    };
    match &*session {
        StitchSession::Calibrated(session) => match session.rect {
            Some(value) => {
                unsafe { *rect = value };
                1
            }
            None => 0,
        },
        StitchSession::Strict(_) => 0,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_append(
    handle: *mut SXStitcher,
    bytes: *const u8,
    length: usize,
    width: u32,
    height: u32,
    stride: usize,
    progress: *mut Progress,
    error: *mut c_char,
    capacity: usize,
) -> i32 {
    guarded(error, capacity, || {
        if handle.is_null() || bytes.is_null() || progress.is_null() || length > isize::MAX as usize
        {
            return Err("Invalid scrolling capture input.".into());
        }
        let data = unsafe { std::slice::from_raw_parts(bytes, length) };
        let mut session = unsafe { &*handle }
            .session
            .lock()
            .map_err(|_| "The scrolling capture is unavailable.")?;
        let result = session.append(data, width as usize, height as usize, stride)?;
        unsafe {
            *progress = result;
        }
        Ok(0)
    })
    .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_finish(
    handle: *mut SXStitcher,
    destination: *const c_char,
    progress: *mut Progress,
    error: *mut c_char,
    capacity: usize,
) -> i32 {
    guarded(error, capacity, || {
        if handle.is_null() || progress.is_null() {
            return Err("Invalid scrolling capture state.".into());
        }
        let mut session = unsafe { &*handle }
            .session
            .lock()
            .map_err(|_| "The scrolling capture is unavailable.")?;
        let result = session.finish(unsafe { path_from_c(destination)? })?;
        unsafe {
            *progress = result;
        }
        Ok(0)
    })
    .unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_destroy(handle: *mut SXStitcher) {
    if !handle.is_null() {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
            drop(Box::from_raw(handle));
        }));
    }
}

#[cfg(test)]
mod tests;
