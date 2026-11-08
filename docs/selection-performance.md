# Selection rendering performance

The drag renderer now updates retained Core Animation layers instead of invoking the former display-sized AppKit drawing routine. The measurements below establish the CPU work removed from that path. They do **not** establish displayed frame rate, pointer-to-pixel latency, GPU cost, or an end-to-end speedup factor.

## Measurement

Measured on 2026-11-07, arm64, macOS 27.0.1 (26A434), optimized Swift 6 compilation. These timings describe the initial retained renderer, before the later 1% root-background hit-coverage revision described below. Both executables ran sequentially after concurrent project compilation finished. Each case used 20 warm-up iterations followed by 200 measured updates. Selection position and dimensions changed on every iteration. Times use `DispatchTime` around the operation under test; median is sorted sample 100, p95 is sorted sample 189 (zero-based).

| Logical display | Bitmap resolution | Former CPU drawing median / p95 | Retained layer update median / p95 |
| --- | --- | --- | --- |
| 1920 × 1080, 1× | 1920 × 1080 | 5.547 / 5.812 ms | 0.0211 / 0.0215 ms |
| 1920 × 1080, 2× | 3840 × 2160 | 21.647 / 23.619 ms | 0.0190 / 0.0196 ms |
| 2560 × 1440, 1× | 2560 × 1440 | 10.416 / 10.893 ms | 0.0189 / 0.0194 ms |

The former operation is the actual `SelectionOverlayView.draw(_:)` method from the saved pre-change source, drawing its dimming path, outline, handles, and badge into `NSBitmapImageRep` through `NSGraphicsContext`. The complete saved controller source was compiled with a benchmark appended to the same file to access the private view. The drawing algorithm was not reimplemented. Bitmap allocation, clearing, input assignment, and PNG encoding were outside the timed section. Setting bitmap logical size supplies the backing scale; the context is not scaled a second time.

The new operation is the actual [`SelectionOverlayRenderer.update(rect:text:resizable:)`](../Sources/Karuto/UI/SelectionOverlayRenderer.swift), including its disabled-animation transaction, path updates, and changed text measurement. It does not rasterize a full-screen bitmap. Core Animation rasterization, transaction delivery, GPU composition, window presentation, and the controller's other work are outside this measurement. The two columns therefore measure different stages of rendering, not equivalent complete frames. The 2× former-renderer run included a 59.890 ms maximum outlier; no absolute timing threshold is enforced.

The host's Dell display was separately reported by the parent process as 2560 × 1440 points, scale 1, maximum refresh 165 Hz; its nominal refresh interval is about 6.06 ms. The former offscreen draw's measured CPU duration is substantial relative to that interval, but this is contextual evidence, not a measurement of application refresh or proof that the replacement presents at 165 Hz. Native display tracing remains necessary to establish presentation cadence.

## Geometry check

Both renderers produced offscreen PNGs for a 700 × 450 point selection at `(400, 300)` in each configuration. The new snapshot used `rootLayer.render(in:)` outside timing. An independent PNG decoder checked four transparent interior points, four exterior points at approximately 0.34 alpha, and all eight white handle centers. All 96 checks passed across the before/after images and three configurations. This checks the selection hole, dimming, and handle placement; it is not a pixel-identical typography or antialiasing assertion.

The final verifier explicitly converts bottom-left logical coordinates to top-left bitmap rows. An early inline diagnostic in the baseline executable used an unconverted row for the Dell interior probe; that diagnostic is superseded by the passing independent verifier. The saved harness source now uses the corrected coordinates.

### Final input-coverage revision

Native interaction exposed a separate issue: a fully transparent selection interior did not receive the move drag, although border resizing worked. The final renderer sets its root background to black at 0.01 alpha so the selection interior remains eligible for hit testing. This changes the initialization, not the `update` method; the table above was not remeasured for this final revision and must not be presented as a measurement of the final binary.

The final renderer was compiled separately to regenerate its three offscreen snapshots. All 48 explicit probes passed: four interior samples at exactly 3/255 alpha, four exterior samples at exactly 89/255 alpha, and eight opaque white handle centers per configuration. The exterior value reflects compositing the shade over the root background; it was measured as 89, rather than the initially estimated 88. The original before/after probe results above remain evidence for the earlier transparent-root revision. Final PNGs use the `after-hitcoverage-` prefix, and results are in `final-hitcoverage-results.txt`.

The parent agent then verified the same interior drag through live computer interaction against the application's own controller fixture: a 650 × 400 point selection moved 100 points horizontally and vertically while preserving its dimensions. See [native movement evidence](ui-evidence/selection-move-fixture.jpg). The parent also reported 33 passing tests and a successful final production build. These observations establish working interior movement, not measured display FPS. The temporary fixture was closed after verification.

## Sources and reproduction

The local benchmark workspace is `/tmp/karuto-selection-bench/`; it is a temporary validation artifact, not part of the shipped app. It contains `Baseline.swift`, `Harness.swift.txt`, `UIComponents.swift`, `SelectionGeometry.swift`, `CaptureModels.swift`, `SelectionOverlayRenderer.swift`, `RetainedBench.swift`, `VerifySnapshots.swift`, the executables, result logs, and PNGs.

Source identities for the measured implementation:

- Pre-change controller snapshot: `/tmp/Karuto-CaptureUI-before-drag-fix.swift`, SHA-256 `ff3610d42691738d91a8fd79890b5b5da89a21278a75bdcfae305a4be09fedc8`.
- New renderer snapshot: SHA-256 `0c902f887d6bc536ae8a4be2e0d2c76ef5cbd485ba4e30eedd1af288a00d637a`.
- Final renderer with input coverage, independently checked after the timed revision: SHA-256 `43d0023fd03b3ec660526e7c3b0344869438942f366f69b2d9d1dd8c0726d5df`. Saved as `FinalSelectionOverlayRenderer.swift`; snapshot/probe harness is `RenderHitCoverage.swift`.
- Final timing logs: `baseline-final-results.txt` and `retained-final-results.txt`.
- Geometry evidence: `snapshot-results.txt` and `before-` / `after-` PNGs named by logical resolution and scale.

To rebuild while the temporary workspace exists:

```sh
cd /tmp/karuto-selection-bench
swiftc -O -swift-version 6 -module-cache-path module-cache Baseline.swift UIComponents.swift SelectionGeometry.swift CaptureModels.swift -o baseline
swiftc -O -swift-version 6 -module-cache-path module-cache SelectionOverlayRenderer.swift RetainedBench.swift -o retained
swiftc -O -module-cache-path module-cache VerifySnapshots.swift -o verify-snapshots
./baseline
./retained
./verify-snapshots
```

Run the executables sequentially without concurrent builds. Do not convert their timing ratio into an FPS claim. No UI automation, synthetic mouse events, or visible application windows were used for these measurements.
