# Development and testing

Karuto requires macOS 15 or later, Xcode or Command Line Tools, Rust and Cargo, and `librsvg` (`rsvg-convert`). From the repository root, build and launch with:

```sh
bash scripts/build.sh
open dist/Karuto.app
```

The build selects an Apple Development certificate when exactly one is available. Set `KARUTO_SIGN_IDENTITY` to a certificate fingerprint when needed. `KARUTO_SIGN_IDENTITY=-` creates an ad-hoc build, whose privacy grants may need renewing after a rebuild.

Run the Swift and Rust test suites with:

```sh
bash scripts/test.sh
```

The script tests the Rust stitcher, builds its release library, and runs Swift tests. Automated tests cover geometry, UI behavior, settings, storage, CLI parsing, and stitching. Run the app for changes affecting actual screen capture, permissions, display placement, input, or playback.

## Manual checks

For the affected workflow, check selection and capture on each available display, permission denial and recovery, and the resulting file or clipboard content. For recording changes, play back the output and check the selected audio sources. For scrolling changes, exercise automatic and manual scrolling in a browser or native app and inspect the stitched result. Check visible UI changes in the running app.

## Memory measurements

The idle target is less than 50 MiB. Use a signed release build, close the overlay, previews, and Settings, finish recordings, and let work settle. Find the process with `pgrep -x Karuto`, then substitute its PID below:

```sh
bash scripts/memory.sh PID footprint 50
bash scripts/memory.sh PID rss 50
```

Record physical footprint and RSS separately along with the workload, display resolution, and open preview count. Measure fresh background launch and post-capture idle separately. The script cannot establish whether the app is idle, and active capture peaks are distinct from the idle target.
