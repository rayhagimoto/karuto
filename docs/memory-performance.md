# Memory budget and measurements

Target: less than 50 MiB at idle. The user clarified that temporary peaks while actively using capture are acceptable; the target concerns usage after the overlay closes. Record both physical footprint and resident memory (RSS); do not substitute one for a budget measured with the other. Physical footprint accounts for memory charged to the process, while RSS includes resident shared mappings. The user's original 124 MiB report has not been matched to a profiler metric and UI state.

## Repeatable check

Use the signed release app. Close capture selection, previews, and Settings, finish any recording, and let pending work settle. Find its PID with `pgrep -x Karuto`, then run:

```sh
bash scripts/memory.sh PID footprint 50
bash scripts/memory.sh PID rss 50
```

The script is read-only, reports both metrics and peak footprint, and exits 1 when the selected metric is at or above the budget. It does not launch, close, or change the app, and cannot certify idle state. `vmmap` requires permission to inspect the process. Its rounded output is unsuitable for evaluating a result within a fraction of a MiB of the boundary.

Measure these states separately: fresh background launch (`--background`), selection with Freeze Display off/on, Settings open, Settings closed, and after repeated capture/dismiss cycles. Keep display resolution and preview count fixed. Record profiler name, metric, release binary, and UI state with each result. Do not count the test runner or compiler as app memory.

## Investigation on 2026-11-07

Existing signed release, PID 62278, macOS 27.0.1, arm64. These samples precede the Settings lifecycle change; they are not a before/after benchmark.

| Observation | Physical footprint | Peak footprint | RSS |
| --- | ---: | ---: | ---: |
| Before UI inspection; window state unverified | 25.9 MiB | 65.9 MiB | 97.6 MiB in adjacent sample |
| Capture toolbar observed | 64.7 MiB | 65.9 MiB | Not sampled |
| After captures; preview activity observed nearby | 44.5 MiB | 68.2 MiB | Not sampled |
| Later read-only budget check; window state unverified | 29.6 MiB | 68.2 MiB | 106.7 MiB |

The later footprint check passes 50 MiB; the subsequent RSS check fails at 107.6 MiB. Live windows changed during interaction, so these are diagnostic samples, not a controlled idle benchmark or proof of the user's target across workloads. A leak scan reported zero detected leaks but warned that the signed process restricts inspection; this does not prove absence of retention.

## Ownership findings

Closed Settings retained its window, glass hierarchy, navigation, keymap view, and (on the Recording page) discovered capture-device objects. This is reachable retention, so a zero-leaks report would not rule it out. Closing now releases these UI references while preserving saved settings, the selected section, and the window frame. A regression test exercised actual show/close: weak window and root-view references remained alive before the fix and became nil afterward. Reopening and unrelated close notifications are also checked. All 55 Swift and 12 Rust tests pass. Quantifying the resulting MiB reduction still requires a controlled release-build comparison.

Frozen desktop images already have explicit cleanup in both the coordinator and overlay layers. At the time of these measurements, result previews kept at most three bounded thumbnails. The later preview update preserves all deliberately open previews and overlaps them when crowded; thumbnail resolution remains bounded, but total memory grows with open preview count. Record open preview count with idle measurements; distinguish background-only idle from idle with previews still visible. Neither source inspection nor these samples establishes that frozen frames leaked. Avoid periodic cache flushing, forced memory pressure, reduced capture quality, or removing glass styling without evidence that they address the measured budget.

## Follow-up: idle budget and targeted experiments

The following measurements are observations of the existing app, not before/after results from a new optimization. No production memory change was shipped from this investigation. The cursor implementation was also left unchanged after the user reported it working.

| Observed workload | Physical footprint | Result against 50 MiB |
| --- | ---: | --- |
| Fresh background launch, PID 93350 | 12.7 MiB | Pass |
| Small 262 × 234 screenshot preview, PID 92546 | 32.0 MiB | Pass |
| Capture overlay, earlier PID 86270 | 49.9 MiB | Active workload; not the idle gate |

The earlier process reached a 73.8 MiB peak during use. These observations satisfy the budget for the measured idle/small-preview states; they do not establish a universal bound after every capture or paste. The background profiling instance and all isolated harnesses were stopped afterward. See [raw measurement evidence](memory-evidence/README.md).

### Clipboard stress case remains isolated

An optimized harness compiled the real clipboard implementation, ran an AppKit event loop without windows, and used a private pasteboard. A separate process requested TIFF and exited before the sender was measured again after one second of idle. It never used the user's general clipboard. The retained figures below are **settled memory, not just peaks**, so this remains a potential idle edge case requiring validation in the complete app.

| Synthetic 3840 × 2160 content | Existing settled footprint | Experimental Deflate TIFF | Existing / experimental paste time |
| --- | ---: | ---: | ---: |
| UI pattern | 75.38 MiB | 10.72 MiB | 0.205 / 0.256 s |
| Gradient with grain | 96.41 MiB | 83.31 MiB | 0.373 / 1.874 s |
| Random RGB noise | 102.64 MiB | 93.91 MiB | 0.290 / 1.652 s |

The candidate changed both TIFF compression and `CGImageDestinationAddImageFromSource`. TIFF metadata and decoding succeeded, but pixel equality was not tested. It was not shipped: it still exceeds the stress-case budget and adds about 1.5 seconds to complex-image paste latency. Earlier LZW results were also content-dependent and worsened noise. File-backed variants added complexity without consistently reaching the target; targeted allocator relief released zero bytes in the tested cases. None justifies a blanket cache flush or an assertion that the full app now stays below 50 MiB after arbitrary images.

### Capture ownership results

The earlier overlay sample added 15.7 MiB, including 14.1 MiB marked `Malloc Large (empty)`, while live allocated bytes grew only about 0.35 MiB. This supports allocator-retained freed bitmap storage rather than a demonstrated live frozen-frame leak. An optimized lifetime harness showed frozen frames remaining alive through completion, then releasing when the task body returned; keeping the completed Task handle did not retain them. Replacing the large shade shape with four plain layers showed no meaningful offscreen memory improvement. Neither proposed change was applied without measured application-level savings.
