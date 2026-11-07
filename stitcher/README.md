# Appshot stitching library

The Rust library aligns overlapping BGRA screenshots into one vertical PNG. Swift owns the capture session and borrows frame bytes synchronously through `Sources/CStitcher/include/ScreenshotXStitcher.h`. `StitchingSession` serializes append, finish and cancellation.

Build with `cargo build --release --manifest-path stitcher/Cargo.toml`; run `cargo test --manifest-path stitcher/Cargo.toml`. Link the static archive with the macOS system `z` library. No crates, browser component, network client or extra runtime are required.

The processor samples luminance to find a unique forward offset, verifies that match against color pixels and rejects ambiguous results. It keeps the last accepted frame plus bounded sampling data. Accepted rows are appended to a scratch file; final PNG encoding reads one row at a time and uses incremental system-zlib compression. Publication uses a temporary file and a same-directory hard link to avoid overwriting existing output. Cancellation removes only the library-owned scratch file.

The alpha accepts a downward, fixed-size region 16–4096 pixels wide, at least 32 pixels tall, at most 32 MiB decoded per frame. Output is capped at 100 million pixels and capture duration at two minutes. Include overlapping content when scrolling. Uniform/repeated content, persistent headers and animation may require a smaller region or reconnection. Those cases are rejected conservatively; arbitrary document layout reconstruction is not implemented.

Tests verify synthetic alignment, padded row strides, reverse and duplicate frames, repeated-content rejection, nonoverlap and sticky-header rejection, invalid input, limits, cleanup, and complete PNG output decoded through zlib with independently checked chunk checksums. Swift integration tests additionally decode the PNG using Apple's Image I/O. Live capture behavior must be verified in the application.
