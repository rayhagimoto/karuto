# Memory profiling evidence

Start with [findings and limitations](../memory-performance.md). These logs were collected on 2026-11-07, macOS 27.0.1, arm64. No optimization was shipped from this investigation.

## Complete app

- [Fresh background launch](app-background-before.txt): 12.7 MiB physical footprint.
- [Small screenshot preview](app-small-preview-before.txt): 32.0 MiB in the adjacent budget-check sample.
- [Capture overlay](app-overlay-before.txt): active capture measurement, not the idle acceptance gate.

## Isolated clipboard owner

These are optimized, private-pasteboard experiments with an AppKit event loop and a separate TIFF reader. The sender is sampled after the reader exits and again after one second of idle. Do not present these values as whole-app measurements.

| Content | Existing implementation | Experimental Deflate + direct source |
| --- | --- | --- |
| UI pattern | [Baseline](appkit-Baseline-3840.log) | [Candidate](appkit-DeflateSource-3840.log) |
| Gradient and grain | [Baseline](appkit-Baseline-3840-grain.log) | [Candidate](appkit-DeflateSource-3840-grain.log) |
| Random noise | [Baseline](appkit-Baseline-3840-noise.log) | [Candidate](appkit-DeflateSource-3840-noise.log) |

The experimental candidate is not in the app. The temporary harness sources remain in `/tmp/karuto-clipboard-memory/` (`Harness-AppKit.swift` and candidate source copies); frozen-frame lifetime and renderer experiments remain in `/tmp/karuto-capture-memory/`. Temporary harness directories are not durable or shipped artifacts. Use `bash scripts/memory.sh PID footprint 50` from the repository root to repeat a current whole-app budget check after establishing its workload state.

Process names and paths in the archived measurements were normalized during the app rename; the measurements predate the current bundle identity.
