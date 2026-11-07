use super::*;
use std::io::Read;

struct TestDirectory(PathBuf);
impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "screenshotx-stitch-test-{}-{}",
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
