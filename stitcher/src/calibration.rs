//! Motion-verified content bounds. This module deliberately abstains when the
//! retained samples cannot be explained by one unambiguous vertical viewport.
use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct ContentRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}
impl ContentRect {
    fn view<'a>(&self, frame: &'a FrameView<'a>) -> FrameView<'a> {
        let offset = self.y as usize * frame.stride + self.x as usize * 4;
        FrameView {
            bytes: &frame.bytes[offset..],
            width: self.width as usize,
            height: self.height as usize,
            stride: frame.stride,
        }
    }
}

pub struct CalibratedSession {
    inner: Session,
    samples: Vec<Frame>,
    input_size: Option<(usize, usize)>,
    pub rect: Option<ContentRect>,
    rejected: bool,
    retried_initial_motion: bool,
}
impl CalibratedSession {
    pub fn new(directory: &Path) -> Result<Self> {
        Ok(Self {
            inner: Session::new(directory)?,
            samples: Vec::new(),
            input_size: None,
            rect: None,
            rejected: false,
            retried_initial_motion: false,
        })
    }
    fn pending(&self, disposition: i32) -> Progress {
        let (w, h) = self.input_size.unwrap_or((0, 0));
        Progress {
            width: w as u32,
            height: h as u32,
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
        let input = FrameView::new(bytes, width, height, stride)?;
        if self.input_size.is_some_and(|size| size != (width, height)) {
            return Err("The capture dimensions changed. Start a new scrolling capture.".into());
        }
        self.input_size = Some((width, height));
        if self.inner.started.elapsed() >= MAX_DURATION {
            return Ok(self.pending(3));
        }
        if let Some(rect) = self.rect {
            let view = rect.view(&input);
            return self
                .inner
                .append(view.bytes, view.width, view.height, view.stride);
        }
        if self.rejected {
            return Ok(self.pending(2));
        }
        let signature = input.signature();
        if let Some(last) = self.samples.last() {
            // Repeated compositor frames do not count as independent evidence.
            if signature_error(&last.signature, &signature, 0, height, false) <= 0.25 {
                return Ok(self.pending(4));
            }
        }
        self.samples.push(Frame::from_view(&input, signature));
        if self.samples.len() < 4 {
            return Ok(self.pending(4));
        }
        let Some(rect) = verified_rect(&self.samples) else {
            // A hover or scrollbar repaint can precede the first actual movement.
            // Keep the baseline and require three verified pairs on the retry.
            if !self.retried_initial_motion {
                self.samples.remove(1);
                self.retried_initial_motion = true;
                return Ok(self.pending(4));
            }
            self.samples.clear();
            self.rejected = true;
            return Ok(self.pending(2));
        };
        // Replay all retained samples through the strict matcher before publishing
        // a verified crop. Every sample contributes its actual new rows.
        let samples = std::mem::take(&mut self.samples);
        let mut result = self.inner.progress(4);
        for sample in samples {
            let raw = sample.view();
            let view = rect.view(&raw);
            result = self
                .inner
                .append(view.bytes, view.width, view.height, view.stride)?;
            if result.disposition != 0 {
                self.rejected = true;
                return Ok(self.pending(2));
            }
        }
        self.rect = Some(rect);
        Ok(result)
    }
    pub fn finish(&mut self, destination: &Path) -> Result<Progress> {
        let rect = self.rect.ok_or("Could not verify a scrolling content region. Adjust the area to include one moving pane and try again.")?;
        if self.inner.height <= rect.height as usize {
            return Err("No scrolling content was added.".into());
        }
        self.inner.finish(destination)
    }
}

fn difference(a: &[u8], b: &[u8]) -> u32 {
    (0..3).map(|i| a[i].abs_diff(b[i]) as u32).sum()
}

/// A pixel must change across a majority of calibration pairs to qualify. The result is
/// only a proposal: every cropped pair still has to pass the strict matcher.
fn verified_rect(samples: &[Frame]) -> Option<ContentRect> {
    let first = samples.first()?;
    let (w, h) = (first.width, first.height);
    let mut changed = vec![false; w * h];
    let mut columns = vec![0usize; w];
    for y in 0..h {
        for (x, count) in columns.iter_mut().enumerate() {
            let p = (y * w + x) * 4;
            let moving = samples
                .windows(2)
                .filter(|pair| {
                    difference(&pair[0].pixels[p..p + 4], &pair[1].pixels[p..p + 4]) > 18
                })
                .count()
                >= 2;
            if moving {
                changed[y * w + x] = true;
                *count += 1;
            }
        }
    }
    // Ignore tiny isolated features such as a scrollbar thumb. Pick the widest
    // coherent column run; unrelated moving panes are rejected by verification.
    let active: Vec<bool> = columns.iter().map(|n| *n >= (h / 100).max(3)).collect();
    let (mut left, mut right) = widest_run(&active, 16)?;
    if right - left < 16 {
        return None;
    }
    let mut rows = vec![0usize; h];
    for (y, count) in rows.iter_mut().enumerate() {
        *count = (left..right).filter(|x| changed[y * w + x]).count();
    }
    let top = rows
        .iter()
        .position(|n| *n >= ((right - left) / 100).max(3))?;
    let bottom = rows
        .iter()
        .rposition(|n| *n >= ((right - left) / 100).max(3))?
        + 1;
    if bottom - top < 32 {
        return None;
    }
    // Do not trim blank margins just because they supplied no motion evidence.
    // A discarded edge must also contain contrast that demonstrably stayed put.
    if !stationary_contrast(samples, 0, 0, left, h) {
        left = 0;
    }
    if !stationary_contrast(samples, right, 0, w, h) {
        right = w;
    }
    let top = if stationary_contrast(samples, left, 0, right, top) {
        top
    } else {
        0
    };
    let bottom = if stationary_contrast(samples, left, bottom, right, h) {
        bottom
    } else {
        h
    };
    let rect = ContentRect {
        x: left as u32,
        y: top as u32,
        width: (right - left) as u32,
        height: (bottom - top) as u32,
    };
    for pair in samples.windows(2) {
        let a_raw = pair[0].view();
        let b_raw = pair[1].view();
        let a = rect.view(&a_raw);
        let b = rect.view(&b_raw);
        let previous = Frame::from_view(&a, a.signature());
        // A gesture can begin with a single pixel of uniquely matched motion.
        displacement(&previous, &b, &b.signature())?;
    }
    Some(rect)
}

fn widest_run(active: &[bool], bridge: usize) -> Option<(usize, usize)> {
    let mut best = None;
    let mut start = None;
    let mut last = 0;
    for (x, &on) in active.iter().enumerate() {
        if on {
            if start.is_none() {
                start = Some(x);
            }
            last = x + 1;
        } else if let Some(s) = start {
            if x + 1 - last > bridge {
                if best.is_none_or(|(a, b)| last - s > b - a) {
                    best = Some((s, last));
                }
                start = None;
            }
        }
    }
    if let Some(s) = start {
        if best.is_none_or(|(a, b)| last - s > b - a) {
            best = Some((s, last));
        }
    }
    best
}

fn stationary_contrast(samples: &[Frame], x0: usize, y0: usize, x1: usize, y1: usize) -> bool {
    if x1 <= x0 || y1 <= y0 {
        return false;
    }
    let w = samples[0].width;
    let mut stable = 0;
    let mut judged = 0;
    for y in y0..y1 {
        for x in x0..x1 {
            let p = (y * w + x) * 4;
            let next = if x + 1 < x1 {
                p + 4
            } else if y + 1 < y1 {
                p + w * 4
            } else {
                continue;
            };
            if difference(
                &samples[0].pixels[p..p + 4],
                &samples[0].pixels[next..next + 4],
            ) <= 18
            {
                continue;
            }
            judged += 1;
            if samples
                .windows(2)
                .filter(|pair| {
                    difference(&pair[0].pixels[p..p + 4], &pair[1].pixels[p..p + 4]) <= 9
                })
                .count()
                >= 2
            {
                stable += 1;
            }
        }
    }
    judged >= 8 && stable * 100 >= judged * 90
}
