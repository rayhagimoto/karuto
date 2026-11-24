//! Bounded vertical screenshot stitching. The caller owns capture and scrolling.
mod calibration;
mod png;
use calibration::CalibratedSession;
pub use calibration::ContentRect;

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
    /// 0 accepted, 1 unchanged, 2 reconnect required, 3 limit reached,
    /// 4 checking content, 5 returned to the last accepted viewport.
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
    fn shares_exact_rows(&self, next: &Self, shift: usize) -> bool {
        // Leave the outer two pixels free for a scrollbar or compositor edge.
        let columns = 8..(self.width - 2) * 4;
        (0..self.height - shift)
            .all(|y| self.row(y + shift)[columns.clone()] == next.row(y)[columns.clone()])
    }
    fn below(&self, rows: usize) -> Self {
        Self {
            bytes: &self.bytes[rows * self.stride..],
            height: self.height - rows,
            ..*self
        }
    }
    fn edge_signature(&self) -> Vec<u8> {
        let mut result = vec![0u8; self.height * 32];
        let stride = (self.width / 320).max(1);
        for y in 0..self.height {
            let row = self.row(y);
            for x in (2..self.width - 2).step_by(stride) {
                if horizontal_edge(row, x).unsigned_abs() >= 18 {
                    result[y * 32 + x * 32 / self.width] += 1;
                }
            }
        }
        result
    }
    fn signature(&self) -> Vec<u8> {
        let mut result = Vec::with_capacity(self.height * 32);
        for y in 0..self.height {
            let row = self.row(y);
            for x in sample_columns(self.width) {
                let p = &row[x * 4..x * 4 + 4];
                result.push(luminance(p));
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

fn luminance(pixel: &[u8]) -> u8 {
    ((29 * pixel[0] as u32 + 150 * pixel[1] as u32 + 77 * pixel[2] as u32) >> 8) as u8
}

fn horizontal_edge(row: &[u8], x: usize) -> i16 {
    i16::from(luminance(&row[x * 4..])) - i16::from(luminance(&row[(x - 1) * 4..]))
}

/// Compare ink near the sides as well as the body. Weight contrast independently
/// of large flat fills, which can look identical at an unrelated scroll offset.
fn pixel_match(a: &FrameView<'_>, b: &FrameView<'_>, shift: usize, repaint: bool) -> bool {
    let overlap = a.height - shift;
    let column_step = (a.width / 256).max(1);
    let row_step = (overlap / 256).max(1);
    let mut differences = 0usize;
    let mut mismatches = 0usize;
    let mut samples = 0usize;
    let mut edges = 0usize;
    let mut edge_mismatches = 0usize;
    let mut first_anchor = None;
    let mut last_anchor = 0;
    let mut anchor_rows = 0;
    for y in (0..overlap).step_by(row_step) {
        let ar = a.row(y + shift);
        let br = b.row(y);
        let mut anchors = 0;
        for x in (2..a.width - 2).step_by(column_step) {
            let p = x * 4;
            let diff = (0..3)
                .map(|c| ar[p + c].abs_diff(br[p + c]) as usize)
                .sum::<usize>();
            differences += diff;
            mismatches += usize::from(diff > 36);
            samples += 1;
            let a_edge = horizontal_edge(ar, x);
            let b_edge = horizontal_edge(br, x);
            if a_edge.unsigned_abs().max(b_edge.unsigned_abs()) >= 22 {
                edges += 1;
                if a_edge.signum() == b_edge.signum()
                    && a_edge.unsigned_abs().min(b_edge.unsigned_abs()) >= 13
                {
                    anchors += 1;
                } else {
                    edge_mismatches += 1;
                }
            } else if !repaint
                && diff <= 18
                && y + shift + 1 < a.height
                && luminance(&ar[p..]).abs_diff(luminance(&a.row(y + shift + 1)[p..])) >= 24
            {
                anchors += 1;
            }
        }
        if anchors >= 2 {
            first_anchor.get_or_insert(y);
            last_anchor = y;
            anchor_rows += 1;
        }
    }
    let spread = last_anchor - first_anchor.unwrap_or(last_anchor);
    let distinctive = anchor_rows >= 3 && spread >= (overlap / 5).max(2);
    let edges_agree = edge_mismatches * 100 <= edges * if repaint { 12 } else { 24 };
    distinctive
        && edges_agree
        && if repaint {
            edges >= 24
        } else {
            differences <= samples * 7 && mismatches * 100 <= samples * 3
        }
}

#[derive(Clone, Copy)]
struct MatchOptions {
    top_overlay: bool,
    repaint: bool,
}

impl MatchOptions {
    const STRICT: Self = Self {
        top_overlay: false,
        repaint: false,
    };
    const CALIBRATED: Self = Self {
        top_overlay: true,
        repaint: true,
    };
    const PINNED_HEADER: Self = Self {
        top_overlay: true,
        repaint: false,
    };
}

/// Returns only a forward displacement supported by a unique image match.
fn displacement(
    previous: &Frame,
    next: &FrameView<'_>,
    signature: &[u8],
    options: MatchOptions,
) -> Option<usize> {
    let a = previous.view();
    let min_overlap = (a.height / 3).max(24);
    let full = matching_displacement(&a, &previous.signature, next, signature, min_overlap, false);
    if full.is_some() {
        return full;
    }

    if options.top_overlay {
        // Sticky UI can obscure the leading edge only. Ignore it for alignment
        // while preserving a substantial overlap and appending the untouched tail.
        // Try a shallow inset first so landmarks just beneath a toolbar survive.
        for top in [
            a.height / 12,
            a.height / 8,
            a.height / 4,
            a.height / 3,
            a.height * 5 / 12,
            a.height / 2,
        ] {
            let min_body_overlap = ((a.height - top) / 3).max(24);
            if a.height - top <= min_body_overlap {
                break;
            }
            if let Some(shift) = matching_displacement(
                &a.below(top),
                &previous.signature[top * 32..],
                &next.below(top),
                &signature[top * 32..],
                min_body_overlap,
                false,
            ) {
                return Some(shift);
            }
        }
    }

    options
        .repaint
        .then(|| {
            matching_displacement(
                &a,
                &a.edge_signature(),
                next,
                &next.edge_signature(),
                min_overlap,
                true,
            )
        })
        .flatten()
}

fn matching_displacement(
    previous: &FrameView<'_>,
    previous_signature: &[u8],
    next: &FrameView<'_>,
    signature: &[u8],
    min_overlap: usize,
    repaint: bool,
) -> Option<usize> {
    let h = previous.height;
    let mut candidates: Vec<(usize, f64)> = (1..=h - min_overlap)
        .map(|d| {
            (
                d,
                signature_error(previous_signature, signature, d, h, true),
            )
        })
        .collect();
    candidates.sort_unstable_by(|a, b| a.1.total_cmp(&b.1));
    // Rescore plausible offsets on every overlap row before checking color or ink.
    let mut refined: Vec<_> = candidates
        .iter()
        .take(16)
        .map(|&(shift, _)| {
            (
                shift,
                signature_error(previous_signature, signature, shift, h, false),
            )
        })
        .collect();
    refined.sort_unstable_by(|a, b| a.1.total_cmp(&b.1));
    let &(candidate, best) = refined.first()?;
    let ambiguity = if repaint { 0.035 } else { 0.75 };
    if best > 2.5
        || refined
            .iter()
            .skip(1)
            .any(|&(other, score)| other.abs_diff(candidate) > 2 && score < best + ambiguity)
    {
        return None;
    }
    pixel_match(previous, next, candidate, repaint).then_some(candidate)
}

pub struct Session {
    file: File,
    scratch: PathBuf,
    previous: Option<Frame>,
    height: usize,
    started: Instant,
    finished: bool,
    failed: bool,
    match_options: MatchOptions,
    rejected_overlap: bool,
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
            match_options: MatchOptions::STRICT,
            rejected_overlap: false,
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
                let baseline = previous.view();
                if signature_error(&previous.signature, &signature, 0, height, false) <= 0.5 {
                    if self.rejected_overlap && baseline.shares_exact_rows(&view, 0) {
                        self.rejected_overlap = false;
                        return Ok(self.progress(5));
                    }
                    return Ok(self.progress(1));
                }
                // After a gap, coincidentally similar rows must not reconnect
                // the capture. Require exact overlap or return to its last view.
                let options = if self.rejected_overlap {
                    MatchOptions::STRICT
                } else {
                    self.match_options
                };
                let matched = displacement(previous, &view, &signature, options).filter(|&shift| {
                    !self.rejected_overlap || baseline.shares_exact_rows(&view, shift)
                });
                match matched {
                    Some(delta) => delta,
                    None => {
                        self.rejected_overlap = true;
                        return Ok(self.progress(2));
                    }
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
        self.rejected_overlap = false;
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

/// Supply a structural suggestion before the first frame. Pixel verification
/// still decides whether the suggested viewport is usable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sx_stitcher_set_content_hint(
    handle: *mut SXStitcher,
    rect: ContentRect,
) -> i32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return -1;
    };
    let Ok(mut session) = handle.session.lock() else {
        return -1;
    };
    match &mut *session {
        StitchSession::Calibrated(session) => {
            if session.set_hint(rect) {
                0
            } else {
                -1
            }
        }
        _ => -1,
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
