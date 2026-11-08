# Karuto initial implementation plan

Plan date: 7 November 2026. Status: implemented alpha; this document records the initial scope. Later additions include automatic scrolling with manual fallback, accessible pane suggestions, and motion-verified exclusion of static outer chrome. For current contracts and evidence, use [architecture](agents/architecture.md#scrolling-pane-discovery-and-verification), [CLI](cli/README.md), and [validation](alpha-validation.md#motion-verified-scrolling-capture).

Build a small native Mac capture utility with a reference-inspired capture toolbar and corner preview. The first release captures screenshots, records the screen with audio, and produces vertical scrolling appshots from browser pages and native Mac apps. All capture and processing stays local. Browser extensions, browser automation, embedded browsers, and remote debugging connections are excluded.

## Decisions

| Decision | Initial choice |
| --- | --- |
| Platform | macOS 15 or later; Apple Silicon arm64 release first |
| Native application | Swift 6, AppKit, Core Animation; one app target |
| Capture | ScreenCaptureKit: SCScreenshotManager for images, SCStream for recording and scrolling capture |
| Video output | SCRecordingOutput, SDR H.264 MP4; validate audio combinations before building recording UI |
| Image output | Image I/O for ordinary PNG screenshots; incremental PNG output for scrolling captures |
| Image processing | One Rust static library for alignment, stitching and incremental scrolling-image output |
| Distribution | Signed and notarized direct-download app; development signing during implementation |
| Persistence | UserDefaults settings, local capture files, tiny session metadata; no database |
| UI reference | Product capture interface research; exact initial surfaces specified below |

The platform and release architecture are planning defaults. Supporting Intel or macOS before 15 is a later decision, not a prerequisite for the first implementation. The current workspace has Swift and Rust toolchains; milestone 0 verifies the complete app build/signing setup.

Apple provides [single-frame capture](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) and [direct recording output](https://developer.apple.com/documentation/screencapturekit/screcordingoutput). The installed SDK confirms SCRecordingOutput and microphone capture are available on macOS 15. Its explicit audio mixing configuration is newer; do not accidentally use that property without availability checks or assume identical audio behavior across OS versions.

## First release scope

| Capability | Behavior to ship |
| --- | --- |
| Area screenshot | Drag selection, dimension readout, resize before capture, Escape to cancel, PNG at native pixel resolution |
| Display screenshot | Capture the display under the pointer |
| Window screenshot | Hover highlight and click to choose a window; transparent surround; optional native shadow |
| Previous area | Repeat the last valid area on its original display; ask for a fresh selection if display geometry changed |
| Timer | Three-second delay after selection so the user can arrange transient content |
| Capture toolbar | Area, Fullscreen, Window, Scrolling, Timer, Recording; width/height controls for area selection |
| Immediate results | Corner thumbnail; copy image, save as, drag file, reveal in Finder, dismiss; video opens in the default player |
| Recording | Display/window/area; 30 fps SDR H.264 MP4; microphone and system-audio switches; cursor switch; start, stop, cancel |
| Scrolling appshot | User selects one scrollable region and manually scrolls downward; app aligns overlapping frames into a PNG |
| Basic settings | Shortcut, save folder, screenshot auto-save, window shadow, recorder resolution, audio inputs, countdown |

Recording defaults to a maximum output size of 1920 × 1080 while preserving aspect ratio and never upscaling. Offer native-resolution recording only within encoder-supported limits. Screenshots preserve native resolution independently of recording preferences.

Ship screenshots and recording as usable intermediate milestones. Manual vertical appshots are required to complete this plan. Horizontal and automatic scrolling, GIF, pause/resume, camera overlays, click/keystroke effects, OCR, markup, backgrounds, pins and a persistent history browser are subsequent work. Do not render inactive controls for them.

## Interface specification

Use the reference product’s visible layout, density, rounded dark capture surfaces, icon-above-label mode buttons, selected-mode treatment, and separate dimension panel as the design reference. Reimplement the interface with AppKit views, system text and SF Symbols where suitable. Use Karuto's own name and icon.



### Menu bar and capture toolbar

- Launch as a menu bar utility. No permanent main window or Dock presence during ordinary use.
- Menu entries: Open Capture Toolbar, Capture Previous Area, Settings, Quit. While recording, expose Stop Recording prominently.
- Default shortcut: Control-Shift-2 for the toolbar; configurable and registered only if available. Report conflicts without changing another application's shortcut.
- Toolbar appears on the pointer's display, anchored near its lower center and constrained to the visible screen bounds.
- Match the reference's two-part composition: capture modes on the left and compact width/height fields on the right. Hide dimensions for modes that do not use an area. Timer is selected through its mode button.
- Use rounded corners, a restrained border/shadow, system typography and a brighter rounded selected segment. Match light/dark system appearance and Reduce Transparency. Tune dimensions against the reference during UI verification rather than claiming the marketing image specifies points exactly.
- Tab navigates controls; Enter confirms a valid selection; Escape cancels. Expose accessible labels and selected states.

### Selection overlay

- One lightweight overlay per display during selection; dim everything outside the active selection. Show a crosshair, selection border and dimensions.
- Constrain an area to one display for this release. Multiple displays are supported as separate targets; cross-display rectangles are deferred.
- Convert AppKit screen points, display-local capture coordinates and output pixels in one geometry implementation. Do not scatter scale or Y-axis corrections through views.
- Exclude all Karuto selection, preview and recording windows from captured pixels. Test absence of controls in the resulting file, not just in the preview.
- Window mode highlights an actual capture target; the app's own windows are never candidates.

### Corner result preview

- Small rounded panel at bottom-right of the capture display, following the compact preview pattern described in the product research.
- Show a thumbnail and type/dimensions or duration. Hover exposes Copy, Save, Reveal and Dismiss; video uses Open instead of image Copy. Dragging provides a local file URL.
- Keep at most three previews, ordered newest first. Closing a preview does not delete an explicitly saved file.
- A large scrolling capture is represented by a downsampled thumbnail. Use Save/drag for its full output; image-to-clipboard is limited by a decoded-size budget so a giant clipboard image cannot defeat memory limits.
- Preview dismissal releases image buffers. A lightweight file record remains available for restoring the most recently dismissed result until app exit or temporary-file cleanup.

### Recording controls

- Before recording: select target, microphone device, system audio, cursor visibility and resolution. Three-second countdown is cancellable.
- During recording: compact floating panel with red recording indicator, elapsed time and Stop; also expose Stop in the menu bar.
- Start the elapsed timer only when recording actually starts. After Stop, show Finishing until the output delegate confirms the file is ready.
- No pause button in this version. Do not suggest that stopping and restarting a stream is seamless pause/resume.

### Scrolling controls

- After selecting the content rectangle, show a compact Start / Finish / Cancel panel outside it. Pass pointer and scroll input through to the underlying app during capture.
- Instruction: “Scroll down slowly, keeping some previous content visible.” Display accepted height and a small progress thumbnail.
- When movement is too large or alignment is ambiguous, pause appending and say “Scroll back slightly to reconnect.” Preserve the last accepted content.
- Finish produces a local PNG and the normal result preview. Cancel stops capture and removes this unfinished session's temporary data.

The local image named `screenshot-workflow.png` in the research actually depicts Annotate and its Background Tool. It is not an initial capture-window specification. This release uses the capture toolbar and workflow references, without implementing that editor.

## Architecture and ownership

```text
AppKit UI and shortcut handling
             |
       CaptureCoordinator
        /       |       \
 Screenshot  Recording  ScrollingSession
        \       |         |       \
         ScreenCaptureKit |     Rust Stitcher
                          |          |
                    Local capture files
                          |
                 Thumbnail / save / drag
```

| Module | Owns |
| --- | --- |
| App | MainActor UI, shortcuts, settings and CaptureCoordinator state |
| Capture | Permissions, target discovery, geometry, SCScreenshotManager, SCStream and recording output lifecycle |
| Appshots | Scrolling-session frame selection and the narrow Rust bridge |
| Storage | Temporary sessions, final capture files, bounded previews, atomic publication and cleanup |

Keep these as source folders rather than separate Swift packages. Add the Rust library when implementing appshots; basic capture should build and run first. Do not introduce generic providers or an event bus.

Use an explicit operation enum for idle, selecting, preparing, screenshot capture, recording, scrolling, finalizing and failure. Only one capture operation owns resources at a time. Each operation has an ID so late callbacks from cancelled work cannot update the next operation. All exits release streams and buffers; failure keeps any recoverable finalized output and reports what the user can do next.

Sample callbacks use dedicated serial queues. They do not execute UI updates or spawn an unbounded Task per frame. Swift owns Apple objects. Rust receives a validated pixel descriptor with dimensions, row stride and format; borrowed memory is valid only for the synchronous call. Any retained working data is explicitly copied into a bounded Rust-owned allocation. No Swift object or CMSampleBuffer crosses the C interface.

Use opaque Rust session handles and status codes; cancellation and destruction are idempotent. Panics must not unwind into Swift. Prefer safe Rust except the audited pointer conversion at the bridge. Link the library statically; there is no Rust daemon.

## Appshot algorithm

The same native capture path handles browser windows and Mac apps. It requires no DOM access, extension, login automation or browser process. The user scrolls content into view; unloaded content is captured only once the target app renders it. If scrolling causes the target app to fetch data, Karuto itself still performs no network request.

1. Select a fixed content region and capture its initial frame. Ask the user to exclude sidebars and persistent headers where possible.
2. During the active session, inspect a bounded, low-rate stream of candidate frames. Accept only stable complete frames with sufficient overlap; ignore idle duplicates.
3. Estimate vertical displacement using reduced-resolution luminance strips. Refine the best candidate at native resolution and require a distinct confident match across multiple bands.
4. Detect stationary edge bands so common fixed headers/footers do not become the alignment signal. Treat uncertain layouts, animated regions and ambiguous repeated text as a recoverable pause rather than guessing a seam.
5. Append only new rows. Keep a small overlap tail and bounded frame working set; write accepted strips to a session file. Do not repeatedly allocate and copy an ever-growing image.
6. On Finish, stream rows into a PNG encoder after final dimensions are known. Do not assume Image I/O will provide bounded-memory encoding of an arbitrary giant bitmap; choose a small Rust PNG encoder with incremental row support and verify that behavior.
7. Publish the completed PNG, then remove scratch strips. Build previews incrementally or by bounded downsampling.

Initial limits: one scroll region, downward vertical movement, maximum width 4096 pixels, total 100 million pixels, 1 GiB scratch budget, two minutes per capture. These are visible product limits, not silent downscaling. Stop before exceeding a limit and offer Finish for accepted content. Slight reverse scrolling is allowed only for overlap recovery; it must not append duplicate rows.

Test repeated lines, sticky headers, lazy loading, partial overlaps, animated cursors, scaling, duplicate frames, fast jumps, reverse recovery and nonuniform row strides. Native apps and browser pages share the same tests for accepted strips. Virtualized and infinite content have no meaningful universal “full document”; Finish and configured limits define the result.

## Recording and output correctness

Use SCRecordingOutput initially, with explicit SDR H.264/MP4 configuration and supported size/codec checks. Offer no audio, microphone, system audio, and both. Prove all four combinations on the minimum supported OS and the current OS before committing the recording UI. Confirm both voices play in ordinary players and remain synchronized over a long recording; a file merely containing two tracks is not sufficient proof.

If direct recording cannot produce compatible combined audio on macOS 15, first test localized AVFoundation audio mixing during finalization. If that cannot meet correctness and latency requirements, replace only the Recording implementation with an AVAssetWriter path. Keep the choice within milestone 0; do not build two production writers speculatively or silently remove combined audio.

Write into a uniquely named session directory. The UI receives a completed artifact only after encoding/recording finalization succeeds and the final file is published atomically on the same volume. A user-selected save destination on another volume uses copy-to-temporary plus rename there. Disk-full and target-loss errors must not display a corrupt artifact as successful.

Saved user files are never removed by preview cleanup. Unfinished scratch data is cleaned on next launch. Unclaimed completed captures expire after 24 hours under a 512 MiB temporary-results budget; preserve active drag operations and never interrupt recording to evict its output. Large completed results prompt for a permanent destination. Stopping, quitting and cancelling have explicit cleanup paths.

## Performance budgets

Budgets are acceptance targets to measure in optimized builds on a named Apple Silicon reference Mac, not claims about framework performance. Record hardware, macOS, resolution, scaling and audio configuration with results.

| Measurement | Initial target |
| --- | --- |
| Installed arm64 release app | Under 20 MiB, excluding captures and external debug symbols |
| Idle CPU | Below 0.5% of one core averaged over 60 seconds; no capture stream while idle |
| Idle physical footprint | Aim below 50 MiB after closing previews |
| Warm shortcut to visible selector | p95 below 50 ms over 30 invocations |
| Selection completion to screenshot preview | p95 below 200 ms for a 1920 × 1080 capture after permission setup; measure Retina separately |
| 1080p30 recording | Starting budget below 10% of one core averaged over 60 seconds, excluding the target app; verify encoder path if missed |
| Long recording memory | Stable plateau; no sustained growth between minute 5 and minute 30 |
| Appshot working memory | Aim below 200 MiB at supported dimensions; total memory must not grow with output height |

Use signposts for selection, capture, encode and preview latency. Profile UI wakeups, physical footprint and recording with Instruments. Keep ScreenCaptureKit's default queue depth initially; Apple documents that retaining buffers can stall capture and [queue depth must not exceed eight](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth). Never increase queue depth to conceal slow processing.

## Implementation milestones

### 0 Establish the native capture path

Create the minimal app target and reproducible release build. Verify signing, screen permission, microphone permission, one screenshot, a short MP4, and all audio combinations. Validate recording output before introducing Rust or elaborate UI. Confirm minimum-OS deployment availability; do not treat compiling against the newest SDK as runtime testing on macOS 15.

Exit: a fresh checkout builds the app; screenshot dimensions are correct; recordings finalize and play; any combined-audio fallback is decided and proven. Record the selected hardware baseline and output measurements.

### 1 Deliver screenshots and the capture interface

Implement menu bar, shortcut, reference-inspired capture bar, geometry, area/display/window capture, timer, previous area, native PNG output and result preview. Add minimal settings required by these paths.

Exit: each mode can capture, copy/save/drag and cancel. Verify at 1×/2× scaling, a secondary display left or above the main display, window shadow on/off, changed display arrangement and target-window closure. Compare toolbar screenshots against the reference at comparable scale. Check keyboard access, appearance and absence of Karuto controls in output.

### 2 Deliver reliable recording

Reuse target selection. Add input options, countdown, compact controls, status, finalization and MP4 results. Implement handling for lost permission, display/window disappearance, sleep interruption, full disk, repeated start/stop and quit during recording. On quit, stop and finalize before exit; do not silently discard an active recording.

Exit: screen-only and all audio combinations produce playable files; a 30-minute 1080p30 recording stays synchronized and within measured resource budgets; controls never appear in captured content. Repeat stop/start at least 20 times without leaked streams or growing memory.

### 3 Deliver manual vertical appshots

Add the Rust library, its small C bridge, strip-based algorithm, scrolling controls and incremental PNG output. Begin with fixture tests before testing real scrolling. Use the same implementation in browser and native-app tests.

Exit: capture a long page in Safari and Chromium, a long native text document and a PDF through manual scrolling without an extension. Verify seam continuity against known fixtures, clear recovery on oversized jumps and bounded memory through final encoding. Stress sticky/repeated content and reject uncertain matches instead of corrupting output.

### 4 Package and verify the initial release

Complete fresh-launch permission UX, cleanup, keyboard/accessibility checks, optimized build, size inspection and signed/notarized packaging when signing credentials are available. Measure all performance targets and retain a concise release checklist with actual results. A budget miss must produce a measurement and a focused optimization task, not an unsupported “lightweight” claim.

Exit: all in-scope functionality passes, no network/browser dependency is required, and the app runs from its distributed bundle. Stop here; editing, automatic scrolling and other deferred features need a subsequent plan.

## Suggested initial layout

```text
Karuto.xcodeproj
Karuto/
  App/                 # App delegate, menu, coordinator, settings
  Capture/             # Permissions, targets, geometry, screenshots, recording
  UI/                  # Toolbar, selection overlays, preview, recorder controls
  Appshots/            # Swift scrolling session and C bridge
  Storage/             # Temporary sessions, completed artifacts, thumbnails
  Resources/           # App icon and minimal localized strings
stitcher/              # Rust static library, introduced in milestone 3
Tests/                 # Geometry/lifecycle tests and stitch fixtures
scripts/               # Reproducible build and packaging commands
docs/                  # Research and this plan
```

## Sources and related research

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple recording lifecycle and audio](https://developer.apple.com/videos/play/wwdc2024/10088/)
