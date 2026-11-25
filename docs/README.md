# Developer guide

Karuto is a macOS application written in Swift, with a Rust library for scrolling-image stitching. [Development and testing](development.md) covers setup and verification.

## Code organization

| Directory | Responsibility |
| --- | --- |
| `Sources/Karuto/App` | Application lifecycle, settings, shortcuts, and `CaptureCoordinator`, which owns capture sessions. |
| `Sources/Karuto/UI` | Capture overlay, annotations, controls, settings views, and result previews. |
| `Sources/Karuto/Capture` | ScreenCaptureKit capture, display geometry, frozen frames, and text recognition. |
| `Sources/Karuto/Appshots` | Scrolling input, pane discovery, and the Swift stitching session. |
| `Sources/Karuto/Storage` | Capture files and clipboard publication. |
| `Sources/Karuto/Shared` | Capture targets, options, and artifact models shared across components. |
| `Sources/Karuto/CLI` | Noninteractive commands and their output. See the [CLI reference](cli/README.md). |
| `Sources/CStitcher` and `stitcher` | C interface and Rust image alignment and PNG encoding. See the [stitcher guide](../stitcher/README.md). |
| `Tests/KarutoTests` | Swift tests for application behavior and integration. Rust tests live in `stitcher/src/tests.rs`. |

## Capture flow

`Application` opens capture through `CaptureCoordinator`. The coordinator presents `CaptureUIController`, which gathers a target and capture options. For a screenshot, the coordinator asks `CaptureEngine` for an image, composites annotations when applicable, and passes the result to storage, clipboard, and preview actions. Recording uses the same coordinator and capture engine for the stream lifecycle.

Scrolling capture sends frames from the capture engine to `StitchingSession`. The session calls the Rust library through `CStitcher`, where frames are aligned and output is assembled on disk. `ScrollRegionResolver` supplies Accessibility-based suggestions, while the stitcher verifies moving content using pixels. See the stitcher guide for limits and calibration details.

Capture target geometry crossing modules uses global AppKit screen points with a bottom-left origin. `Capture` converts coordinates for ScreenCaptureKit. Stitcher crop coordinates use input pixels with a top-left origin. Area annotations use bottom-left coordinates relative to the selection.

The [keymap guide](keymap.md) explains shortcut registration, persistence, and dispatch.
