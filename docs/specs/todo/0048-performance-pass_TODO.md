# 0048 — Measure every NF target in an optimized benchmark suite, write a performance report, and fix what misses

> Source: PRD.md §6 NF-1 ("Paintbrush latency under 16 ms per frame (60 fps), and 120 fps on ProMotion displays, on a 4000×3000 image on an M1 or newer"), NF-2 ("Opening a 24 MP JPEG takes under 1 s. Pan and zoom stay at 60 fps or better on a 10-layer 4K document"), NF-3 ("Gaussian Blur (radius 20) on a 24 MP layer finishes in under 500 ms on an M1", re-measured), NF-4 (tiled storage, undo stores only changed tiles, configurable budget, default 1 GB); §5.3 T-4 ("The fill runs synchronously on click (0048 may move it off the main actor)"); §8 M7 ("performance pass against the NF targets"); §9 ("The NF-1 to NF-3 performance targets are met on the author's machine"); §4 Testing row (XCTest only for `measure`); AGENTS.md *Workflow for agents* 6 and *Build and test*; spec-writer skill §6 ("Gate only on gross regressions (for example 3× the target)").
> Milestone: M7 (v1.0 polish)
> Depends on: 0047-autosave-and-crash-recovery (and through it every earlier spec; this spec measures and tunes code from 0002, 0003, 0005, 0008, 0009, 0016, 0024, 0028, 0029, 0031, 0041).

## Context

Every earlier spec that touches a hot path added a performance test, but they all run in the **Debug** test pass of the quality gate, so each one gates only on a lenient Debug threshold and none of them proves a PRD §6 target. The existing tests (all XCTest in `PaintDotMacTests`, Debug, kept as they are):

| Spec | Test | Debug gate today |
|---|---|---|
| 0002 | `Performance/ImageDecoderPerformanceTests.testDecode24MegapixelJPEG`, `.testRegionWriteThroughput` | 3 s / 1.5 s |
| 0003 | `Rendering/CanvasRenderPerformanceTests.testColdFrame24MP`, `.testWarmFrame24MP` | 1 s / 48 ms |
| 0008 | `Performance/HistoryPerformanceTests.testFullLayerDiffAndCommit`, `.testOneTileStrokeCommit` | 150 ms / 5 ms |
| 0009 | `Performance/PaintbrushPerformanceTests.testStrokeSegmentLatencyWidth50`, `…Width300`, `.testCommitDiffCost` | 48 ms mean and p95 per `extend` (no GPU) |
| 0011 | `Performance/EraserPerformanceTests` | 48 ms |
| 0012 | `Performance/ColorPickerPerformanceTests` | 50 ms |
| 0013/0014/0018/0019/0020/0022/0023/0025/0035–0040 | selection, tool, operation, thumbnail, and shape/text re-render tests | 3× each spec's own target or report-only |
| 0016 | `Performance/MagicWandPerformanceTests` (24 MP contiguous/global click, checkerboard) | 3 s fill, 10 s click, 20 s checkerboard |
| 0017 | `Performance/PaintBucketPerformanceTests.testLargeContiguousFill` | 5 s |
| 0024 | `Rendering/MetalCompositorPerformanceTests.testPanZoom10Layer4K`, `.testSingleTileEditFrame`, `.testFullRecomposite10Layer4K` | 50 ms / 50 ms / 2 s |
| 0028 | `Performance/OpenRasterPerformanceTests.testSave10Layer4K`, `.testOpen10Layer4K` | gross only |
| 0029 | `JPEGSizeEstimatorPerformanceTests.testEstimate24MP` | 1.5 s |
| 0031/0033 | `Effects/EffectRunnerPerformanceTests.testInvert24MP`, `Effects/HistogramPerformanceTests.testHistogram24MP` | gross / 3 s |
| 0041 | `Effects/Blurs/BlurPerformanceTests.testGaussianRadius20On24MP` (NF-3), `.testMotionBlurDefaultsOn24MP` | 1.5 s / 3 s |
| 0042–0044 | photo, noise/render, stylize/distort effect tests | gross only |

Items earlier specs explicitly deferred to this spec:

- **0003** (`0003…:313`): "Performance tuning for very large dense images (GPU mip generation, upload throttling, intermediate caching) → 0048". 0003 generates the mip chain on the CPU (`Core/Rendering/TileMipmapper.swift`, exact 2×2 box, round half up) and uploads every stale visible tile in one frame.
- **0004** (`0004…:239`, manual 9): NF-2 pan/zoom smoothness is measured by 0048.
- **0005 / 0028 / 0029** (`0005…:193`, `0028…:317,515`, `0029…:166,354`): saving is synchronous on the main actor; "0048 revisits asynchronous writing … if the measured save time warrants it".
- **0006** (`0006…:487`): "0048 measures the paint path including routing".
- **0009** (`0009…:256,276`): "0048 tightens to the real targets"; "Final NF-1 tuning and on-device frame-time measurement (0048)".
- **0016** (`0016…:107,270`, PRD T-4/D-43): `FloodFill` is pure and nonisolated "so 0048 can move it off the main actor without changing the API".
- **0024** (`0024…:151,378`): a paint stroke re-composites each changed tile across all contributing layers; "NF-1/NF-2 optimization beyond the measurements here → 0048".
- **0041** (`0041…:137`): `EffectRunner.Configuration` (`chunkTiles`, `maxConcurrentChunks`, 0031 `…:198`) was tuned against NF-3 in a Debug build; 0048 re-tunes it with optimized code.

What is missing: an optimized-build benchmark run that measures every NF target (including the GPU part of a paint frame and the in-app frame pacing on ProMotion), a report with the numbers and the machine, a way to run it through the quality gate, and the optimizations the measurements call for.

## User story

As the author of PaintDotMac, I can run one command that builds an optimized app, measures every PRD §6 target on my Mac, and writes a report with the numbers, the chip and the OS, and I can see in the report which targets are met; and as a user, painting, panning, zooming, opening, and blurring feel instant on a 4000×3000 or 24 MP image.

## Scope & changes

Work order for the implementer: (1) build the harness, report, probe, target, scheme, and gate step (items 1–9); (2) run `quality-gate.sh --benchmarks` on the unmodified code and keep the report as the **baseline** (`build/performance/baseline/`); (3) profile every row that is *missed* or *triggered* with the checklist in item 10; (4) apply the optimization items in item 11 whose trigger fired; (5) re-run and record baseline and final numbers side by side in the Verification status. An optimization item whose trigger didn't fire is not implemented; its measured number is still recorded.

### Core (pure, unit-tested in the Debug pass)

1. **`PaintDotMac/Core/Rendering/FramePacing.swift`** (new; imports Foundation only)
   ```swift
   public struct SampleStatistics: Codable, Equatable, Sendable {
       public var count: Int
       public var mean: Double
       public var median: Double   // even count: mean of the two middle values
       public var p95: Double      // nearest rank: sorted[ceil(0.95 · count) − 1]
       public var max: Double
       public var min: Double
       public init?(_ samples: [Double])   // nil when empty after dropping non-finite values
   }
   public struct FramePacingStatistics: Codable, Equatable, Sendable {
       public var frameCount: Int            // presented frames considered
       public var burstCount: Int            // runs of frames separated by gaps > burstGap
       public var intervals: SampleStatistics?   // ms between consecutive presents inside a burst
       public var refreshIntervalMs: Double
       public var missedFrames: Int          // Σ over intervals of max(0, round(interval / refresh) − 1)
       public var achievedFPS: Double?       // 1000 / intervals.median
       public static func compute(presentTimes: [Double],      // seconds, any order
                                  refreshInterval: Double,     // seconds, > 0
                                  burstGap: Double = 0.1) -> FramePacingStatistics
   }
   ```
   - `compute` drops non-finite and ≤ 0 times, sorts, removes exact duplicates, splits into bursts where the gap to the previous time is `> burstGap`, and computes intervals only inside bursts. A `refreshInterval` ≤ 0 or non-finite is treated as 1/60 s.
   - No `os`/AppKit import (AGENTS.md rule 1; `os` is not on the allowed list, so signposts live in app glue, item 6).

### Benchmark infrastructure (test support)

2. **`PaintDotMacTests/Support/Performance/PerformanceReport.swift`** (new; compiled into **both** `PaintDotMacTests` and `PaintDotMacBenchmarks`; pure Foundation + `@testable import PaintDotMac` for `SampleStatistics`)
   ```swift
   enum BenchmarkUnit: String, Codable { case milliseconds = "ms", seconds = "s", megabytes = "MB" }
   enum BenchmarkStatus: String, Codable { case met, missed, failed, informational }
   struct BenchmarkResult: Codable, Equatable {
       var id: String                 // e.g. "NF-1.paint.w50.actual"
       var requirement: String        // "NF-1", "NF-2", "NF-3", "NF-4", or the source ID for informational rows ("T-4", "F-1", …)
       var title: String
       var unit: BenchmarkUnit
       var value: Double              // the gated statistic (see the catalog)
       var target: Double?            // nil → informational
       var gate: Double?              // 3 × target unless the catalog says otherwise
       var trigger: Double?           // optimization trigger for informational rows (item 11)
       var samples: SampleStatistics?
       var cpuSeconds: Double?        // process CPU time over the measured section
       var footprintDeltaMB: Double?
       var notes: String
       var status: BenchmarkStatus { get }       // rule below
       var isTriggered: Bool { get }             // trigger != nil && value > trigger
   }
   struct MachineInfo: Codable, Equatable { var chip, model, osVersion, configuration, commit: String; var performanceCores, efficiencyCores: Int; var memoryGB: Double; var maxDisplayFPS: Int; var thermalState: String; var lowPowerMode: Bool; var date: Date }
   struct PerformanceReport: Codable, Equatable {
       var machine: MachineInfo
       var results: [BenchmarkResult]
       var requiredIDs: [String]
       var missingRequired: [String] { get }   // requiredIDs not in results, in requiredIDs order
       func markdown() -> String
       func jsonData() throws -> Data          // pretty-printed, sorted keys, ISO 8601 dates
   }
   ```
   - **Status rule:** `gate` (explicit, or `3 × target` when only a target is given) and `value > gate` → `.failed`; else `target == nil` → `.informational`; else `value ≤ target` → `.met`; else `.missed`. Comparisons are inclusive (a value equal to the gate or target passes it).
   - **Markdown** (exact layout, tested): line 1 `# PaintDotMac performance report`; blank; `- Chip: <chip> (<P>P + <E>E cores, <memoryGB formatted %.0f> GB)`; `- Model: <model>`; `- macOS: <osVersion>`; `- Build: <configuration>, commit <commit>`; `- Display: up to <maxDisplayFPS> Hz`; `- Thermal state: <thermalState>, Low Power Mode: <on|off>`; `- Date: <ISO 8601>`; blank; `| Requirement | Benchmark | Value | Target | Gate | Status |`; `|---|---|---|---|---|---|`; one row per result in `results` order: value/target/gate formatted with the unit (`ms` and `MB` → 2 decimals, `s` → 3 decimals, e.g. `8.12 ms`, `0.734 s`), missing target/gate → `—`; status `met` → `met`, `missed` → `**MISSED**`, `failed` → `**FAILED**`, `informational` → `info` (plus ` (trigger exceeded)` when `isTriggered`). Then, if `missingRequired` is non-empty, a blank line and `Missing required benchmarks: <comma-separated ids>`.
3. **`PaintDotMacTests/Support/Performance/MachineInfo+Current.swift`** (new; both targets): `static func current(configuration:commit:) -> MachineInfo` from `sysctlbyname` (`machdep.cpu.brand_string` → chip, e.g. "Apple M1 Pro"; `hw.model`; `hw.perflevel0.physicalcpu`, `hw.perflevel1.physicalcpu` (0 when absent); `hw.memsize`), `ProcessInfo.processInfo.operatingSystemVersionString`, `.thermalState` (`nominal|fair|serious|critical`), `.isLowPowerModeEnabled`, `NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60`. `commit` comes from the environment variable `PERF_GIT_COMMIT` (set by the gate through `TEST_RUNNER_PERF_GIT_COMMIT`), else `"unknown"`; `configuration` is `"Benchmark"` under `#if BENCHMARK`, else `"Debug"`.
4. **New test target `PaintDotMacBenchmarks`** (XCTest only, `bundle.unit-test`, hosted in the app like `PaintDotMacTests`, `@testable import PaintDotMac`):
   - `PaintDotMacBenchmarks/Support/BenchmarkTestCase.swift`: `class BenchmarkTestCase: XCTestCase` (base of every benchmark). `override class func setUp()` registers `BenchmarkObserver` once with `XCTestObservationCenter.shared`. `continueAfterFailure = true` (one missed row must not hide the others).
   - `…/Support/BenchmarkHarness.swift`:
     - `func timeIterations(id:warmup:iterations:_ body: () throws -> Void) rethrows -> [Double]` — runs `warmup` untimed iterations, then wraps the timed ones in `measure(metrics: [XCTClockMetric(), XCTCPUMetric(limitingToCurrentProcess: true), XCTMemoryMetric()], options:)` with `options.iterationCount = iterations`, and inside the block times each iteration itself with `ContinuousClock` (so the report has the numbers XCTest doesn't expose); returns per-iteration milliseconds.
     - `func timeFrames(...)` — same, but `body` returns the per-frame durations it timed, which are pooled across iterations.
     - `processCPUSeconds()` (`clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)`), `physicalFootprintBytes()` (`task_info(mach_task_self_, TASK_VM_INFO, …)` → `phys_footprint`).
     - `func record(_ result: BenchmarkResult)` → `BenchmarkRecorder.shared.append(result)`, prints the row, and `XCTAssertNotEqual(result.status, .failed, "<id>: <value> > gate <gate>")`.
   - `…/Support/BenchmarkRecorder.swift`: appends each result as one JSON line to `<reportDir>/results.jsonl` immediately (crash-safe); `reportDir` = environment `PERF_REPORT_DIR` (gate sets `TEST_RUNNER_PERF_REPORT_DIR=<repo>/build/performance`), else `<repo>/build/performance` derived from `#filePath`. The directory is emptied of `results.jsonl` when the bundle starts.
   - `…/Support/BenchmarkObserver.swift`: `testBundleDidFinish` reads `results.jsonl`, builds a `PerformanceReport` with `MachineInfo.current(…)` and `BenchmarkCatalog.requiredIDs`, and writes `PerformanceReport.json` and `PerformanceReport.md` to `reportDir`.
   - `…/Support/BenchmarkCatalog.swift`: the single table of IDs, titles, units, targets, gates, and triggers (rows in item 7). `static let requiredIDs` = every row with a target.
   - `…/Support/BenchmarkFixtures.swift` (fixtures are built outside timed sections):
     - `noiseImage(width:height:seed:)` → one opaque layer, every tile allocated, seeded noise (`SeededRandom`).
     - `layeredNoiseImage(width:height:layers: 10, seed:)` → 0024's recipe: layer i seeded noise; even layers opaque, odd layers alpha seeded in 64…255; opacities `[255, 200, 128, 255, 64, 180, 255, 100, 220, 150]`; layers 3 and 7 hidden.
     - `jpeg24MP()` → 6000×4000 CoreGraphics gradient plus 40 seeded filled rects/ellipses, JPEG quality 0.9, written to a temp file (0002's recipe); returns the URL.
     - `strokePath(in rect: CGRect, step: Double, count: Int)` → points on the Lissajous curve `x = midX + 0.4·w·sin(2π·1.3·t)`, `y = midY + 0.4·h·sin(2π·0.7·t + 0.5)`, resampled by arc length so consecutive points are `step` canvas px apart.
   - Sources also include, by explicit path, `PaintDotMacTests/Support/TestImages.swift`, `SeededRandom.swift`, `FakeToolContext.swift`, `MetalTestTarget.swift`, and `PaintDotMacTests/Support/Performance/` (shared, not duplicated).
5. **Build configuration, scheme, and project** (`project.yml`; run `xcodegen generate`):
   - `configs: { Debug: debug, Release: release, Benchmark: release }`. The `Benchmark` configuration inherits Release optimization (`-O`, whole module) and adds, for `PaintDotMac` and `PaintDotMacBenchmarks`: `ENABLE_TESTABILITY: YES`, `ONLY_ACTIVE_ARCH: YES` (native arch only, like Debug), `SWIFT_ACTIVE_COMPILATION_CONDITIONS: BENCHMARK`, `MTL_ENABLE_DEBUG_INFO: NO`. Metal API validation is off for this scheme's test and run actions. `Release` itself is unchanged (universal, no testability).
   - Target `PaintDotMacBenchmarks` (`TEST_HOST`/`BUNDLE_LOADER` as `PaintDotMacTests`, bundle ID `com.thera-engineering.paintdotmac.benchmarks`, `GENERATE_INFOPLIST_FILE: YES`).
   - New scheme **`PaintDotMacBenchmarks`**: build `PaintDotMac: all`, `PaintDotMacBenchmarks: [test]`; `test.config: Benchmark`, `targets: [{ name: PaintDotMacBenchmarks, parallelizable: false }]`, `gatherCoverageData: false`, launch arguments `-ApplePersistenceIgnoreState YES`; `run.config: Benchmark` and `profile.config: Benchmark` so the author can launch and profile the optimized app from Xcode/Instruments (item 10).
   - Scheme `PaintDotMac`: add `PaintDotMacBenchmarks: [test]` to its build targets only (compiled during the Debug test pass so compile errors show up in every gate run; **not** in its test targets, so it never runs in Debug). Nothing else changes.
6. **Signposts (app glue, always compiled)** — `PaintDotMac/App/PerformanceSignposts.swift` (new): `enum PerformanceSignposts { static let signposter = OSSignposter(subsystem: "com.thera-engineering.paintdotmac", category: "Performance") }` with interval names `"Canvas Frame"` (`CanvasView.draw(_:)`: start before building the frame, end in the command buffer's completed handler), `"Stroke Segment"` (`Canvas/CanvasInputRouter.swift` around forwarding one `mouseDragged`), `"Open Document"` (`PaintDocument.read(from:ofType:)`), `"Save Document"` (`PaintDocument.data(ofType:)` / `write`), `"Effect Run"` (`Document/EffectSessionController.swift`, one interval per runner generation), `"Magic Wand"` (`MagicWandTool` click to committed selection). No behavior change; signposts cost nothing unless Instruments records.
7. **Benchmarks** (all in `PaintDotMacBenchmarks/`, `@MainActor` where they touch Metal/AppKit types; GPU work uses an offscreen 2560×1600 `.bgra8Unorm` target from `MetalTestTarget` = a 1280×800-pt window at 2×; each GPU frame is `encode` + `commit` + `waitUntilCompleted`, so a frame's time covers CPU and GPU work). Gates are stored explicitly in `BenchmarkCatalog` as listed (≈ 3 × target, rounded; informational rows get a gross-regression gate or none).

   | ID | Test | Measures (value) | Target | Gate |
   |---|---|---|---|---|
   | `NF-1.paint.w50.actual` | `PaintbrushFrameBenchmarks.testWidth50ActualSize` | p95 ms per paint frame | 8.33 (120 Hz) | 25 |
   | `NF-1.paint.w50.fit` | `.testWidth50FitToWindow` | p95 ms | 8.33 | 25 |
   | `NF-1.paint.w300.actual` | `.testWidth300ActualSize` (hardness 0) | p95 ms | 8.33 | 25 |
   | `NF-1.paint.w50.fast` | `.testWidth50FastStroke` (40 px per frame) | p95 ms | 8.33 | 25 |
   | `NF-1.paint.10layer.w50` | `.testTenLayerWidth50` (active layer 4) | p95 ms | 8.33 | 25 |
   | `NF-1.paint.60hz` | (derived from `NF-1.paint.w50.actual`) | p95 ms | 16.7 | 50 |
   | `NF-1.stroke.commit.w300` | `.testStrokeCommitWidth300` | ms for `mouseUp` (diff + history commit) | — (info) | 150 |
   | `NF-2.open.jpeg24mp` | `OpenBenchmarks.testOpen24MPJPEG` | median s, file → first frame | 1.0 | 3.0 |
   | `NF-2.open.decode24mp` | `.testDecode24MPJPEG` | median s, `ImageDecoder` only | — (info) | 3.0 |
   | `NF-2.coldFrame.24mp` | `.testColdFrame24MP` | median s, first frame incl. uploads + mips | — (info, trigger 0.25) | 1.0 |
   | `NF-2.panzoom.10layer4k` | `PanZoomBenchmarks.testPanZoom10Layer4K` | mean ms per frame | 16.7 | 50 |
   | `NF-2.panzoom.10layer4k.p95` | (same run) | p95 ms | 16.7 | 50 |
   | `NF-2.pan.24mp` | `.testPan24MPSingleLayer` | p95 ms | 16.7 | 50 |
   | `NF-3.gaussian20.24mp` | `GaussianBlurBenchmarks.testRadius20On24MP` | median s | 0.5 | 1.5 |
   | `NF-3.runnerMatrix` | `.testRunnerConfigurationMatrix` | best median s (notes: full matrix) | — (info) | — |
   | `NF-4.open24mp.footprint` | `MemoryBenchmarks.testOpen24MPFootprint` | MB footprint delta | 120 (pixel bytes 96 MiB + 25 %) | 300 (≈ 3 × pixel bytes) |
   | `NF-4.budget.footprint` | `.testBudgetBoundsFootprint` | MB footprint delta | 640 (budget 512 MiB + 25 %) | 1,610 (≈ 3 × budget) |
   | `NF-4.openClose.leak` | `.testOpenCloseTenDocuments` | MB footprint growth | 64 | 300 |
   | `T-4.wand.contiguous.24mp` | `DeferredItemBenchmarks.testMagicWandContiguous24MP` | median s, whole click | — (info, trigger 0.1) | 3.0 |
   | `T-4.wand.global.24mp` | `.testMagicWandGlobal24MP` | median s | — (info, trigger 0.1) | 3.0 |
   | `F-1.ora.save.10layer4k` | `.testSaveORA10Layer4K` | median s | — (info, trigger 1.0) | 10 |
   | `F-1.ora.open.10layer4k` | `.testOpenORA10Layer4K` | median s | — (info) | 10 |
   | `F-2.png.save.24mp` | `.testSavePNG24MP` | median s | — (info, trigger 1.0) | 10 |
   | `F-3.jpeg.save.24mp` | `.testSaveJPEG24MP` | median s (quality 95) | — (info, trigger 1.0) | 10 |
   | `FX.invert.24mp` | `.testInvert24MP` | median s | — (info) | 1.5 |

   Recipes (iterations exclude a warm-up unless stated):
   - **Paint frame (NF-1):** 4000×3000 `noiseImage` (or `layeredNoiseImage(4000, 3000)` for the 10-layer row), `PaintbrushTool` with `FakeToolContext`, primary color opaque black, width 50 hardness 75 antialiasing on (width 300 hardness 0 for that row). Transform: Actual Size = zoom 1 centered; Fit = `CanvasTransform.initial` for the target. Stroke: `strokePath` inside the visible canvas rect, `step` 8 px (40 for the fast row), 240 points. Per iteration: fresh copy of the fixture image (COW, like a real document), a warm renderer that already drew one frame of it, `mouseDown` at point 0 (not timed), then for each next point one **frame** = `mouseDragged` → read `context.image` → renderer `encode` of that image → commit → `waitUntilCompleted`, timed together; `mouseUp` not timed (the commit row times it). 5 iterations, 1,200 frames pooled. The derived 60 Hz row reuses the same samples.
   - **Open (NF-2):** `PaintDocument().read(from: jpegURL, ofType: "public.jpeg")` then a cold `MetalCanvasRenderer` frame of the loaded image at `CanvasTransform.initial` (fresh renderer per iteration), timed together; 5 iterations; value = median. Decode-only and cold-frame rows time the two halves separately.
   - **Pan/zoom (NF-2):** 0024's recipe on `layeredNoiseImage(3840, 2160)`: warm-up one frame at each zoom, then 120 frames alternating pan (+37 device px) and zoom presets 25 %, 33 %, 50 %, 66.7 %, 100 %, 200 %, 400 %; 5 iterations, 600 frames pooled. `testPan24MPSingleLayer`: 0003's warm-frame recipe on `noiseImage(6000, 4000)`, 120 frames × 5.
   - **NF-3:** 0041's recipe (6000×4000 noise layer, real `CoreImageBridge`, whole-layer `EffectRunner.run` to completion including tile assembly and `EffectMaskBlend`, no selection), radius 20; 5 iterations, median. The matrix row runs `chunkTiles ∈ {2, 4, 8}` × `maxConcurrentChunks ∈ {2, 3, 4, 6}`, 3 iterations each, and writes every median into `notes` (`"c2/m2=0.412 s; …"`).
   - **Memory (NF-4):** each test wraps work in `autoreleasepool` and samples `phys_footprint` after a 0.2 s settle (`RunLoop.main.run(until:)`). `testOpen24MPFootprint`: baseline → open the 24 MP JPEG as above and render one frame → delta (the image's tile storage is 384 tiles × 256 KiB = 96 MiB). `testBudgetBoundsFootprint`: a `HistoryStack`/`UndoBridge` with budget 512 MiB over a 4000×3000 noise image; 20 times rewrite every tile with new seeded noise and commit `TileDiffHistoryItem(TileDiff.between(...))`; hard-assert `totalBytes ≤ budgetBytes` after every commit (exact, NF-4/H-5), then record the footprint delta from the post-open baseline. `testOpenCloseTenDocuments`: open a 24 MP document, render, `close()`, ten times; growth = footprint after the tenth close − after the first close.
   - **Deferred items:** Magic Wand: 0016's fixture (6000×4000 gradient with 20 seeded black rects), click through `MagicWandTool.mouseDown`/`mouseUp` with `FakeToolContext` until the selection history step is committed (await the pending fill if item 11 O-3 shipped), tolerance 50 %, Layer sampling; saves call `ImageEncoder.encode` for the format (ORA via `OpenRasterCodec.encode`) on `layeredNoiseImage(3840, 2160)` or `noiseImage(6000, 4000)`; invert = 0031's `testInvert24MP` recipe.
8. **In-app frame probe** (app glue, compiled only under `#if DEBUG || BENCHMARK`):
   - `PaintDotMac/App/LaunchOptions.swift` (modify 0001): `-PerfFrameProbe <path>` → `var perfFrameProbeOutput: URL?` (absolute file path; missing or relative → nil). Unlike 0001's always-compiled hooks, both the property and its parsing branch are inside `#if DEBUG || BENCHMARK`, so the string `PerfFrameProbe` is absent from Release (the gate's check in item 9 relies on this). Read through 0046's `LaunchOptions.current`. Not added to `resettableKeyPrefixes` (it stores nothing in defaults).
   - `PaintDotMac/Canvas/CanvasFrameProbe.swift` (new): `@MainActor final class CanvasFrameProbe` with `init(output: URL, refreshInterval: @escaping () -> Double, now: @escaping () -> Double = { CACurrentMediaTime() })`, `func frameEncoded(cpuMs: Double)`, `func framePresented(at time: CFTimeInterval)` (ignores `time ≤ 0`, i.e. not presented), `func gpuCompleted(ms: Double)`, `func markOpenStarted()`, `func flush()`. It keeps the present times, CPU encode times, and GPU times of the current window of activity; after **0.5 s without a presented frame** (a one-shot timer re-armed on each present) and at `applicationWillTerminate`, `flush()` writes `FrameProbeReport` JSON atomically to the output path (overwriting): `{ "pacing": FramePacingStatistics, "cpuEncodeMs": SampleStatistics?, "gpuMs": SampleStatistics?, "openToFirstFrameMs": Double?, "maxDisplayFPS": Int, "frames": Int }` for **all** frames since launch (cumulative, so the file always describes the whole session).
   - `CanvasView` (modify 0003/0024): when `LaunchOptions.current.perfFrameProbeOutput` is set, it owns one shared probe (one per app; documents share it), calls `frameEncoded` with the time from `draw(_:)` entry to `commit`, `drawable.addPresentedHandler { framePresented(at: $0.presentedTime) }` (hop to the main actor), `gpuCompleted` from `commandBuffer.gpuEndTime − gpuStartTime` in the completed handler. `refreshInterval` = `1 / window.screen.maximumFramesPerSecond` (60 when unknown). `PaintDocument.read` calls `markOpenStarted()`; the first presented frame afterwards sets `openToFirstFrameMs`.
   - With the probe off, `CanvasView` does no extra work (no handlers added).
9. **Quality gate** (`.agents/skills/spec-implementer/scripts/quality-gate.sh`, modify):
   - New option `--benchmarks` (usage text: "Also run the optimized benchmark suite (scheme PaintDotMacBenchmarks, configuration Benchmark) and write build/performance/PerformanceReport.{md,json} (end of every batch; slow; don't use the Mac while it runs)").
   - Step after the Release step: abort with `die` unless `uname -m` is `arm64` ("benchmarks need Apple Silicon"); `TEST_RUNNER_PERF_REPORT_DIR="$ROOT/build/performance" TEST_RUNNER_PERF_GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" xcodebuild -scheme PaintDotMacBenchmarks -destination "$DEST" -derivedDataPath "$ROOT/build/DerivedData-benchmark" -resultBundlePath "$OUT/benchmarks.xcresult" clean test > "$OUT/benchmarks.log"`; `check_warnings` on that log; `summarize "$OUT/benchmarks.xcresult" benchmarks 0` (failed or skipped tests fail the gate); require `build/performance/PerformanceReport.json` to exist; `jq` must find `missingRequired` empty and no result whose computed status is `failed` (the JSON includes `status` and `isTriggered` as encoded fields); print every `missed` and `isTriggered` row as a `WARNING:` line; add `Benchmarks: <met> met, <missed> missed (within 3× gate), <info> informational; report: build/performance/PerformanceReport.md` to the summary.
   - The default gate run (after every spec) does **not** run the benchmarks (only compiles them, item 5).
   - **Release-step addition (same file):** inside the existing `if [[ $RELEASE == 1 ]]` block, directly after the `ditto` copy to `build/$SCHEME.app`, add the probe-exclusion check: `! nm -gU "$ROOT/build/$SCHEME.app/Contents/MacOS/$SCHEME" 2>/dev/null | grep -q PerfFrameProbe && ! strings -a "$ROOT/build/$SCHEME.app/Contents/MacOS/$SCHEME" | grep -q PerfFrameProbe || die "Release binary contains the PerfFrameProbe hook"` (`nm` and `strings -a` read every slice of a universal binary, so the check keeps working after 0050 makes Release universal), and `SUMMARY+=("Release: no PerfFrameProbe")`.
   - **Usage comment:** add `[--benchmarks]` to the usage line and an `--benchmarks` entry under *Options* (text above); update `--help`'s `sed -n '2,34p'` to the comment's new last line.
   - **Ordering with 0050** (built after this spec, also edits this script): 0050 replaces only the Release `xcb -configuration Release …` call with a `-destination 'generic/platform=macOS'` build, adds `SCRIPT_DIR`/`CHECK_BUNDLE` and `lipo iconutil` to the tools loop, adds a Debug bundle check after step 3 and `check-app-bundle.sh` after `codesign --verify` in the Release block, and re-syncs the `--help` range. It keeps this spec's `--benchmarks` option, step, and the probe-exclusion check unchanged. The benchmark step keeps `-destination "$DEST"` (native arch, `ONLY_ACTIVE_ARCH: YES`); it never uses the generic destination.
   - Update AGENTS.md *Build and test* (benchmark command, report location, "run with the Mac idle and on power"), *Spec workflow* (end-of-batch command becomes `quality-gate.sh --sanitizers --release --benchmarks`), *Repository layout* (`PaintDotMacBenchmarks/`), and *Testing expectations* ("NF targets are proven only in the Benchmark configuration; Debug performance tests gate gross regressions"); update `.agents/skills/spec-implementer/SKILL.md:181` to the same end-of-batch command.
   - PRD: §4 Testing row gets "Performance targets are measured in the `Benchmark` build configuration (Release optimization plus testability) by the `PaintDotMacBenchmarks` scheme" and §12 gets the decision row — applied by whoever resolves the open questions below; the implementer checks they are present.
10. **Profiling checklist** (done by the implementer for every *missed* or *triggered* row, and by the author before v1.0; results summarized in the Verification status). Profile the `PaintDotMacBenchmarks` scheme (Profile action = Benchmark configuration) and filter to the `Performance` signpost category:
    - **Time Profiler** + Points of Interest: (a) scribble with Paintbrush width 50 for 10 s on a 4000×3000 photo at 100 % and at Fit; (b) open a 24 MP JPEG; (c) Magic Wand clicks on a 24 MP photo; (d) ⌘S of a 10-layer 4K `.ora`. Record the top 5 self-time symbols of the main thread inside `Stroke Segment`/`Canvas Frame`/`Open Document`/`Save Document`/`Magic Wand` intervals.
    - **Metal System Trace**: pan and pinch-zoom a 10-layer 4K document for 10 s, then paint on layer 5. Record per-frame CPU encode time, GPU time, and time waiting for `nextDrawable`; confirm one command buffer per frame and no frame waiting on a previous frame's tile upload.
    - **Allocations** (+ VM Tracker): open and close ten 24 MP documents; paint 50 strokes then undo all and redo all; set the undo limit to 256 MB in Settings and apply 10 Invert Colors. Check: persistent bytes return to within 64 MB of the post-launch baseline after closing; no per-frame allocations in `Canvas Frame` (zero transient `MTLTexture`/`Data` per frame on warm pan frames); history memory falls when the budget drops.
    - Fix rule: an optimization must not change any pixel, history step, or file byte — every existing unit, golden, integration, and UI test keeps passing unmodified; if a fix needs to change an existing test's expected values, stop and record it as an open question instead.
11. **Optimization items** (each: trigger → allowed change → measurable acceptance). Implement an item only when its trigger fires on the baseline run.
    - **O-1 Cold frame / upload throttling (0003).** Trigger: `NF-2.coldFrame.24mp` > 0.25 s or `NF-2.open.jpeg24mp` > 1.0 s with the cold frame > 25 % of it. Change: (a) `MetalCanvasRenderer` caps upload work per frame (`uploadBudget`: at most N tiles or ~6 ms of CPU mip work per frame, N chosen from measurement), draws not-yet-uploaded visible tiles from a coarser resident level or as checkerboard, and requests another frame until all visible tiles are resident; (b) mip levels for a tile are generated in parallel across tiles with `DispatchQueue.concurrentPerform` (still `TileMipmapper`'s exact CPU math). GPU mip generation is allowed only as a compute kernel that reproduces `TileMipmapper.mipChain` exactly (integer 2×2 box, round half up); `MTLBlitCommandEncoder.generateMipmaps` is **not** allowed (implementation-defined filter). Acceptance: `NF-2.coldFrame.24mp` ≤ 0.25 s and `NF-2.open.jpeg24mp` ≤ 1.0 s; with throttling, the first frame after open is presented within 50 ms and the last tile within the 1 s budget (`OpenBenchmarks.testThrottledFirstFrame` records both); all 0003/0024 renderer tests pass unmodified; new `MetalCanvasRendererThrottleTests` (Debug): with `uploadBudget = 4` on a 16-visible-tile image the first frame uploads exactly 4, the image is complete after 4 frames, and the final target equals the unthrottled frame exactly.
    - **O-2 Paint path (0009/0024/0006).** Trigger: any `NF-1.paint.*` p95 > 8.33 ms. Candidates, applied in order until met, each measured: (1) remove per-`extend` allocations in `BrushStroke` (reuse coverage/scratch buffers across segments); (2) vectorize `BlendOps` Normal compose over a row with `simd` (same integer formula, bit-identical); (3) reuse tile textures from a pool guarded by the frame's completion instead of a fresh `MTLTexture` per changed tile; (4) **stroke composite cache** in `MetalCompositor`: while a stroke is active on layer k, cache per visible tile the composite of layers below k and the premultiplied stack above k (as two textures), so a changed tile composites 3 inputs instead of all contributing layers; invalidate on any non-stroke change. Acceptance: every `NF-1.paint.*` row ≤ 8.33 ms p95 (or the best reached, recorded with the profile evidence if still missed); CPU/Metal parity (±1) and every golden test pass unmodified; new `StrokeCompositeCacheTests` (Debug, if (4) ships): a 10-layer stroke rendered with the cache equals the uncached render exactly at zoom 1 and 0.5, and an opacity change on layer k+1 mid-stroke invalidates the cache (frame equals uncached).
    - **O-3 Magic Wand off the main actor (0016, PRD T-4).** Trigger: `T-4.wand.contiguous.24mp` or `T-4.wand.global.24mp` > 0.1 s. Change: `MagicWandTool.mouseDown` captures the `FloodFillSource` and parameters on the main actor, runs fill + outline + mask in `Task.detached(priority: .userInitiated)` (`FloodFill` is already nonisolated), and commits the same `SelectionHistoryItem` on the main actor when it finishes; `pendingFill: Task<Void, Never>?` is exposed internally for tests. While pending: further canvas clicks of the wand are ignored; `cancel`, `deactivate`, `prepareForHistoryNavigation`, document close, and Escape cancel the task and discard its result (no history step, selection unchanged). Acceptance: main-actor time inside `mouseDown` ≤ 16 ms on the 24 MP fixture (`DeferredItemBenchmarks.testMagicWandMainActorTime`, gate 50 ms); new Debug tests `MagicWandAsyncTests.resultMatchesSynchronous` (awaiting `pendingFill` yields the same selection mask bytes and history name "Magic Wand" as 0016's expectations on its fixtures), `.undoWhilePendingDiscards`, `.toolSwitchWhilePendingDiscards`, `.secondClickWhilePendingIgnored`; every 0016 test passes (tests that assert synchronous completion await `pendingFill` first — the only allowed test change, and only if O-3 ships).
    - **O-4 Effect runner tuning (0041).** Always run (no trigger): set `EffectRunner.Configuration`'s defaults to the fastest `NF-3.runnerMatrix` combination when it beats the current defaults by ≥ 10 %; otherwise keep them. Acceptance: `NF-3.gaussian20.24mp` ≤ 0.5 s (or best recorded); 0031 `EffectRunnerTests` and 0041 `BlurGoldenTests.chunkSeamsInvisible` pass; manual check 4 (dialog preview stays responsive).
    - **O-5 Save time (0005/0028/0029).** Trigger: any save row > 1.0 s. Change, in order: (1) `OpenRasterCodec.encode` encodes layer PNGs concurrently (`concurrentPerform` over layers, results placed in the original order; ZIP bytes identical to the serial path); (2) if a save still exceeds 1 s, `PaintDocument` adopts NSDocument asynchronous saving (`canAsynchronouslyWrite(to:ofType:for:)` → `true`; snapshot the `LayeredImage` (COW), call `unblockUserInteraction()` before encoding, encode off the main actor; 0047's autosave uses the same path and keeps skipping while `UndoBridge.isBusy`). If Swift 6 isolation of `NSDocument` makes (2) need `@unchecked Sendable`/`nonisolated(unsafe)` on document state, don't ship (2): record the numbers and add an open question to the Verification status. Acceptance: (1) `OpenRasterCodecTests.parallelEncodeIsByteIdentical` (seeded 10-layer image: serial vs parallel `Data` equal) and every save row ≤ 1.0 s or recorded; (2) the main actor is blocked ≤ 100 ms during a 10-layer 4K save (`SaveBlockingBenchmarks.testAsyncSaveBlocksBriefly`), and the existing save/close/autosave UI tests pass.
    - **O-6 Open (0002).** Trigger: `NF-2.open.decode24mp` > 0.75 s. Change: decode directly into tile storage (no intermediate full-image buffer kept after tiling) and split rows into tiles in parallel. Acceptance: `NF-2.open.jpeg24mp` ≤ 1.0 s, `NF-4.open24mp.footprint` ≤ 120 MB, all 0002 decoder tests unchanged.
    - **O-7 ProMotion pacing (0003, NF-1 120 fps).** Trigger: manual check 1 shows a probe `achievedFPS` < 110 on a 120 Hz display while the automated `NF-1.paint.*` rows are met (i.e. the draw-on-demand path is capped, not the work). Change: while a canvas gesture (stroke, pan, pinch) is active, drive redraws from `NSView.displayLink(target:selector:)` with `preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)`, drawing only when `needsDisplay` is pending; stop the link when the gesture ends (draw-on-demand otherwise, 0003's no-idle-GPU rule). Acceptance: manual check 1 repeated: median interval ≤ 8.6 ms and `missedFrames` ≤ 5 % of frames over a 10 s scribble; `CanvasViewTests.displayLinkStopsAfterGesture` (Debug): after a simulated gesture end the link is invalidated.

## Acceptance criteria

- [ ] `xcodegen generate` produces scheme `PaintDotMacBenchmarks` and configuration `Benchmark`; the `PaintDotMac` scheme's test action still runs only `PaintDotMacTests` and `PaintDotMacUITests` in Debug, and compiles `PaintDotMacBenchmarks`. → quality gate default run (benchmark compile is part of its test build) + `--benchmarks` run
- [ ] `quality-gate.sh --benchmarks` builds the Benchmark configuration cleanly (no warnings), runs every benchmark with none failed or skipped, and writes `build/performance/PerformanceReport.md` and `.json` with the chip, model, OS, configuration, commit, display rate, thermal state, and one row per catalog ID; it fails when a required row is missing or any row is beyond its gate. → gate `--benchmarks` step; `PerformanceReportTests.*`
- [ ] NF-1 is measured end to end (tool event → stroke → image update → GPU frame) on 4000×3000 single- and 10-layer images at 100 % and Fit, against the 120 Hz (8.33 ms) and 60 Hz (16.7 ms) budgets, gated at 3×. → `PaintbrushFrameBenchmarks.*`
- [ ] NF-2 open (24 MP JPEG, file → first frame) and pan/zoom (10-layer 3840×2160) are measured, gated at 3 s and 50 ms. → `OpenBenchmarks.testOpen24MPJPEG`, `PanZoomBenchmarks.*`
- [ ] NF-3 is re-measured in the optimized build and the runner configuration is (re)tuned. → `GaussianBlurBenchmarks.*`, O-4
- [ ] NF-4: history stays within its budget and the process footprint follows it; opening tracks the tile storage; closing documents releases memory. → `MemoryBenchmarks.*`
- [ ] The frame-pacing math and the report's status rule and markdown are exact. → `FramePacingTests.*`, `PerformanceReportTests.*`
- [ ] The in-app probe records presented frames, CPU/GPU times, and open-to-first-frame, and writes its JSON after 0.5 s idle; it is absent from Release builds. → `CanvasFrameProbeTests.*`, `FrameProbeUITests.testProbeRecordsPaintFrames`, the gate `--release` step's `PerfFrameProbe` symbol/string check, manual 5
- [ ] Every optimization item whose trigger fired is implemented and meets its acceptance (or its best number and profile evidence are recorded); items whose trigger did not fire are recorded as "not triggered" with the number. → the item's named tests and benchmark rows; Verification status table
- [ ] No pixel, history step, or file byte changes: every pre-existing unit, golden, integration, and UI test passes unmodified (except O-3's allowed await). → quality gate default run
- [ ] ProMotion frame pacing during painting is checked on a 120 Hz display. → manual 1 (needs real hardware and a human hand on the trackpad)
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke, Debug and Release).

## Edge cases

- **No Metal device / Intel Mac:** benchmarks fail (never skip) without Metal; the gate's `--benchmarks` step refuses to run on non-arm64 with a clear message (Release stays universal; Intel is best-effort per PRD §4).
- **No ProMotion display:** `maxDisplayFPS` = 60 in the report; automated NF-1 rows still use the 8.33 ms budget (they measure work, not presentation); manual check 1 is marked "not run (no 120 Hz display)".
- **Noisy machine (thermal state ≥ serious, Low Power Mode on, on battery):** the report records thermal state and Low Power Mode; the gate prints `WARNING: benchmarks ran with thermal state <x> / Low Power Mode on; numbers are not representative` but does not fail.
- **Report directory missing or unwritable:** the recorder creates `build/performance/`; a write failure fails the bundle with an `XCTFail` naming the path (never a silent pass).
- **A benchmark crashes mid-run:** rows recorded so far stay in `results.jsonl`; the observer doesn't run, so the gate fails on the missing report.
- **Probe:** output path relative or unwritable → probe disabled, one `NSLog` line, no crash; `presentedTime == 0` (frame not presented, e.g. window occluded) ignored; no frames → `pacing.frameCount == 0`, `intervals == nil`; multiple documents → one shared probe, cumulative; app quit mid-burst → `applicationWillTerminate` flush.
- **`FramePacingStatistics`:** single frame → no intervals; unsorted/duplicate times → sorted, duplicates dropped; non-finite → dropped; refresh ≤ 0 → 1/60 s.
- **`SampleStatistics`:** empty or all non-finite → `nil`; one sample → all fields equal to it.
- **Footprint noise:** footprint rows have generous gates (≈ 3× the theoretical bytes); the exact NF-4 property (`totalBytes ≤ budgetBytes`) is a hard assertion, not a footprint heuristic.
- **O-3 pending fill:** document closed, ⌘Z, tool switch, Escape, or a second wand click while pending → defined above (discard or ignore), never a crash or a late history step on a closed document.
- **O-1 throttled frames:** zoom/pan while tiles are pending → pending set recomputed from the new visible range; an image replacement (`invalidateAll`) clears the pending set.

## Test plan

- **Unit tests (Debug pass, `PaintDotMacTests`):**
  - `PaintDotMacTests/Rendering/FramePacingTests.swift`:
    - `sampleStatisticsBasics`: `[4, 1, 3, 2]` → count 4, mean 2.5, median 2.5, p95 4 (rank ⌈3.8⌉ = 4), min 1, max 4.
    - `sampleStatisticsOddAndSingle`: `[5, 1, 9]` → median 5, p95 9; `[7]` → all fields 7.
    - `sampleStatisticsDropsNonFinite`: `[1, .nan, .infinity, 3]` → count 2, mean 2; `[]` and `[.nan]` → `nil`.
    - `p95NearestRank20`: values 1…20 → p95 19 (rank ⌈19⌉ = 19).
    - `pacingSteady120Hz`: times `[0, 1/120, 2/120, 3/120, 4/120]`, refresh 1/120 → frameCount 5, burstCount 1, 4 intervals with mean 8.333 ms (±0.001), missedFrames 0, achievedFPS 120 (±0.01).
    - `pacingCountsMissedFrames`: `[0, 1/120, 2/120, 4/120, 7/120]` → intervals 8.33, 8.33, 16.67, 25.0 ms; missedFrames 0 + 0 + 1 + 2 = 3.
    - `pacingSplitsBursts`: `[0, 1/60, 0.5, 0.5 + 1/60]`, refresh 1/60 → burstCount 2, 2 intervals of 16.667 ms, missedFrames 0.
    - `pacingSanitizesInput`: `[2/60, 0, 1/60, 1/60, -1, .nan]` → frameCount 3, intervals 16.667 ms × 2 (sorted, duplicate and invalid dropped); refresh 0 → treated as 1/60.
    - `pacingSingleFrame`: `[0.3]` → frameCount 1, `intervals == nil`, `achievedFPS == nil`.
  - `PaintDotMacTests/Support/PerformanceReportTests.swift`:
    - `statusRule`: target 10, gate nil (defaults to 30) → value 8 met, 10 met, 10.01 missed, 30 missed, 30.01 failed; target 8.33 with explicit gate 25 (the catalog's NF-1 rows) → 25 missed, 25.01 failed; target nil, gate nil → informational whatever the value; target nil, gate 3 → value 3 informational, 3.01 failed.
    - `triggerFlag`: informational with trigger 0.1 → value 0.1 not triggered, 0.1001 triggered; no trigger → never triggered.
    - `markdownExactLayout`: a fixed `MachineInfo` (chip "Apple M1", 4P + 4E, 16 GB, model "MacBookAir10,1", macOS "Version 15.1 (Build 24B83)", Benchmark, commit "abc1234", 60 Hz, nominal, Low Power off, date 2026-01-02T03:04:05Z) and three results (met ms, missed s, informational triggered MB) → equals a hand-written expected string, including `**MISSED**`, `info (trigger exceeded)`, `—` for missing target, and number formats `8.12 ms`, `1.234 s`, `130.50 MB`.
    - `missingRequiredListed`: requiredIDs `[a, b, c]`, results `[b]` → `missingRequired == [a, c]` and markdown ends with `Missing required benchmarks: a, c`.
    - `jsonRoundTrip`: encode → decode → equal; the JSON contains `"status"` and `"isTriggered"` keys per result (the gate's `jq` relies on them).
  - `PaintDotMacTests/Support/MachineInfoTests.swift`: `current` → chip non-empty (starts with "Apple" under `#if arch(arm64)`), memoryGB > 0, performanceCores ≥ 1, osVersion == `ProcessInfo…operatingSystemVersionString`, configuration "Debug" in this target, commit "unknown" when `PERF_GIT_COMMIT` is unset.
  - `PaintDotMacTests/Canvas/CanvasFrameProbeTests.swift` (`@MainActor`, Debug): injected `now` and refresh 1/120; present 10 frames 1/120 apart, `flush()` → JSON at a temp path decodes with frames 10, `pacing.missedFrames` 0, `maxDisplayFPS` 120; `framePresented(at: 0)` ignored; `markOpenStarted()` at t = 1.0, present at 1.25 → `openToFirstFrameMs` 250; idle flush: after a present, advancing the run loop 0.6 s writes the file without an explicit `flush()`; relative output path → `CanvasFrameProbe` init returns a disabled probe and nothing is written.
  - `PaintDotMacTests/App/LaunchOptionsTests.swift` (extend 0001): `-PerfFrameProbe /tmp/x.json` → URL; `-PerfFrameProbe x.json` → nil; absent → nil.
  - Optimization tests only if the item ships: `MetalCanvasRendererThrottleTests.*` (O-1), `StrokeCompositeCacheTests.*` (O-2), `MagicWandAsyncTests.*` (O-3), `OpenRasterCodecTests.parallelEncodeIsByteIdentical` (O-5), `CanvasViewTests.displayLinkStopsAfterGesture` (O-7), each with the assertions in item 11.
- **Property tests:** `FramePacingTests.randomPresentTimesInvariants` (seeded `SeededRandom`, 200 cases, seed printed): `frameCount` = number of distinct positive finite inputs; Σ interval count = frameCount − burstCount; `missedFrames ≥ 0`; permuting the input gives an identical result.
- **Benchmarks (`PaintDotMacBenchmarks`, Benchmark configuration, `--benchmarks` only):** every row of item 7's table, with the recipe and gate stated there; each calls `record`, so a row beyond its gate fails its test and appears as `**FAILED**` in the report. Additionally `OpenBenchmarks.testThrottledFirstFrame` (O-1), `DeferredItemBenchmarks.testMagicWandMainActorTime` (O-3), `SaveBlockingBenchmarks.testAsyncSaveBlocksBriefly` (O-5 (2)) when those items ship.
- **UI tests (Debug pass):** `PaintDotMacUITests/FrameProbeUITests.swift` `testProbeRecordsPaintFrames`: launch with a generated 800×600 PNG fixture and `-PerfFrameProbe <tempdir>/probe.json`; select Paintbrush (`tool.paintbrush`); drag across `canvas` for ~1 s in 20 steps; wait up to 5 s for the file; decode it (the UI test target includes `FramePacing.swift`'s Codable shape via a local mirror struct, not `@testable`): `frames ≥ 5`, `pacing.frameCount ≥ 5`, `cpuEncodeMs.count ≥ 5`, `openToFirstFrameMs` > 0 and < 10,000. This proves the probe works; it gates no performance.
- **Release exclusion:** a Debug test can't inspect the Release binary, so the gate's `--release` step greps the Release binary: `nm -gU` / `strings -a` of `build/PaintDotMac.app/Contents/MacOS/PaintDotMac` must not contain `PerfFrameProbe` (exact command and placement in item 9).
- **Quality gate:** default run green (clean build, no warnings, every test passes with none skipped, UI tests ran, launch smoke); end-of-batch `quality-gate.sh --sanitizers --release --benchmarks` green (sanitizers may report UNAVAILABLE). Record baseline and final reports in the Verification status: a table with every catalog row's baseline value, final value, target, status, and the chip/OS line; plus, per optimization item, "triggered/not triggered, shipped/not shipped, before → after".
- **Manual verification** (run on the author's Mac with the Benchmark-configuration app: Xcode → scheme `PaintDotMacBenchmarks` → Run, arguments `-PerfFrameProbe /tmp/paintdotmac-probe.json`):
  1. **ProMotion pacing (NF-1 120 fps):** on a 120 Hz display (MacBook Pro built-in, ProMotion on), open a 4000×3000 photo, Paintbrush width 50, scribble fast and continuously for 10 s at 100 %, then at Fit. Wait 1 s, open `/tmp/paintdotmac-probe.json`: expect `achievedFPS` ≥ 110 and `missedFrames` ≤ 5 % of `frames`. Visually: the stroke follows the pointer with no visible lag or stutter. If `achievedFPS` < 110 with the automated rows met, O-7 applies. Record the numbers.
  2. **60 Hz external display:** repeat 1 on a 60 Hz display: `achievedFPS` ≥ 58, `missedFrames` ≤ 5 %.
  3. **Pan/zoom feel (NF-2):** build a 10-layer 4K document (open a 4K photo, ⇧⌘D nine times), pan with two fingers and pinch-zoom for 10 s: smooth; probe `achievedFPS` ≥ 58 (≥ 110 on ProMotion is a bonus, not required). Also with `MTL_HUD_ENABLED=1` in the scheme's environment: the HUD's frame time stays ≤ 16.7 ms.
  4. **Effect preview responsiveness (O-4):** open a ~4000×3000 photo, Gaussian Blur…, drag Radius from 2 to 100 quickly: the preview follows without beachball; Cancel restores the image.
  5. **Open feel (NF-2):** quit, then open a real 24 MP camera JPEG from Finder: the image appears in about a second; probe `openToFirstFrameMs` < 1,000 (includes window creation, so it may exceed the benchmark slightly; record it). Also confirm the Release app from `build/PaintDotMac.app` launched with `-PerfFrameProbe /tmp/x.json` writes no file (probe compiled out).
  6. **Instruments checklist (item 10):** run the three templates as listed and paste the key findings (top main-thread symbols, per-frame GPU time, persistent-bytes check) into the Verification status.
  7. **Magic Wand (if O-3 shipped):** click with the wand on a 24 MP photo and immediately press ⌘Z: no selection, no "Magic Wand" history row, no crash; click and wait: the selection appears as before.

## Open questions

1. **New target, scheme, and build configuration.** D-4 lists three targets in scheme `PaintDotMac`. Optimized benchmarks need a fourth test target in its own scheme with a `Benchmark` configuration (Release optimization + testability + `BENCHMARK` flag), because Release has no testability and the gate's test run is Debug. *Recommended (applied above):* add target `PaintDotMacBenchmarks`, scheme `PaintDotMacBenchmarks`, configuration `Benchmark`; leave `Release` and the `PaintDotMac` scheme's test targets unchanged; record it in PRD §4 and §12.
2. **When the gate runs the benchmarks.** *Recommended (applied above):* only with `--benchmarks`, which joins the end-of-batch command (`--sanitizers --release --benchmarks`); the per-spec gate only compiles them. Benchmarks take several minutes and need an idle Mac.
3. **A target that can't be met on the author's machine.** *Recommended (applied above):* the spec closes when every row is within its 3× gate and every triggered optimization item has shipped or has its best number and Instruments evidence recorded; rows still *missed* are listed in the Verification status and reported to the user, who decides between relaxing the PRD §6 wording and a follow-up spec. No PRD target changes without the user.
4. **What "120 fps on ProMotion" means for the automated test.** *Recommended (applied above):* the automated NF-1 rows gate the per-frame work (CPU + GPU, p95) against 8.33 ms for every paint row, including the 10-layer case, with 16.7 ms (60 fps) recorded as a secondary row; actual presentation at 120 Hz is the manual probe check 1.
5. **Magic Wand while a background fill is pending (only if O-3 ships).** PRD T-4 allows moving the fill off the main actor but doesn't say what happens to input meanwhile. *Recommended (applied above):* a second wand click is ignored; ⌘Z/⇧⌘Z, History-panel clicks, tool switch, Escape, and closing the document cancel the pending fill and discard it (no history step, selection unchanged); no busy cursor, because the fill is expected to take well under a second.

## Out of scope

- Disk-backed history (H-4) → 0062. Tablet pressure → 0055. Dockable panels → 0052.
- Changing any PRD §6 target, the undo budget default, the tile size (256), or the pixel format (NF-9).
- New user-facing UI (no "performance" menu or setting); the probe is a Debug/Benchmark launch hook only.
- Accessibility and appearance → 0049; bundle size (NF-8) → 0050; use-case acceptance tests → 0051.
- Moving the Debug performance tests of earlier specs into the benchmark target (they stay as Debug gross-regression guards).
- Paint Bucket off the main actor (no PRD allowance; measured indirectly through the wand rows only).
