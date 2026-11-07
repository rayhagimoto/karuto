# Alpha validation

[Project](../README.md) · [Architecture](agents/architecture.md) · [Plan](implementation-plan.md)

## Automated checks

Validated on Apple silicon, macOS 27, Swift 6.4 Command Line Tools and Rust 1.96. The deployment target is macOS 15; live behavior on macOS 15 has not yet been exercised.

- 12 Rust tests: overlap matching, duplicate/reverse/ambiguous frame rejection, bounded allocation and output, scratch cleanup, salvage after failures, and decoded PNG pixels/checksums.
- 74 Swift Testing tests: two cursor initialization/tracking tests, eighteen Settings lifecycle, preview preferences, clipboard, and preview behavior tests, plus five toolbar placement/gesture tests, three capture-window policy tests, five capture geometry, three selection geometry, four retained-selection rendering tests, twelve area interaction tests, four frozen-desktop tests, one settings persistence test, one session/default separation test, seven keymap tests, six local storage tests, and three Swift-to-Rust PNG integration tests. Area interaction checks use real overlay views in hidden windows: first-mouse acceptance, capture exactly once at the release endpoint, ignored clicks/tiny gestures, canceled gestures, and staged scrolling/recording/timer modes. Additional checks cover retained selection movement/resizing followed by Return, menu toggle callbacks, frozen backdrop orientation and mode visibility, immutable frozen pixel crops at native scale, and preference persistence. These direct event tests do not establish host mouse-event delivery.
- Release app builds offline and uses an Apple Development certificate. The build requires an explicit opt-in for disposable ad-hoc signing. Distribution signing and notarization are not configured.

## Live checks

The running capture toolbar was visually inspected against the research reference and exposes all six modes, dimensions, and confirmation/cancel controls. Initial keyboard focus is on the toolbar container, not a dimension field. Settings opens without selection overlays obscuring it. The preview controller was also inspected with a local fixture. See [UI review](ui-review.md) and [visual evidence](ui-evidence/README.md).

A live screenshot attempt reached the Screen Recording permission gate and displayed an actionable error. Permission was not changed. Successful live screenshot output, recording playback and audio, appshots in real browsers/native apps, multiple displays, and permission recovery remain manual validation gates. Automated stitching and geometry tests do not establish that the entire live capture workflow has passed.

The enabled-permission/repeated-denial issue was traced to ad-hoc signing: `tccd` logged “Failed to match existing code requirement” for `local.screenshotx.app` and `kTCCServiceScreenCapture`, showing different stored and current code hashes. The build now uses a stable development identity; the old permission must be reauthorized once. See Apple's [explanation of this exact development issue](https://developer.apple.com/forums/thread/819406).

Before Area capture-on-release was introduced, the native selection fixture verified drawing a 650 × 400 area, resizing via its handle, and moving it by dragging its interior while preserving its dimensions. A transparent-pixel input bug was reproduced and corrected with 1% alpha hit coverage. No native presentation-rate measurement was made. See [selection performance evidence](selection-performance.md).

## Size and performance evidence

The release app bundle is approximately 1.4 MB on this machine. This excludes source, compiler caches and the unlinked Rust archive. It uses system frameworks and has no embedded browser or downloaded runtime.

A release Rust benchmark stitched 54 synthetic text-like 1920 × 1080 frames into a 1920 × 20160 PNG: append work about 85 ms, PNG encoding about 909 ms, total fixture generation/stitch/encode about 1.20 seconds, peak process RSS about 26.2 MiB. These are synthetic Rust-process measurements, **not** end-to-end app capture measurements or guaranteed resource budgets.

## Known alpha limits

- Appshots support manual downward scrolling only. Keep fixed headers/sidebars out of the selection. Animated, repetitive, or insufficiently overlapping content can be rejected rather than silently stitched incorrectly.
- Appshot input width is capped at 4096 pixels, each frame at 32 MiB, output at 100 million pixels, and session length at two minutes. Strips are stored on disk and PNG output streams from those strips.
- Very large still images use a file placeholder in previews to avoid decoding a huge bitmap. Clipboard image conversion has a separate memory guard.
- Temporary sessions expire after 24 hours; there is no total disk quota yet. The plan's disk and performance budgets are targets, not measured guarantees.
- H.264 native recording is capped at 4096 × 4096; the 1080p option scales while preserving aspect ratio. Audio mixing must be checked on each supported macOS version.
- No pause/resume, webcam, GIF, editing, OCR, background styling, or persistent history in this alpha.

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
