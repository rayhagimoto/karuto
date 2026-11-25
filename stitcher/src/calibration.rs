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
    fn fits(self, width: usize, height: usize) -> bool {
        self.width >= 16
            && self.height >= 32
            && self.x as usize + self.width as usize <= width
            && self.y as usize + self.height as usize <= height
    }

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
    pub excluded_bottom_overlay: bool,
    hint: Option<ContentRect>,
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
            excluded_bottom_overlay: false,
            hint: None,
            rejected: false,
            retried_initial_motion: false,
        })
    }
    pub fn set_hint(&mut self, rect: ContentRect) -> bool {
        if self.input_size.is_some() {
            return false;
        }
        self.hint = Some(rect);
        true
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
        if let Some(rect) = self.rect {
            let view = rect.view(&input);
            return self
                .inner
                .append(view.bytes, view.width, view.height, view.stride);
        }
        if self.inner.started.elapsed() >= MAX_DURATION {
            return Ok(self.pending(3));
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
        let suggested = self
            .hint
            .and_then(|rect| verified_candidate(&self.samples, rect, MatchOptions::PINNED_HEADER));
        let Some((rect, excluded_bottom_overlay)) =
            suggested.or_else(|| verified_rect(&self.samples))
        else {
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
        // Replay all retained samples through the same matcher before publishing
        // a verified crop. Every sample contributes its actual new rows.
        let samples = std::mem::take(&mut self.samples);
        self.inner.match_options = MatchOptions::CALIBRATED;
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
        self.excluded_bottom_overlay = excluded_bottom_overlay;
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
fn verified_rect(samples: &[Frame]) -> Option<(ContentRect, bool)> {
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
    let mut top = rows
        .iter()
        .position(|n| *n >= ((right - left) / 100).max(3))?;
    let mut bottom = rows
        .iter()
        .rposition(|n| *n >= ((right - left) / 100).max(3))?
        + 1;
    if bottom - top < 32 {
        return None;
    }
    // Find real pane edges before deciding that quiet margins belong to fixed
    // chrome. Test only the moving height so a footer cannot trim the sides.
    left = (1..=left)
        .rev()
        .find(|&x| pane_edge(samples, x, top, bottom, Edge::Left))
        .unwrap_or_else(|| {
            if stationary_side(samples, 0, left, top, bottom) {
                left
            } else {
                0
            }
        });
    right = (right..w)
        .find(|&x| pane_edge(samples, x, top, bottom, Edge::Right))
        .unwrap_or_else(|| {
            if stationary_side(samples, right, w, top, bottom) {
                right
            } else {
                w
            }
        });

    if stationary_contrast(samples, left, 0, right, top) {
        // Padding just inside a bordered pane can be visually quiet.
        top = (top.saturating_sub(4).max(1)..=top)
            .rev()
            .find(|&y| pane_edge(samples, y, left, right, Edge::Top))
            .unwrap_or(top);
    } else {
        top = 0;
    }
    if stationary_contrast(samples, left, bottom, right, h) {
        bottom = (bottom..(bottom + 5).min(h))
            .find(|&y| pane_edge(samples, y, left, right, Edge::Bottom))
            .unwrap_or(bottom);
    } else {
        bottom = h;
    }

    // Preserve quiet edges when the full pane agrees. When the pane fills
    // both sides and extends to the bottom, keep its initial pinned band once.
    if left == 0 && right == w && (top > 0 || bottom < h) {
        let full = ContentRect {
            x: 0,
            y: 0,
            width: w as u32,
            height: h as u32,
        };
        let options = MatchOptions {
            top_overlay: bottom == h && top <= h / 3,
            repaint: false,
        };
        if bottom == h {
            if let Some(candidate) = verified_candidate(samples, full, options) {
                return Some(candidate);
            }
        } else if verifies(samples, full, options) {
            return Some((full, false));
        }
    }
    let rect = ContentRect {
        x: left as u32,
        y: top as u32,
        width: (right - left) as u32,
        height: (bottom - top) as u32,
    };
    verified_candidate(samples, rect, MatchOptions::CALIBRATED)
}

fn verified_candidate(
    samples: &[Frame],
    rect: ContentRect,
    options: MatchOptions,
) -> Option<(ContentRect, bool)> {
    if !rect.fits(samples[0].width, samples[0].height) {
        return None;
    }
    if let Some(clean) = without_bottom_overlay(samples, rect, options) {
        return Some((clean, true));
    }
    verifies(samples, rect, options).then_some((rect, false))
}

/// A floating bottom control can have moving content beside it or below it.
/// Require independent evidence that it stays still while the pane scrolls.
fn without_bottom_overlay(
    samples: &[Frame],
    rect: ContentRect,
    options: MatchOptions,
) -> Option<ContentRect> {
    let probe = ContentRect {
        height: rect.height * 3 / 4,
        ..rect
    };
    let top = rect.y as usize;
    let rows = top + probe.height as usize..top + rect.height as usize;
    let columns = rect.x as usize + 2..(rect.x + rect.width) as usize - 2;
    let width = samples[0].width;
    let change = |a: &Frame, p: usize, b: &Frame, q: usize| {
        difference(&a.pixels[p..p + 4], &b.pixels[q..q + 4])
    };
    let contrast = |p| change(&samples[0], p, &samples[0], p - 4) > 18;
    let stays_put = |pair: &[Frame], p| {
        change(&pair[0], p, &pair[1], p) <= 9 && change(&pair[0], p - 4, &pair[1], p - 4) <= 9
    };
    let row_pixels = |y| columns.clone().map(move |x| (y * width + x) * 4);
    // Look for local stationary edges. A narrow control can cover only a few
    // pixels of a row whose remaining text moves normally.
    let candidates: Vec<_> = rows
        .clone()
        .filter(|&y| {
            row_pixels(y)
                .filter(|&p| {
                    contrast(p)
                        && samples
                            .windows(2)
                            .filter(|pair| stays_put(pair, p))
                            .nth(1)
                            .is_some()
                })
                .nth(3)
                .is_some()
        })
        .collect();
    if candidates.len() < 3 || probe.height < 32 {
        return None;
    }
    let shifts: Vec<_> = samples
        .windows(2)
        .map(|pair| pair_displacement(pair, probe, options))
        .collect::<Option<_>>()?;
    let fixed_edge = |p| {
        contrast(p)
            && samples
                .windows(2)
                .zip(&shifts)
                .filter(|&(pair, &shift)| {
                    stays_put(pair, p) && change(&pair[0], p, &pair[1], p - shift * width * 4) > 18
                })
                .nth(1)
                .is_some()
    };
    let fixed_rows: Vec<_> = candidates
        .into_iter()
        .filter(|&y| row_pixels(y).filter(|&p| fixed_edge(p)).nth(3).is_some())
        .collect();
    // A small glyph may have only a few strong edges in one row. Require a
    // run of adjacent rows so isolated matching edges cannot mark a control.
    let first_fixed = fixed_rows.windows(3).find(|run| run[2] == run[0] + 2)?[0];

    // Cut before the first row that disagrees after translation. A control's
    // shadow can alter the pixels well above its first high-contrast edge.
    let disagreement = |p| {
        samples
            .windows(2)
            .zip(&shifts)
            .any(|(pair, &shift)| change(&pair[0], p, &pair[1], p - shift * width * 4) > 0)
    };
    let bottom = (rows.start..first_fixed)
        .find(|&y| row_pixels(y).filter(|&p| disagreement(p)).nth(7).is_some())
        .unwrap_or(first_fixed);
    let clean = ContentRect {
        height: (bottom - top) as u32,
        ..rect
    };
    samples
        .windows(2)
        .zip(shifts)
        .all(|(pair, shift)| pair_displacement(pair, clean, options) == Some(shift))
        .then_some(clean)
}

fn pair_displacement(pair: &[Frame], rect: ContentRect, options: MatchOptions) -> Option<usize> {
    let a_raw = pair[0].view();
    let b_raw = pair[1].view();
    let a = rect.view(&a_raw);
    let b = rect.view(&b_raw);
    let previous = Frame::from_view(&a, a.signature());
    displacement(&previous, &b, &b.signature(), options)
}

fn verifies(samples: &[Frame], rect: ContentRect, options: MatchOptions) -> bool {
    samples
        .windows(2)
        .all(|pair| pair_displacement(pair, rect, options).is_some())
}

enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

/// A persistent transition with the stationary pixel on the outside of a pane.
fn pane_edge(samples: &[Frame], position: usize, start: usize, end: usize, side: Edge) -> bool {
    if end <= start || position == 0 {
        return false;
    }
    let vertical = matches!(side, Edge::Left | Edge::Right);
    let before = matches!(side, Edge::Left | Edge::Top);
    let width = samples[0].width;
    let stride = ((end - start) / 64).max(1);
    let mut total = 0;
    let mut stable = 0;
    for at in (start..end).step_by(stride) {
        let index = |offset| {
            if vertical {
                (at * width + offset) * 4
            } else {
                (offset * width + at) * 4
            }
        };
        let inner = index(if before { position } else { position - 1 });
        let outer = index(if before { position - 1 } else { position });
        let reference = &samples[0].pixels[outer..outer + 4];
        let supported = samples
            .iter()
            .filter(|frame| {
                difference(reference, &frame.pixels[outer..outer + 4]) <= 9
                    && difference(
                        &frame.pixels[outer..outer + 4],
                        &frame.pixels[inner..inner + 4],
                    ) > 18
            })
            .count();
        total += 1;
        stable += usize::from(supported >= 3);
    }
    stable * 4 >= total * 3
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

fn stationary_side(samples: &[Frame], x0: usize, x1: usize, top: usize, bottom: usize) -> bool {
    // A small floating control does not establish a fixed vertical sidebar.
    (0..3)
        .filter(|band| {
            let y0 = top + (bottom - top) * band / 3;
            let y1 = top + (bottom - top) * (band + 1) / 3;
            stationary_contrast(samples, x0, y0, x1, y1)
        })
        .count()
        >= 2
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
