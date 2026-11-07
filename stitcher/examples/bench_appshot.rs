//! Focused end-to-end benchmark with a deterministic text-like document.
//! macOS peak process RSS is reported using getrusage; includes fixture generation.
use screenshotx_stitcher::Session;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

#[cfg(target_os = "macos")]
fn peak_rss_bytes() -> i64 {
    #[repr(C)]
    struct TimeVal {
        seconds: std::ffi::c_long,
        micros: std::ffi::c_int,
    }
    #[repr(C)]
    struct RUsage {
        user: TimeVal,
        system: TimeVal,
        values: [std::ffi::c_long; 14],
    }
    unsafe extern "C" {
        fn getrusage(who: std::ffi::c_int, usage: *mut RUsage) -> std::ffi::c_int;
    }
    let mut usage: RUsage = unsafe { std::mem::zeroed() };
    if unsafe { getrusage(0, &mut usage) } == 0 {
        usage.values[0]
    } else {
        -1
    }
}
#[cfg(not(target_os = "macos"))]
fn peak_rss_bytes() -> i64 {
    -1
}

fn viewport(width: usize, height: usize, start: usize) -> Vec<u8> {
    let mut pixels = vec![255; width * height * 4];
    for y in 0..height {
        let doc_y = start + y;
        let line = doc_y / 28;
        let glyph_y = doc_y % 28;
        for x in 120..width - 120 {
            let character = (x - 120) / 10;
            let glyph_x = (x - 120) % 10;
            let mut seed =
                (line as u32).wrapping_mul(0x119de1f3) ^ (character as u32).wrapping_mul(0x45d9f3b);
            seed ^= seed >> 16;
            seed = seed.wrapping_mul(0x45d9f3b);
            let line_length = 65 + (line * 37 % 90);
            let ink = character < line_length
                && glyph_y < 16
                && glyph_x < 7
                && ((seed.rotate_left((glyph_y / 2 * 3 + glyph_x) as u32) & 1) == 1);
            if ink {
                let offset = (y * width + x) * 4;
                pixels[offset..offset + 3].copy_from_slice(&[35, 32, 30]);
            }
        }
    }
    pixels
}

fn main() -> Result<(), String> {
    let directory = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::temp_dir().join(format!("screenshotx-benchmark-{}", std::process::id()))
        });
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    let began = Instant::now();
    let mut session = Session::new(&directory)?;
    let mut append_time = Duration::ZERO;
    let mut accepted = 0;
    for frame in 0..54 {
        let bytes = viewport(1920, 1080, frame * 360);
        let t = Instant::now();
        let progress = session.append(&bytes, 1920, 1080, 1920 * 4)?;
        append_time += t.elapsed();
        if progress.disposition != 0 {
            return Err(format!(
                "Unexpected rejection of text-like frame {frame}: {progress:?}"
            ));
        }
        accepted += 1;
    }
    let destination = directory.join("appshot-1920x20160.png");
    let t = Instant::now();
    let output = session.finish(&destination)?;
    let encode_time = t.elapsed();
    let total = began.elapsed();
    let size = std::fs::metadata(&destination)
        .map_err(|e| e.to_string())?
        .len();
    println!(
        "frames={accepted} dimensions={}x{} append_ms={:.1} encode_ms={:.1} total_ms={:.1} png_bytes={size} peak_process_rss_bytes={} output={}",
        output.width,
        output.height,
        append_time.as_secs_f64() * 1000.0,
        encode_time.as_secs_f64() * 1000.0,
        total.as_secs_f64() * 1000.0,
        peak_rss_bytes(),
        destination.display()
    );
    Ok(())
}
