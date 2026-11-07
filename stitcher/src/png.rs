//! Streaming PNG writer using the operating system's zlib. Working memory is one
//! scanline and a fixed compression buffer; no complete output image is allocated.
use std::ffi::{c_char, c_int, c_uint, c_ulong, c_void};
use std::io::{Read, Write};
use std::ptr;

#[repr(C)]
struct ZStream {
    next_in: *mut u8,
    avail_in: c_uint,
    total_in: c_ulong,
    next_out: *mut u8,
    avail_out: c_uint,
    total_out: c_ulong,
    msg: *mut c_char,
    state: *mut c_void,
    zalloc: Option<unsafe extern "C" fn(*mut c_void, c_uint, c_uint) -> *mut c_void>,
    zfree: Option<unsafe extern "C" fn(*mut c_void, *mut c_void)>,
    opaque: *mut c_void,
    data_type: c_int,
    adler: c_ulong,
    reserved: c_ulong,
}

#[link(name = "z")]
unsafe extern "C" {
    fn zlibVersion() -> *const c_char;
    fn deflateInit_(
        stream: *mut ZStream,
        level: c_int,
        version: *const c_char,
        size: c_int,
    ) -> c_int;
    fn deflate(stream: *mut ZStream, flush: c_int) -> c_int;
    fn deflateEnd(stream: *mut ZStream) -> c_int;
    fn crc32(initial: c_ulong, bytes: *const u8, length: c_uint) -> c_ulong;
    #[cfg(test)]
    pub(crate) fn uncompress(
        out: *mut u8,
        out_len: *mut c_ulong,
        input: *const u8,
        input_len: c_ulong,
    ) -> c_int;
}

struct Compressor {
    stream: Box<ZStream>,
}

impl Compressor {
    fn new() -> Result<Self, String> {
        // zlib stores a pointer to this structure: keep its address stable.
        let mut stream: Box<ZStream> = Box::new(unsafe { std::mem::zeroed() });
        let code = unsafe {
            deflateInit_(
                &mut *stream,
                3,
                zlibVersion(),
                std::mem::size_of::<ZStream>() as c_int,
            )
        };
        if code != 0 {
            return Err(format!("Could not initialize PNG compression ({code})."));
        }
        Ok(Self { stream })
    }
    fn push(
        &mut self,
        data: &[u8],
        finish: bool,
        destination: &mut impl Write,
    ) -> Result<(), String> {
        self.stream.next_in = if data.is_empty() {
            ptr::null_mut()
        } else {
            data.as_ptr().cast_mut()
        };
        self.stream.avail_in = data.len() as c_uint;
        let mut output = [0u8; 64 * 1024];
        loop {
            self.stream.next_out = output.as_mut_ptr();
            self.stream.avail_out = output.len() as c_uint;
            let result = unsafe { deflate(&mut *self.stream, if finish { 4 } else { 0 }) };
            if result != 0 && result != 1 {
                return Err(format!("PNG compression failed ({result})."));
            }
            let emitted = output.len() - self.stream.avail_out as usize;
            if emitted > 0 {
                chunk(destination, b"IDAT", &output[..emitted])?;
            }
            if result == 1 || (!finish && self.stream.avail_in == 0 && self.stream.avail_out > 0) {
                break;
            }
        }
        // Do not retain a borrowed caller buffer after this call.
        self.stream.next_in = ptr::null_mut();
        self.stream.avail_in = 0;
        Ok(())
    }
}

impl Drop for Compressor {
    fn drop(&mut self) {
        unsafe {
            deflateEnd(&mut *self.stream);
        }
    }
}

fn chunk(destination: &mut impl Write, kind: &[u8; 4], data: &[u8]) -> Result<(), String> {
    let mut checksum = unsafe { crc32(0, kind.as_ptr(), 4) };
    checksum = unsafe { crc32(checksum, data.as_ptr(), data.len() as c_uint) };
    destination
        .write_all(&(data.len() as u32).to_be_bytes())
        .map_err(|e| e.to_string())?;
    destination.write_all(kind).map_err(|e| e.to_string())?;
    destination.write_all(data).map_err(|e| e.to_string())?;
    destination
        .write_all(&(checksum as u32).to_be_bytes())
        .map_err(|e| e.to_string())
}

pub(crate) fn encode(
    input: &mut impl Read,
    destination: &mut impl Write,
    width: u32,
    height: u32,
) -> Result<(), String> {
    destination
        .write_all(b"\x89PNG\r\n\x1a\n")
        .map_err(|e| e.to_string())?;
    let mut header = [0u8; 13];
    header[..4].copy_from_slice(&width.to_be_bytes());
    header[4..8].copy_from_slice(&height.to_be_bytes());
    header[8] = 8;
    header[9] = 6; // RGBA, 8-bit, standard compression/filter, non-interlaced.
    chunk(destination, b"IHDR", &header)?;
    chunk(destination, b"sRGB", &[0])?;
    let mut compressor = Compressor::new()?;
    let mut source = vec![0u8; width as usize * 4];
    let mut filtered = vec![0u8; source.len() + 1];
    filtered[0] = 1; // Sub filter for text-heavy captures.
    for _ in 0..height {
        input
            .read_exact(&mut source)
            .map_err(|e| format!("Could not read captured rows: {e}"))?;
        let mut previous = [0u8; 4];
        for (pixel, encoded) in source
            .chunks_exact(4)
            .zip(filtered[1..].chunks_exact_mut(4))
        {
            let alpha = pixel[3];
            let straighten = |channel: u8| {
                if alpha == 0 {
                    0
                } else {
                    ((channel as u32 * 255 + alpha as u32 / 2) / alpha as u32).min(255) as u8
                }
            };
            let rgba = [
                straighten(pixel[2]),
                straighten(pixel[1]),
                straighten(pixel[0]),
                alpha,
            ];
            for channel in 0..4 {
                encoded[channel] = rgba[channel].wrapping_sub(previous[channel]);
            }
            previous = rgba;
        }
        compressor.push(&filtered, false, destination)?;
    }
    compressor.push(&[], true, destination)?;
    chunk(destination, b"IEND", &[])?;
    destination.flush().map_err(|e| e.to_string())
}
