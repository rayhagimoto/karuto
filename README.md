# ScreenshotX

A local-only macOS capture app. Native Swift/AppKit interface and ScreenCaptureKit capture, with a small Rust core for scrolling-image stitching. No browser extension, embedded browser, cloud storage, telemetry, or third-party runtime dependencies.

## Try the alpha

Requires macOS 15 or newer. Build with Apple's Swift tools and Rust:

```sh
bash scripts/build.sh
open dist/ScreenshotX.app
```

The build selects your Apple Development signing identity when exactly one is available. With multiple identities, set `SCREENSHOTX_SIGN_IDENTITY` to the intended certificate's SHA-1 fingerprint. Keep the same identity across builds so macOS can recognize existing privacy grants. Ad-hoc signing is available only by explicitly setting `SCREENSHOTX_SIGN_IDENTITY=-`; changed ad-hoc builds can lose permission despite an enabled Settings toggle.

After switching from an older ad-hoc build, quit ScreenshotX, remove its entry from **System Settings → Privacy & Security → Screen & System Audio Recording**, then reopen this app and grant access again. Reopen once more if macOS requests it. This is a one-time migration to the new signing identity, not a step required for every build.

The app opens a floating capture toolbar. Drag anywhere on the toolbar to reposition it; an ordinary click still operates the control. The options menu opens above or below its button according to available screen space. **Control–Shift–2** reopens it by default; the menu-bar icon provides settings, previous-area capture, and restore-last-capture. **Area:** drag once and release to capture by default. Open the overlay’s gear menu to turn off **Instant Capture**; then drag, move, or resize the selection and press **Return** when ready. For other modes, select a target and press **Return**. Exact area dimensions can also be entered in the toolbar and captured with **Return**. **Escape** cancels selection. Screen Recording permission is required when capturing; microphone permission is requested only when microphone recording is selected.

- **ScreenshotX settings:** Preferences remains visible in screenshots and can be selected in Window mode; capture controls and previews remain excluded.
- **Screenshots:** area, display, window, three-second timer, previous area; PNG output and optional window shadow.
- **Overlay options:** **Instant Capture** and **Freeze Display During Capture** in Settings → Capture are saved defaults for new sessions. The overlay gear menu overrides them only for the current session. Freeze takes a still frame before the overlay opens; Area, Fullscreen, and Window output use those same saved pixels. Apps and audio continue underneath. Switching freeze restarts selection. Recording, scrolling, and the screenshot timer remain live.
- **Recording:** area, display, or window; H.264 MP4, cursor option, system audio and microphone options, native or 1080p resolution; stop/cancel controls.
- **Scrolling appshots:** select a content rectangle in an existing browser or Mac app, then manually scroll slowly downward. Overlapping frames are stitched locally into a PNG. Exclude fixed headers and sidebars from the rectangle.
- **Results:** screenshots copy to the clipboard automatically by default; disable this in Settings → General. Videos never auto-copy. Preview actions include copy, save, reveal, and screenshot Trash. Clicking the image opens its default viewer; dragging exports the file. Actions close the preview, and its footer shows file size in B/kB/MB as appropriate. Auto-save remains optional.

Settings → General also controls preview dismissal: keep until dismissed (default), or close automatically after 1–300 seconds (initially 5). Hovering over a preview and then moving away dismisses it in either mode. The timer waits while the pointer is over the preview or a mouse button is held; a file drag finishes before hover dismissal. Every dismissal uses a short fade-out, including actions, the close button, and timeouts. Persistent previews otherwise remain available until dismissed; crowded previews overlap within the display instead of evicting older captures. Dismissing a preview does not delete its file. The Trash action moves the preview's current file to macOS Trash; Restore Last Capture does not restore trashed files. Saving closes the preview even if the save dialog is later cancelled; Restore Last Capture remains available from the menu bar.

Freeze uses the earliest frames returned by macOS after permission and display discovery, not an exact keypress timestamp; separate displays are not guaranteed simultaneous. Frozen Window mode crops the visible screen region, including any occluding windows, without isolated transparency or shadows. For a window spanning displays, use Area or turn off freeze.

This is an alpha, not a complete commercial capture suite. Editing, annotations, OCR, background composition, GIF export, webcam overlays, recording pause/resume, and persistent capture history are deferred. Scrolling capture is conservative: animation, sticky content, repeated patterns, and fast scrolling can prevent reliable overlap detection. It captures rendered pixels; it cannot reveal unloaded or never-rendered content.

## Keyboard shortcuts

Open Preferences with **Command–comma**, or open **Keyboard Shortcuts** directly with **Command–Option–comma**, including from the overlay. These defaults can be changed or cleared, along with every other app-defined shortcut. The gear and menu-bar menus provide clickable paths even when shortcuts are unassigned. Instant Capture and Freeze Display toggle shortcuts start unassigned and affect only the current overlay session.

The editor provides **Record**, **Clear**, and **Restore Defaults**. Assignments are grouped by where they work: anywhere on your Mac, while ScreenshotX is active, or within capture selection. Conflicts are rejected before saving. See [keymap architecture](docs/keymap.md).

## Validate

```sh
bash scripts/test.sh
```

The suite covers capture-coordinate conversion, selection geometry, local storage, Rust overlap detection and PNG output, and the Swift/Rust bridge. See [alpha validation](docs/alpha-validation.md) for the distinction between automated checks and live app checks.

## Documentation

- [Initial implementation plan](docs/implementation-plan.md)
- [Architecture and module contracts](docs/agents/architecture.md)
- [Keymap and session preferences](docs/keymap.md)
- [Alpha validation and limitations](docs/alpha-validation.md)
- [Selection performance measurements](docs/selection-performance.md)
- [Memory budget and measurements](docs/memory-performance.md)
