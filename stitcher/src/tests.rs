use super::*;
use std::io::Read;

struct TestDirectory(PathBuf);
impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "karuto-stitch-test-{}-{}",
            std::process::id(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}
impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn pixels(width: usize, height: usize, start: usize, padding: usize) -> Vec<u8> {
    let stride = width * 4 + padding;
    let mut result = vec![0xCC; stride * height];
    for y in 0..height {
        for x in 0..width {
            let mut hash =
                (x as u32).wrapping_mul(0x45d9f3b) ^ ((y + start) as u32).wrapping_mul(0x119de1f3);
            hash ^= hash >> 16;
            hash = hash.wrapping_mul(0x45d9f3b);
            let p = y * stride + x * 4;
            result[p..p + 4].copy_from_slice(&[
                hash as u8,
                (hash >> 8) as u8,
                (hash >> 16) as u8,
                255,
            ]);
        }
    }
    result
}

fn crc(bytes: &[u8]) -> u32 {
    let mut result = !0u32;
    for &b in bytes {
        result ^= b as u32;
        for _ in 0..8 {
            result = (result >> 1) ^ (0xEDB88320 & (0u32.wrapping_sub(result & 1)));
        }
    }
    !result
}

fn decode_png(path: &Path) -> (usize, usize, Vec<u8>) {
    let mut bytes = Vec::new();
    File::open(path).unwrap().read_to_end(&mut bytes).unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    let mut offset = 8;
    let mut compressed = Vec::new();
    let (mut width, mut height) = (0, 0);
    while offset < bytes.len() {
        let length = u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
        let kind = &bytes[offset + 4..offset + 8];
        let data = &bytes[offset + 8..offset + 8 + length];
        let checksum = u32::from_be_bytes(
            bytes[offset + 8 + length..offset + 12 + length]
                .try_into()
                .unwrap(),
        );
        assert_eq!(crc(&bytes[offset + 4..offset + 8 + length]), checksum);
        if kind == b"IHDR" {
            width = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
            height = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
            assert_eq!(&data[8..], &[8, 6, 0, 0, 0]);
        } else if kind == b"IDAT" {
            compressed.extend_from_slice(data);
        }
        offset += 12 + length;
    }
    let mut filtered = vec![0; (width * 4 + 1) * height];
    let mut size = filtered.len() as std::ffi::c_ulong;
    assert_eq!(
        unsafe {
            png::uncompress(
                filtered.as_mut_ptr(),
                &mut size,
                compressed.as_ptr(),
                compressed.len() as _,
            )
        },
        0
    );
    assert_eq!(size as usize, filtered.len());
    let mut result = Vec::with_capacity(width * height * 4);
    for row in filtered.chunks_exact(width * 4 + 1) {
        assert_eq!(row[0], 1);
        let mut last = [0u8; 4];
        for encoded in row[1..].chunks_exact(4) {
            for c in 0..4 {
                last[c] = last[c].wrapping_add(encoded[c]);
            }
            // Convert PNG RGBA back into opaque BGRA fixture representation.
            result.extend_from_slice(&[last[2], last[1], last[0], last[3]]);
        }
    }
    (width, height, result)
}

#[test]
fn stitches_padded_frames_and_png_pixels_exactly() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    for start in [0, 24, 48, 72] {
        let frame = pixels(96, 128, start, 16);
        let p = session.append(&frame, 96, 128, 96 * 4 + 16).unwrap();
        assert_eq!(p.disposition, 0);
        assert_eq!(p.height, (start + 128) as u32);
    }
    let path = dir.0.join("stitched.png");
    let p = session.finish(&path).unwrap();
    assert_eq!((p.width, p.height), (96, 200));
    let (w, h, actual) = decode_png(&path);
    assert_eq!((w, h), (96, 200));
    assert_eq!(actual, pixels(w, h, 0, 0));
    assert!(!session.scratch.exists());
}

#[test]
fn duplicate_and_reverse_frames_do_not_append() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let initial = pixels(64, 96, 0, 0);
    session.append(&initial, 64, 96, 256).unwrap();
    assert_eq!(
        session.append(&initial, 64, 96, 256).unwrap().disposition,
        1
    );
    session.append(&pixels(64, 96, 20, 0), 64, 96, 256).unwrap();
    let reverse = session.append(&initial, 64, 96, 256).unwrap();
    assert_eq!((reverse.height, reverse.disposition), (116, 2));
}

#[test]
fn nonoverlap_and_sticky_headers_require_reconnection() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let initial = pixels(64, 128, 0, 0);
    session.append(&initial, 64, 128, 256).unwrap();
    assert_eq!(
        session
            .append(&pixels(64, 128, 1000, 0), 64, 128, 256)
            .unwrap()
            .disposition,
        2
    );
    let mut header = pixels(64, 128, 32, 0);
    header[..20 * 256].copy_from_slice(&initial[..20 * 256]);
    assert_eq!(
        session.append(&header, 64, 128, 256).unwrap().disposition,
        2
    );
    assert_eq!(session.height, 128);
}

#[test]
fn late_content_replaces_provisional_blank_rows_without_skipping_overlap() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    session.match_options = MatchOptions::CALIBRATED;
    let (width, height, shift, populated) = (192, 360, 120, 228);
    let stride = width * 4;
    let document = pixels(width, height + shift, 0, 0);
    let mut initial = document[..height * stride].to_vec();
    initial[populated * stride..].fill(0xff);
    session.append(&initial, width, height, stride).unwrap();

    let next = &document[shift * stride..];
    let progress = session.append(next, width, height, stride).unwrap();
    assert_eq!(
        (progress.disposition, progress.height),
        (0, (height + shift) as u32)
    );
    let output = dir.0.join("late-content.png");
    session.finish(&output).unwrap();
    let (_, _, actual) = decode_png(&output);
    assert!(actual == document, "late rows were skipped or duplicated");
}

#[test]
fn late_render_without_motion_does_not_interrupt_scrolling() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    session.match_options = MatchOptions::CALIBRATED;
    let (width, height, shift, populated) = (192, 360, 120, 228);
    let stride = width * 4;
    let document = pixels(width, height + shift, 0, 0);
    let mut initial = document[..height * stride].to_vec();
    initial[populated * stride..].fill(0xff);
    session.append(&initial, width, height, stride).unwrap();

    let repaint = session
        .append(&document[..height * stride], width, height, stride)
        .unwrap();
    assert_eq!((repaint.disposition, repaint.height), (1, height as u32));
    let moved = session
        .append(&document[shift * stride..], width, height, stride)
        .unwrap();
    assert_eq!(
        (moved.disposition, moved.height),
        (0, (height + shift) as u32)
    );
    let output = dir.0.join("late-render.png");
    session.finish(&output).unwrap();
    let (_, _, actual) = decode_png(&output);
    assert!(
        actual == document,
        "the stationary redraw must not add or duplicate rows"
    );
}

#[test]
fn finalizing_with_provisional_rows_keeps_the_accepted_blank_tail() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    session.match_options = MatchOptions::CALIBRATED;
    let (width, height, populated) = (96, 144, 102);
    let stride = width * 4;
    let mut initial = pixels(width, height, 0, 0);
    initial[populated * stride..].fill(0xff);
    session.append(&initial, width, height, stride).unwrap();
    assert_eq!(
        session.file.metadata().unwrap().len(),
        (populated * stride) as u64
    );

    let other = pixels(width, height, 3000, 0);
    assert_eq!(
        session
            .append(&other, width, height, stride)
            .unwrap()
            .disposition,
        2
    );
    let output = dir.0.join("blank-tail.png");
    session.finish(&output).unwrap();
    let (_, _, actual) = decode_png(&output);
    assert!(actual == initial);
}

#[test]
fn ordinary_overlap_leaves_previously_seen_pixels_intact() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    session.match_options = MatchOptions::CALIBRATED;
    let (width, height, shift) = (192, 288, 72);
    let stride = width * 4;
    let mut document = pixels(width, height + shift, 0, 0);
    document[225 * stride..height * stride].fill(0xff);
    session
        .append(&document[..height * stride], width, height, stride)
        .unwrap();

    let mut next = document[shift * stride..].to_vec();
    next[160 * stride + 80 * 4] = 0;
    assert_eq!(
        session
            .append(&next, width, height, stride)
            .unwrap()
            .disposition,
        0
    );
    let output = dir.0.join("ordinary-overlap.png");
    session.finish(&output).unwrap();
    let (_, _, actual) = decode_png(&output);
    assert!(actual == document);
}

#[test]
fn repeated_content_is_not_given_an_arbitrary_seam() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let base = pixels(64, 16, 0, 0);
    let a = base.repeat(12);
    let b: Vec<u8> = a[8 * 256..]
        .iter()
        .chain(a[..8 * 256].iter())
        .copied()
        .collect();
    session.append(&a, 64, 192, 256).unwrap();
    assert_eq!(session.append(&b, 64, 192, 256).unwrap().disposition, 2);
}

#[test]
fn bad_stride_short_data_and_dimension_changes_are_errors() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let a = pixels(64, 96, 0, 0);
    assert!(session.append(&a, 64, 96, 64).is_err());
    assert!(session.append(&a[..100], 64, 96, 256).is_err());
    assert!(session.append(&a, 64, 96, usize::MAX).is_err());
    session.append(&a, 64, 96, 256).unwrap();
    assert!(session.append(&pixels(65, 96, 0, 0), 65, 96, 260).is_err());
    assert!(FrameView::new(&[], 4097, 32, 4097 * 4).is_err());
    assert!(FrameView::new(&[], 4096, 8192, 4096 * 4).is_err());
}

#[test]
fn duration_and_pixel_limits_preserve_accepted_capture() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let a = pixels(64, 96, 0, 0);
    session.append(&a, 64, 96, 256).unwrap();
    session.height = MAX_PIXELS / 64;
    assert_eq!(
        session
            .append(&pixels(64, 96, 24, 0), 64, 96, 256)
            .unwrap()
            .disposition,
        3
    );
    session.height = 96;
    session.started = Instant::now() - Duration::from_secs(121);
    assert_eq!(session.append(&a, 64, 96, 256).unwrap().disposition, 3);
    assert_eq!(session.height, 96);
}

#[test]
fn output_exists_is_not_overwritten_and_empty_capture_is_rejected() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let destination = dir.0.join("keep.png");
    assert!(session.finish(&destination).is_err());
    fs::write(&destination, b"keep").unwrap();
    session.append(&pixels(64, 96, 0, 0), 64, 96, 256).unwrap();
    assert!(session.finish(&destination).is_err());
    assert_eq!(fs::read(&destination).unwrap(), b"keep");
}

#[test]
fn dropping_session_removes_scratch() {
    let dir = TestDirectory::new();
    let path;
    {
        let session = Session::new(&dir.0).unwrap();
        path = session.scratch.clone();
        assert!(path.exists());
    }
    assert!(!path.exists());
}

#[test]
fn ffi_null_input_returns_terminated_error() {
    let mut error = [0i8; 8];
    let mut progress = Progress {
        width: 0,
        height: 0,
        disposition: 0,
    };
    let result = unsafe {
        sx_stitcher_append(
            std::ptr::null_mut(),
            std::ptr::null(),
            0,
            0,
            0,
            0,
            &mut progress,
            error.as_mut_ptr(),
            error.len(),
        )
    };
    assert_eq!(result, -1);
    assert_eq!(error[7], 0);
    assert_ne!(error[0], 0);
}

#[test]
fn many_frames_keep_only_one_frame_in_memory() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    for start in (0..1000).step_by(25) {
        session
            .append(&pixels(64, 96, start, 0), 64, 96, 256)
            .unwrap();
    }
    assert_eq!(session.height, 1071);
    assert_eq!(session.previous.as_ref().unwrap().pixels.len(), 64 * 96 * 4);
    assert_eq!(session.file.metadata().unwrap().len(), 64 * 1071 * 4);
}

#[test]
fn failed_append_can_finalize_only_last_committed_rows() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let initial = pixels(64, 96, 0, 0);
    session.append(&initial, 64, 96, 256).unwrap();
    session.file.write_all(&[0xCC; 333]).unwrap();
    session.failed = true; // Simulate a failed append with a partial scratch tail.
    assert!(session.append(&initial, 64, 96, 256).is_err());
    let output = dir.0.join("recovered.png");
    session.finish(&output).unwrap();
    let (width, height, actual) = decode_png(&output);
    assert_eq!((width, height), (64, 96));
    assert_eq!(actual, initial);
}

#[test]
fn high_frequency_periodic_patterns_do_not_choose_an_arbitrary_offset() {
    for period in [2, 3, 5, 7] {
        let dir = TestDirectory::new();
        let mut session = Session::new(&dir.0).unwrap();
        let height = 192;
        let a: Vec<u8> = (0..height)
            .flat_map(|y| pixels(64, 1, y % period, 0))
            .collect();
        let b: Vec<u8> = (0..height)
            .flat_map(|y| pixels(64, 1, (y + 1) % period, 0))
            .collect();
        session.append(&a, 64, height, 256).unwrap();
        let result = session.append(&b, 64, height, 256).unwrap();
        assert_eq!(result.disposition, 2, "period {period}");
        assert_eq!(result.height, height as u32);
    }
}

fn decorated_frame(width: usize, height: usize, rect: ContentRect, start: usize) -> Vec<u8> {
    let mut raw = pixels(width, height, 50_000, 0);
    let content = pixels(rect.width as usize, rect.height as usize, start, 0);
    for y in 0..rect.height as usize {
        let to = ((y + rect.y as usize) * width + rect.x as usize) * 4;
        let from = y * rect.width as usize * 4;
        raw[to..to + rect.width as usize * 4]
            .copy_from_slice(&content[from..from + rect.width as usize * 4]);
    }
    raw
}

#[test]
fn calibration_uses_structural_bounds_only_if_the_pixels_agree() {
    let dir = TestDirectory::new();
    let rect = ContentRect {
        x: 30,
        y: 24,
        width: 120,
        height: 112,
    };
    for hint in [
        rect,
        ContentRect {
            x: 0,
            y: 0,
            width: 192,
            height: 160,
        },
    ] {
        let mut session = CalibratedSession::new(&dir.0).unwrap();
        assert!(session.set_hint(hint));
        for start in [0, 14, 28, 42, 56] {
            let raw = decorated_frame(192, 160, rect, start);
            session.append(&raw, 192, 160, 768).unwrap();
        }
        assert_eq!(session.rect, Some(rect));
        assert!(!session.set_hint(rect));
    }
}

#[test]
fn calibrated_capture_excludes_a_floating_composer_from_appended_rows() {
    let dir = TestDirectory::new();
    let (width, height, overlay_top) = (320, 300, 260);
    let stride = width * 4;
    let mut document = [34, 34, 34, 255].repeat(width * 550);
    for (y, x, w) in [
        (20, 96, 132),
        (69, 141, 111),
        (107, 68, 138),
        (152, 150, 107),
        (201, 90, 121),
        (243, 111, 143),
        (303, 72, 160),
        (374, 154, 107),
        (431, 84, 155),
        (496, 134, 118),
    ] {
        let block = pixels(w, 12, y, 0);
        for row in 0..12 {
            let offset = (y + row) * stride + x * 4;
            document[offset..offset + w * 4]
                .copy_from_slice(&block[row * w * 4..(row + 1) * w * 4]);
        }
    }
    let overlay = pixels(84, 16, 80_000, 0);
    for hint in [
        None,
        Some(ContentRect {
            x: 0,
            y: 0,
            width: width as u32,
            height: height as u32,
        }),
    ] {
        let mut session = CalibratedSession::new(&dir.0).unwrap();
        if let Some(hint) = hint {
            assert!(session.set_hint(hint));
        }
        for (index, start) in [0, 12, 24, 36, 108, 180, 250].into_iter().enumerate() {
            let mut frame = document[start * stride..(start + height) * stride].to_vec();
            for row in 0..16 {
                let offset = (overlay_top + row) * stride + 116 * 4;
                frame[offset..offset + 84 * 4]
                    .copy_from_slice(&overlay[row * 84 * 4..(row + 1) * 84 * 4]);
            }
            let progress = session.append(&frame, width, height, stride).unwrap();
            assert_eq!(
                progress.disposition,
                if index < 3 { 4 } else { 0 },
                "offset {start}, hint {hint:?}"
            );
        }
        let rect = session.rect.unwrap();
        assert!(session.excluded_bottom_overlay);
        assert!(rect.y + rect.height <= overlay_top as u32);
        let name = if hint.is_some() {
            "hinted.png"
        } else {
            "inferred.png"
        };
        let output = dir.0.join(name);
        session.finish(&output).unwrap();
        let (w, h, stitched) = decode_png(&output);
        assert_eq!((w, h), (rect.width as usize, rect.height as usize + 250));
        let expected: Vec<_> = (rect.y as usize..rect.y as usize + h)
            .flat_map(|y| {
                let offset = y * stride + rect.x as usize * 4;
                document[offset..offset + w * 4].iter().copied()
            })
            .collect();
        assert!(
            stitched == expected,
            "stitched pixels differ for hint {hint:?}"
        );
    }
}

#[test]
fn calibrated_capture_excludes_a_small_fixed_button_over_moving_rows() {
    let dir = TestDirectory::new();
    let (width, height, button_x, button_top) = (512, 288, 249, 261);
    let (button_width, button_height) = (14, 12);
    let stride = width * 4;
    let button = pixels(button_width, button_height, 90_000, 0);
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    for start in [0, 18, 36, 54, 128, 202] {
        let mut frame = pixels(width, height, start, 0);
        for y in 0..button_height {
            let to = (button_top + y) * stride + button_x * 4;
            let from = y * button_width * 4;
            frame[to..to + button_width * 4]
                .copy_from_slice(&button[from..from + button_width * 4]);
        }
        session.append(&frame, width, height, stride).unwrap();
    }
    assert!(session.excluded_bottom_overlay);
    let output = dir.0.join("fixed-button.png");
    session.finish(&output).unwrap();
    let (w, h, stitched) = decode_png(&output);
    assert_eq!((w, h), (width, button_top + 202));
    assert!(
        stitched == pixels(width, h, 0, 0),
        "the fixed button was stitched into the moving content"
    );
}

#[test]
fn matching_does_not_require_ink_in_every_third_of_the_overlap() {
    let dir = TestDirectory::new();
    let mut session = Session::new(&dir.0).unwrap();
    let (width, height, step) = (192, 216, 25);
    let mut document = pixels(width, height + step, 0, 0);
    document[width * 4 * 85..width * 4 * 160].fill(0xee);
    session.append(&document, width, height, width * 4).unwrap();
    let progress = session
        .append(&document[width * 4 * step..], width, height, width * 4)
        .unwrap();
    assert_eq!(
        (progress.disposition, progress.height),
        (0, (height + step) as u32)
    );
}

#[test]
fn shallow_pinned_header_keeps_nearby_alignment_evidence() {
    let (width, height, shift, header) = (192, 384, 100, 30);
    let stride = width * 4;
    let mut document = vec![240; stride * (height + shift)];
    for (start, end) in [(shift + 32, shift + 48), (shift + 220, shift + 226)] {
        document[start * stride..end * stride].copy_from_slice(&pixels(
            width,
            end - start,
            start,
            0,
        ));
    }
    let fixed = pixels(width, header, 2_000, 0);
    let viewport = |start: usize| {
        let mut frame = document[start * stride..(start + height) * stride].to_vec();
        frame[..header * stride].copy_from_slice(&fixed);
        frame
    };
    let previous = viewport(0);
    let current = viewport(shift);
    let a = FrameView::new(&previous, width, height, stride).unwrap();
    let b = FrameView::new(&current, width, height, stride).unwrap();
    let previous = Frame::from_view(&a, a.signature());
    assert_eq!(
        displacement(&previous, &b, &b.signature(), MatchOptions::CALIBRATED),
        Some(shift)
    );
}

#[test]
fn calibrated_capture_crops_fixed_edges_and_replays_initial_content_exactly() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    let rect = ContentRect {
        x: 40,
        y: 20,
        width: 176,
        height: 160,
    };
    for (index, start) in [0, 24, 48, 72, 96, 120].iter().enumerate() {
        let raw = decorated_frame(256, 200, rect, *start);
        let progress = session.append(&raw, 256, 200, 1024).unwrap();
        assert_eq!(progress.disposition, if index < 3 { 4 } else { 0 });
    }
    assert_eq!(session.rect, Some(rect));
    let output = dir.0.join("calibrated.png");
    let progress = session.finish(&output).unwrap();
    assert_eq!((progress.width, progress.height), (176, 280));
    let (w, h, actual) = decode_png(&output);
    assert_eq!(actual, pixels(w, h, 0, 0));
}

#[test]
fn calibrated_capture_preserves_clean_full_frame_and_ignores_duplicate_evidence() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    for start in [0, 0, 20, 20, 40, 60] {
        session
            .append(&pixels(96, 128, start, 0), 96, 128, 384)
            .unwrap();
    }
    assert_eq!(
        session.rect,
        Some(ContentRect {
            x: 0,
            y: 0,
            width: 96,
            height: 128
        })
    );
    let output = dir.0.join("full.png");
    session.finish(&output).unwrap();
    let (w, h, actual) = decode_png(&output);
    assert_eq!((w, h), (96, 188));
    assert_eq!(actual, pixels(w, h, 0, 0));
}

#[test]
fn calibrated_capture_stitches_past_a_header_that_becomes_sticky() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    let (width, height) = (256, 192);
    let stride = width * 4;
    let header_start = 64;
    let header = pixels(width, 58, header_start, 0);
    let viewport = |start| {
        let mut frame = pixels(width, height, start, 0);
        if start > header_start {
            for y in 0..58 {
                let portion = y * stride + 16 * 4..y * stride + 160 * 4;
                frame[portion.clone()].copy_from_slice(&header[portion]);
            }
        }
        frame
    };

    for (index, start) in [0, 16, 32, 48, 80, 144, 208, 256].into_iter().enumerate() {
        let progress = session
            .append(&viewport(start), width, height, stride)
            .unwrap();
        assert_eq!(
            progress.disposition,
            if index < 3 { 4 } else { 0 },
            "offset {start}"
        );
        assert_eq!(
            progress.height,
            (height + if index < 3 { 0 } else { start }) as u32
        );
    }
    let disconnected = session
        .append(&viewport(1000), width, height, stride)
        .unwrap();
    assert_eq!(disconnected.disposition, 2);

    let mut altered = viewport(296);
    altered[80 * stride + 32] ^= 0xff;
    assert_eq!(
        session
            .append(&altered, width, height, stride)
            .unwrap()
            .disposition,
        2
    );

    // The first frame that overlaps again still has the pinned toolbar.
    let resumed = session
        .append(&viewport(296), width, height, stride)
        .unwrap();
    assert_eq!(
        (resumed.disposition, resumed.height),
        (0, (height + 296) as u32)
    );

    let output = dir.0.join("sticky.png");
    session.finish(&output).unwrap();
    let (w, h, actual) = decode_png(&output);
    assert_eq!((w, h), (width, height + 296));
    assert_eq!(actual, pixels(w, h, 0, 0));
}

#[test]
fn manual_scroll_accelerates_from_one_pixel_to_fast_overlapping_steps() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    let rect = ContentRect {
        x: 20,
        y: 16,
        width: 96,
        height: 128,
    };
    for start in [0, 1, 7, 35, 94, 174, 254, 261] {
        let frame = decorated_frame(144, 160, rect, start);
        session.append(&frame, 144, 160, 576).unwrap();
    }
    let output = dir.0.join("manual.png");
    session.finish(&output).unwrap();
    let (w, h, actual) = decode_png(&output);
    assert_eq!((w, h), (96, 389));
    assert_eq!(actual, pixels(w, h, 0, 0));
}

#[test]
fn transient_repaint_before_scrolling_does_not_discard_the_start() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    for (index, start) in [0, 0, 24, 60, 110].into_iter().enumerate() {
        let mut frame = pixels(96, 128, start, 0);
        if index == 1 {
            // A hover highlight repaints without moving the document.
            frame[384 * 60..384 * 72].fill(255);
        }
        session.append(&frame, 96, 128, 384).unwrap();
    }
    let output = dir.0.join("repaint.png");
    session.finish(&output).unwrap();
    let (w, h, actual) = decode_png(&output);
    assert_eq!((w, h), (96, 238));
    assert_eq!(actual, pixels(w, h, 0, 0));
}

#[test]
fn calibrated_capture_rejects_periodic_and_unrelated_animation() {
    for periodic in [true, false] {
        let dir = TestDirectory::new();
        let mut session = CalibratedSession::new(&dir.0).unwrap();
        for n in 0..5 {
            let raw = if periodic {
                (0..128)
                    .flat_map(|y| pixels(96, 1, (y + n * 3) % 16, 0))
                    .collect()
            } else {
                pixels(96, 128, n * 1000, 0)
            };
            let result = session.append(&raw, 96, 128, 384).unwrap();
            if n == 4 {
                assert_eq!(result.disposition, 2);
            }
        }
        assert!(session.rect.is_none());
        assert!(session.finish(&dir.0.join("bad.png")).is_err());
    }
}

#[test]
fn calibrated_capture_does_not_treat_blank_static_background_as_motion() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    let raw = vec![255; 96 * 128 * 4];
    for _ in 0..8 {
        assert_eq!(session.append(&raw, 96, 128, 384).unwrap().disposition, 4);
    }
    assert!(session.rect.is_none());
    assert!(session.finish(&dir.0.join("blank.png")).is_err());
}

#[test]
fn calibrated_ffi_reports_only_verified_input_pixel_bounds() {
    let dir = TestDirectory::new();
    let directory = std::ffi::CString::new(dir.0.to_str().unwrap()).unwrap();
    let mut error = [0 as c_char; 256];
    let handle = unsafe {
        sx_stitcher_create_calibrated(directory.as_ptr(), error.as_mut_ptr(), error.len())
    };
    assert!(!handle.is_null());
    let mut rect = ContentRect {
        x: 0,
        y: 0,
        width: 0,
        height: 0,
    };
    assert_eq!(unsafe { sx_stitcher_content_rect(handle, &mut rect) }, 0);
    let expected = ContentRect {
        x: 32,
        y: 16,
        width: 128,
        height: 128,
    };
    for start in [0, 16, 32, 48] {
        let bytes = decorated_frame(192, 160, expected, start);
        let mut progress = Progress {
            width: 0,
            height: 0,
            disposition: 0,
        };
        assert_eq!(
            unsafe {
                sx_stitcher_append(
                    handle,
                    bytes.as_ptr(),
                    bytes.len(),
                    192,
                    160,
                    768,
                    &mut progress,
                    error.as_mut_ptr(),
                    error.len(),
                )
            },
            0
        );
    }
    assert_eq!(unsafe { sx_stitcher_content_rect(handle, &mut rect) }, 1);
    assert_eq!(rect, expected);
    assert_eq!(
        unsafe { sx_stitcher_content_rect(handle, std::ptr::null_mut()) },
        -1
    );
    unsafe { sx_stitcher_destroy(handle) };
}

#[test]
fn calibrated_capture_rejects_independent_panes_moving_different_distances() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    let rect = ContentRect {
        x: 32,
        y: 16,
        width: 128,
        height: 128,
    };
    for n in 0..5 {
        let mut raw = decorated_frame(192, 160, rect, n * 16);
        let right = pixels(64, 128, n * 24, 0);
        for y in 0..128 {
            let p = ((y + 16) * 192 + 96) * 4;
            raw[p..p + 64 * 4].copy_from_slice(&right[y * 64 * 4..(y + 1) * 64 * 4]);
        }
        session.append(&raw, 192, 160, 768).unwrap();
    }
    assert!(session.rect.is_none());
    assert!(session.finish(&dir.0.join("two-panes.png")).is_err());
}

#[test]
fn calibrated_content_votes_allow_pixels_unchanged_in_one_moving_pair() {
    let dir = TestDirectory::new();
    let mut session = CalibratedSession::new(&dir.0).unwrap();
    let rect = ContentRect {
        x: 40,
        y: 20,
        width: 176,
        height: 160,
    };
    for start in [0, 4, 8, 12] {
        let mut raw = decorated_frame(256, 200, rect, start);
        // A mostly flat/repeating document is still identifiable from its unique
        // rail. Most body pixels change in two pairs, never all three pairs.
        for y in 0..160 {
            for x in 24..176 {
                let shade = if (y + start) % 3 == 2 { 234 } else { 220 };
                let p = ((y + 20) * 256 + x + 40) * 4;
                raw[p..p + 4].copy_from_slice(&[shade, shade, shade, 255]);
            }
        }
        session.append(&raw, 256, 200, 1024).unwrap();
    }
    assert_eq!(session.rect, Some(rect));
    let output = dir.0.join("voted.png");
    let progress = session.finish(&output).unwrap();
    assert_eq!((progress.width, progress.height), (176, 172));
}
