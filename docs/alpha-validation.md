# Alpha validation

[Project](../README.md) · [Architecture](agents/architecture.md) · [Plan](implementation-plan.md)

## Automated checks

Validated on Apple silicon, macOS 27, Swift 6.4 Command Line Tools and Rust 1.96. The deployment target is macOS 15; live behavior on macOS 15 has not yet been exercised.

- 19 Rust tests: overlap matching, duplicate/reverse/ambiguous frame rejection, bounded allocation and output, scratch cleanup, salvage after failures, decoded PNG pixels/checksums, and motion-calibrated crop verification/replay.
- 97 Swift Testing tests cover capture geometry, native overlay interaction and cursors, settings and shortcuts, setup and startup behavior, storage, clipboard and previews, CLI parsing, scrolling suggestions and stale-query rejection, automatic-scroll progress, frozen desktop output, and Swift-to-Rust PNG integration. Overlay checks use real views in hidden windows; they do not establish host mouse-event delivery or rendered animation quality.
- Release app builds offline and uses an Apple Development certificate. The build requires an explicit opt-in for disposable ad-hoc signing. Distribution signing and notarization are not configured.

## Headless browser regressions

The workspace-local [Playwright suite](../.scratch/playwright/README.md) lives under gitignored `.scratch/playwright/`, alongside the requested local HTML fixtures. It uses isolated headless Chromium at 1× and 2× device scale and feeds visible viewport screenshots through the same calibrated Rust C API as the app. Seven scenarios per scale cover ordinary documents, nested panes, four fixed outer edges, uneven manual steps, duplicate frames, no movement, and nonoverlapping jumps. Successful cases require exact verified crop/output dimensions and independently checked fingerprints on every output pixel row. Negative cases require rejection without publishing a PNG.

On 2026-11-07, **14 tests passed in 213 seconds**, with no skipped, retried, or flaky tests. Ten complete captures verified **54,000 physical pixel rows with zero mismatches**, including exact four-edge crops at both scales. The runner used Playwright 1.65.0 and headless Chromium 158.0.8127.18. JSON and HTML reports retain the results; raw BGRA streams were removed after replay.

After installing its test-only dependencies, run `npm --prefix .scratch/playwright test`. JSON/HTML reports, stitched PNGs, pixel-check results, and failure traces are kept under that scratch directory; the suite and fixtures are intentionally absent from a fresh checkout. The test adapter waits for rendered-pixel stability so elastic browser overscroll is not counted as extra content. This tests the production stitching core against actual browser rendering; it does not validate native overlay UI, Accessibility discovery, ScreenCaptureKit, permissions, or the Swift input driver's timing/end detection. No app runtime dependency was added.

## Live checks

### Motion-verified scrolling capture

On 2026-11-07, the signed production CLI automatically scrolled Google Chrome's nested overflow pane from top to bottom while capturing an oversized 1000 × 800 region that included a fixed 60px header, 40px footer, and two 100px sidebars. The verified moving crop was exactly `(100,60,800,700)` in input pixels; the final PNG was **800 × 3600**. The deterministic color rail passed all **3600 rows with zero mismatches**. Visual review confirmed all twelve numbered sections in order, START at the beginning, END at the bottom, and no fixed furniture. Initial calibration rows were preserved. The local fixture, capture/check script, PNG, and JSON results are under gitignored `.scratch/`; see `.scratch/README.md`.

The structural Accessibility query returned Chrome's outer web viewport rather than the nested canvas pane on this host. That is a suggestion, not a verified scrolling bound. A whole-window control containing the fixture's changing Position counter outside the document was rejected; multiple unrelated moving regions are not reconstructed into a guessed result. The deterministic ordinary-document variant with fixed furniture has not been live-validated. These checks establish this real Chrome capture, not universal handling of every app or layout.

### Earlier alpha checks

The running capture toolbar was visually inspected against the research reference and exposes all six modes, dimensions, and confirmation/cancel controls. Initial keyboard focus is on the toolbar container, not a dimension field. Settings opens without selection overlays obscuring it. The preview controller was also inspected with a local fixture. See [UI review](ui-review.md) and [visual evidence](ui-evidence/README.md).

A live screenshot attempt reached the Screen Recording permission gate and displayed an actionable error. Permission was not changed. Successful live screenshot output, recording playback and audio, appshots in real browsers/native apps, multiple displays, and permission recovery remain manual validation gates. Automated stitching and geometry tests do not establish that the entire live capture workflow has passed.

The enabled-permission/repeated-denial issue was traced to ad-hoc signing: `tccd` logged “Failed to match existing code requirement” for `local.karuto.app` and `kTCCServiceScreenCapture`, showing different stored and current code hashes. The build now uses a stable development identity; the old permission must be reauthorized once. See Apple's [explanation of this exact development issue](https://developer.apple.com/forums/thread/819406).

Before Area capture-on-release was introduced, the native selection fixture verified drawing a 650 × 400 area, resizing via its handle, and moving it by dragging its interior while preserving its dimensions. A transparent-pixel input bug was reproduced and corrected with 1% alpha hit coverage. No native presentation-rate measurement was made. See [selection performance evidence](selection-performance.md).

## Size and performance evidence

The release app bundle is approximately 3.7 MB on this machine, including app icon assets. This excludes source, compiler caches and the unlinked Rust archive. It uses system frameworks and has no embedded browser or downloaded runtime.

A release Rust benchmark stitched 54 synthetic text-like 1920 × 1080 frames into a 1920 × 20160 PNG: append work about 85 ms, PNG encoding about 909 ms, total fixture generation/stitch/encode about 1.20 seconds, peak process RSS about 26.2 MiB. These are synthetic Rust-process measurements, **not** end-to-end app capture measurements or guaranteed resource budgets.

## Known alpha limits

- Appshots support automatic downward scrolling with manual fallback. Motion verification can exclude stationary outer headers, footers, and sidebars; animated, repetitive, independently moving, or insufficiently overlapping content can require a smaller selection or be rejected.
- Appshot input width is capped at 4096 pixels, each frame at 32 MiB, output at 100 million pixels, and session length at two minutes. Strips are stored on disk and PNG output streams from those strips.
- Very large still images use a file placeholder in previews to avoid decoding a huge bitmap. Clipboard image conversion has a separate memory guard.
- Temporary sessions expire after 24 hours; there is no total disk quota yet. The plan's disk and performance budgets are targets, not measured guarantees.
- H.264 native recording is capped at 4096 × 4096; the 1080p option scales while preserving aspect ratio. Audio mixing must be checked on each supported macOS version.
- No pause/resume, webcam, GIF, editing, OCR, background styling, or persistent history in this alpha.

## Setup and login launch

The signed app's Setup section was inspected at its normal 900 × 680 size. Its Screen Recording, Accessibility, Microphone, and Login Items buttons opened the corresponding System Settings pages. On this macOS 27 host, the Accessibility link opens **Device Control and Data Access**. The live form refreshed access status and displayed the operating system's enabled login-item state. No actual logout/login cycle was performed.

GUI launches are always quiet, including manual opens and reopens; no launch-reason detection is needed. Automated checks exercise the actual reopen delegate with and without visible windows and verify that it declines default presentation. Setup tests use fake operating-system services to verify permission destinations, layout bounds, refresh on return, approval-required status, registration failure rollback, and disabling launch at login. They never grant permissions or register a real login item. Changes are serialized in the system adapter so reopening Preferences cannot overlap registration with pending asynchronous unregistration.

The full suite passes 97 Swift tests and 19 Rust tests. A pre-existing preview timeout check passed alone but exceeded its three-second wait while other native UI suites occupied MainActor; its bounded wait now allows that scheduling contention and retains the same dismissal assertions. The parallel suite passed after that test-only correction.

## Overlay capture options

Instant Capture defaults on and Freeze Display defaults off. Settings → Capture persists defaults for new sessions. The overlay gear menu changes only the current session, including a freeze restart. Toggle shortcuts start unassigned. Frozen sessions acquire desktop frames before selection appears and export from those same frames. Live video/audio are not paused. Recording, scrolling, and timed capture remain live. Frozen-frame memory is capped at 256 MiB; window snapshots represent the visible desktop crop and reject windows spanning displays. Exact keypress-time or simultaneous multi-display capture is not guaranteed by the one-frame ScreenCaptureKit requests.

The signed build’s overlay dropdown was inspected live and both preference values were readable after interaction. The live window disappeared before a complete frozen-output check could finish; video-background freezing and exported pixel identity remain manual end-to-end checks. The 54 Swift and 12 Rust tests passed, including synthetic frozen-frame crop and displayed-layer orientation checks.

Keymap tests cover explicit unassignment, safe legacy migration/corrupt data, exact scopes and repeat filtering, cross-scope conflicts, atomic registration rollback, startup conflict recovery, recorder suspension/restoration, and removing Return/keypad Enter while preserving click confirmation. Runtime hotkey tests use a fake backend and do not reserve system shortcuts.

Live keymap checks passed in the signed build: Command–comma opened Preferences; Command–Option–comma opened Keyboard Shortcuts directly from the overlay; the recorder rejected the occupied Preferences chord and accepted Control–Option–I for Instant Capture. That binding changed the active overlay to manual confirmation, while Preferences still showed Instant Capture enabled and the next capture restored instant behavior. The temporary binding was cleared afterward; both toggle commands are unassigned. GUI conflict, assignment, scope, and session-default behavior were observed, not inferred only from tests. See [keymap screenshot](ui-evidence/keymap-settings.jpg).

Toolbar checks cover menus near the top/bottom of displays, horizontal edge clamping, insufficient vertical room, cross-display drag placement, and native pan priority/delayed click delivery. The running toolbar accepted a drag starting over Fullscreen while Area stayed selected; subsequent live menu/click checks were interrupted by window-state changes, so complete native drag-vs-click and popup placement verification remains outstanding.

## Clipboard and preview update

The final suite passes 70 Swift tests and 12 Rust tests. Clipboard integration tests require access to the macOS pasteboard service; a restricted execution environment cannot satisfy these tests. They use unique private pasteboards and never alter the general clipboard. Tests verify PNG and TIFF readback after source removal, native NSImage compatibility, preservation of the existing clipboard on invalid/video/oversized/cancelled requests, preference persistence and limits, actual Settings layout, first-click controls, single-click versus movement, dismissal before action callbacks, timeout cancellation, and persistent stacks containing more than three previews.

Live signed-app checks verified General's automatic-copy default and preview controls, their spacing at 900 × 680, and a 200 × 150 screenshot preview displaying 6.2 kB with Copy, Save, Reveal, and Trash controls. Clicking Copy dismissed that preview. Preview's New from Clipboard command created an image document. The inspection tool did not provide a usable rendered image for pixel comparison; clipboard pixel dimensions and readable representations were checked separately by integration tests.

Save now uses the asynchronous system dialog API and background file copying. No measured improvement to the system dialog's cold-start latency is claimed. Actual Trash recovery, live timeout expiry, drag/drop, and default-viewer opening from a preview remain manual integration checks. Persistent stacking was added after the live check and verified by tests before the final signed rebuild.

## Hover dismissal and fade-out

The updated suite passes 72 Swift and 12 Rust tests. New checks cover whole-card hover tracking, leaving only after entry, child-control boundaries, held-button and cancelled-drag exit deferral, and stale callbacks after replacing a preview for the same artifact. Existing action/timeout tests now await dismissal completion and verify callbacks fire once after closure. Visible removals share a native 180 ms ease-out opacity animation. Already-hidden windows close asynchronously without trying to animate invisible content, because AppKit may not complete their animation transactions. These automated checks establish lifecycle and event handling; they do not measure or visually certify the rendered fade.

## Initial capture cursor

The suite passes 74 Swift and 12 Rust tests. Cursor tests exercise actual overlay presentation with a stationary pointer, verify the crosshair is set before any movement event, check toolbar button and editable-field cursors, and check non-key canvas entry/movement and dismissal. Activation observers are removed on dismissal and controller destruction. These checks inspect AppKit cursor state; the inspection tool did not visually verify the hardware pointer in the running app.

## Reversible preview hover dismissal

Hover exit now waits 500 ms before the native 180 ms ease-out fade. Passive fades retain mouse tracking and the preview entry until completion; reentry cancels the pending dismissal and restores full opacity. A canceled timer/fade cannot close a restored or replacement preview. Explicit actions still close once and then invoke their action. Timeout dismissal can also be interrupted by reentry, and cannot shorten an already scheduled hover-exit grace period. The regression test exercises leaving, returning during the grace period, returning during fade, and a subsequent successful exit using deterministic pointer input.
