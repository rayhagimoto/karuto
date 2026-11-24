# Karuto CLI

The CLI captures locally without showing the capture overlay, preview, or settings. It calls the executable inside the signed app bundle. Build Karuto first, then run `scripts/karuto` from the project root. For a command named `karuto` on your PATH, add the project's `scripts` directory to PATH; keep the script beside the project because it resolves the bundle relative to itself. You can also invoke `dist/Karuto.app/Contents/MacOS/Karuto --cli` directly.

```sh
scripts/karuto help
scripts/karuto help screenshot
scripts/karuto help record
```

## Agent contract

Successful commands return one JSON object on standard output, except `help` and `--help`, which return text. Errors return one JSON object with `error` and numeric `code` on standard error. Exit status is 0 for success, 2 for invalid arguments, 3 when privacy access is needed, and 1 for capture or filesystem errors. Framework diagnostics may also appear on standard error. No shell commands or output paths are evaluated by Karuto.

Capture requires macOS Screen & System Audio Recording permission for the signed app. Use `permissions` to check before invoking capture. The CLI does not request permissions or interact with the GUI; grant access through macOS before using it. Microphone recording additionally requires microphone permission. Launch context and macOS privacy attribution can affect authorization, so verify with `permissions` from the same environment as the caller.

## Commands

### `permissions`

```sh
scripts/karuto permissions
```

Returns `screen_recording` and `automatic_scrolling` (`authorized` or `not_authorized`), and `microphone` (`authorized`, `denied`, `restricted`, `not_determined`, or `unknown`). Does not trigger permission prompts.

### `list displays` and `list windows`

```sh
scripts/karuto list displays
scripts/karuto list windows
```

Returns a `displays` or `windows` array. Each entry has a numeric `id` and `bounds` object with `x`, `y`, `width`, and `height` in global AppKit points. Displays also include `name` and `scale`; windows include `title` and `application`. Window metadata may be limited without screen recording permission. IDs can change when displays or windows change, so discover them immediately before use.

### `screenshot`

```sh
scripts/karuto screenshot --display 1 --output /tmp/screen.png
scripts/karuto screenshot --window 42 --output /tmp/window.png --no-shadow
scripts/karuto screenshot --area 1 0 0 800 600 --output /tmp/area.png --cursor
```

Requires one target and `--output`. Select a target with `--display ID`, `--window ID`, or `--area DISPLAY_ID X Y WIDTH HEIGHT`. Area coordinates are global AppKit points, with the origin at the bottom-left of the primary display; values can be negative on other displays. The rectangle must be entirely inside the selected display. Use `list displays` to find its bounds. `--cursor` includes the pointer; `--no-shadow` disables window shadows. Output is PNG and the success object contains `path`, `type`, `width`, and `height`.

### `record`

```sh
scripts/karuto record --display 1 --duration 5 --output /tmp/demo.mp4
scripts/karuto record --window 42 --duration 10 --fps 120 --native --system-audio --output /tmp/window.mp4
scripts/karuto record --area 1 0 0 800 600 --duration 3 --no-cursor --output /tmp/area.mp4
```

Accepts the same target syntax. `--duration` is required and must be 0.1–3600 seconds. Output is H.264 MP4. Use `--fps 30`, `--fps 60`, or `--fps 120` to set the maximum recording frame rate. The default is 30 fps. Actual frame delivery depends on the display and changes in the captured content. Resolution defaults to 1080p; `--native` requests native resolution. `--system-audio` and `--microphone` opt into audio; `--no-cursor` hides the pointer. The success object contains `path`, `type`, `width`, `height`, and recorded `duration`. Startup and finalization add time beyond the requested duration. Run a separate process for each recording; this CLI does not provide pause or remote stop.

For both capture commands, the output parent must exist and the output must not already exist. The CLI creates a temporary sibling and moves it into place after success; it does not overwrite existing output. Failed operations attempt to remove the temporary file. `SIGKILL` or a crash can leave a `.karuto-*` temporary file. Capture output is never automatically copied to the clipboard.

### `scroll`

```sh
scripts/karuto scroll --area 1 40 100 800 600 --output /tmp/page.png
scripts/karuto scroll --area 1 40 100 800 600 --manual --duration 30 --output /tmp/manual.png
```

Automatically scrolls downward from the current position, takes short steps to identify the moving pane, then advances up to half a viewport when stitching confirms the previous step. At the bottom it checks for further growth before saving. Keep the target visible and frontmost, with the selected rectangle's center over the intended scrollable content. Accessibility access is required for automatic input; `permissions` reports `automatic_scrolling` authorization. The CLI never prompts for it.

Automatic and manual capture first verify one moving viewport across three overlapping frame pairs. Stationary outer headers, footers, and sidebars can be excluded when pixel evidence supports their boundaries. The initial frames are replayed into the stitched image, preserving the beginning. On success, `content_rect` reports the verified rectangle in **input-image pixels with a top-left origin**, relative to the selected capture rectangle; output `width` is the cropped viewport width and `height` is the complete stitched height. These pixel coordinates are distinct from the global AppKit points used by `--area`.

`--duration` is an automatic-mode safety limit of 1–120 seconds (default 120); reaching it reports an error rather than claiming a complete page. With `--manual`, duration is required and specifies how long to capture while the user scrolls. Width, height, path, type, and scrolling mode are returned as JSON on success. As with screenshots, existing outputs are never overwritten. Scrolling without accepted extension reports an error.

The GUI switches to manual capture when automation cannot proceed, or when the user selects **Scroll Manually**. The noninteractive CLI instead returns a reason and suggests retrying with `--manual --duration SECONDS`. When the initial motion cannot be explained by one scrolling pane, the GUI offers **Adjust Area** and the CLI reports an error; manual mode does not bypass verification. Animated content outside the desired pane can require a smaller area. End detection is based on settled pixels, not a DOM or accessibility scroll range; slow-loading pages can appear temporarily stationary. No automatic scrolling implementation can guarantee that unrendered or lazily loaded content is complete.

### `scroll-region`

```sh
scripts/karuto scroll-region --window 42 --point 640 480
```

Queries the target application's accessibility tree for a scrollable ancestor under the point. The point and returned `bounds` use the same global AppKit coordinates as `--area`. Discover the current window ID and bounds with `list windows`. The point must lie in that window and on a connected display. Accessibility access is required; the command never requests it or scrolls the app.

Returns `window`, `suggested`, `bounds` (an object or `null`), and `verified: false`. A suggestion is structural evidence, not proof that its pixels scroll together: Chrome may expose the outer page rather than an inner scrolling div, and some apps expose no usable pane. Use a returned rectangle as a candidate for `scroll --area`; motion verification runs during capture. A missing suggestion is a successful query with `suggested: false`, not a capture error.
