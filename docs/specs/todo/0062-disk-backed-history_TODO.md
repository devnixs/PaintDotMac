# 0062 — Spill old history steps to disk instead of dropping them

> Source: PRD.md §5.7 H-4 ("Memory budget with spillover of old steps to disk (scratch files in the app's caches directory)", P1), H-5 ("H-4 later replaces dropping with disk spillover"; dropping stays as the fallback here), H-6 (no-op steps, oversized steps kept, "1 GB" = 1 GiB, undo doesn't switch layers); §6 NF-4 (tiled storage, undo stores only changed tiles, configurable budget, default 1 GB), NF-1 (no stalls while painting), NF-5 (autosave/crash recovery, 0047); §12 D-9, D-34; AGENTS.md architecture rules 1–3 and 7.
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (and through the chain: 0008 `HistoryStack`/`HistoryItem`/`TileDiff`/`HistoryCost`/`UndoBridge`, 0010 History panel, 0013 `SelectionHistoryItem`, 0020 `FloatingPixelsHistoryItem`, 0025 `LayerPropertiesHistoryItem`, 0028 `CRC32`, 0031 `UndoBridge.isBusy` + `EffectProgressView`, 0046 Settings + live undo budget + `-UITestUndoLimitPreset`, 0047 autosave, 0048 benchmark target, 0049 `AccessibilityCatalog`/`KeyboardNavigationPlan`).

## Context

Not yet implemented. After 0001–0051, the history engine (0008, `docs/specs/todo/0008-history-stack-and-undo-bridge_TODO.md:120-171`) keeps every step's tiles in memory and, when `totalBytes > budgetBytes`, **folds** the oldest step into the base step (H-5, `0008…:169-171`): the step disappears from the History panel and its "before" state is gone for good. 0046 made the budget live-configurable (`0046…:95-98`), 0048 measures that the process footprint follows it (`0048…:170`).

H-4 (P1) replaces that dropping with **spillover**: when the in-memory budget is exceeded, the tile payload of old steps is written to scratch files in the app's caches directory and released from memory. The steps stay in the History panel and stay undoable; undoing to them reads their tiles back. Dropping (H-5) remains only as the fallback when spilling is impossible (disk quota reached, a write fails, an item kind can't be spilled).

The undoable item kinds that exist after 0051, and what each keeps alive (its `byteCost`):

| Kind | Defined in | `byteCost` (what memory it keeps alive) | Spilled by this spec |
|---|---|---|---|
| `TileDiffHistoryItem` | 0008 `HistoryItem.swift` (`0008…:82`) | Σ before + after tiles of its `TileDiff` | yes: all before/after tiles |
| `DocumentSnapshotHistoryItem` | 0008 (`0008…:83`), + selection bytes (0013 `…:149`) | tiles whose storage is on one side only (`HistoryCost.unsharedTileBytes`) + selection bytes | yes: exactly the unshared layer tiles; tiles shared by both sides and the selections stay in memory |
| `CompositeHistoryItem` | 0008 (`0008…:84`) | Σ children | yes: each spillable child's payload; other children stay |
| `SelectionHistoryItem` | 0013 (`0013…:139-147`) | `HistoryCost.selectionBytes` (partial mask tiles + path estimate) | no (see decision S-4) |
| `FloatingPixelsHistoryItem` | 0020 (`0020…:102-110`) | lift step: `after.byteCount` + underlay tiles differing from `restore.layerSurface`; otherwise 256 | yes: exactly those tiles |
| `LayerPropertiesHistoryItem` | 0025 (`0025…:47-55`) | 0 | no (nothing to spill) |

Types this spec relies on (exact names from the earlier specs): `Tile` (`init(bytes:)`, `byteCount` 262,144, `withUnsafeBytes`, `sharesStorage(with:)`, 0002 `…:100-106`), `TiledSurface` (`tile(at:)`, `setTile(_:at:)`, `allocatedTileCoordinates`), `TileCoordinate` (row-major `<`), `Layer.ID == UUID`, `DocumentState` (`image`, `selection`, `floatingPixels`), `HistoryItem` (`name`, `icon`, `byteCost`, `change`, `isNoOp`, `apply(to:)`, `revert(_:)`), `HistoryStep` (`id`, `name`, `icon`, `item`, `isBase`), `HistoryStack` (`steps`, `currentIndex`, `totalBytes`, `budgetBytes`, `savedStepID`, `commit`, `perform`, `undo`, `redo`, `jump`, `setBudget`, `markSaved`, fold rule), `HistoryCost` (`tileBytes`, `storageKey`, `unsharedTileBytes`, `selectionBytes`, `stepOverheadBytes` = 1,024), `TileDiff`/`TileDiff.Entry`, `UndoBridge` (`state`, `history`, `historyRevision`, `undoManager`, `prepareForNavigation`, `onStateChange`, `onEditedChange`, `commit`, `perform`, `undo`, `redo`, `jump(to:)`, `setBudget`, `reset`, `isBusy` from 0031), `HistoryStepToken` (0008 `…:209`), `CRC32.checksum(_:)` (0028 `Core/IO/CRC32.swift`), `EffectProgressView(title:fraction:onCancel:)` (0031 `…:283`, identifier `effectProgress`), `AppSettings.undoBudgetBytes` and `PaintDocument.settingsProvider` (0046 `…:101`), `LaunchOptions` (0001, extended by 0046/0047), `PaintDotMacBenchmarks` + `BenchmarkCatalog` (0048 `…:138-146`).

## User story

As a PaintDotMac user editing a big image for a long time, I never lose undo history just because it no longer fits in memory: old steps quietly move to disk, stay in the History panel, and ⌘Z or a click on an old History row brings them back. Painting never stalls while this happens. When I close the document or quit, the scratch files are deleted; after a crash they are cleaned up at the next launch.

## Design decisions (stated here so the implementer has nothing to re-derive)

- **S-1 What spills, and in which order.** Only the tile payload of a step spills (the tiles its `byteCost` counts); names, icons, `change`, layer metadata, selections, and the base step always stay in memory. The **in-memory budget** is the existing `budgetBytes` (`settings.undoBudgetBytes`, default 1 GiB). When the resident accounted bytes exceed it, the stack picks spill candidates among non-base steps that are resident and have a non-empty payload, **excluding the current step and the next redo step** (so one ⌘Z and one ⇧⌘Z are always instant). Candidates are ordered by distance from `currentIndex`, farthest first, ties → lower index first. In the common case (current = newest step) this is **oldest first**.
- **S-2 Accounting.** A spilled step's resident cost = its residual bytes (`byteCost − payloadTiles × 262,144`, floored at 0; e.g. a snapshot's selection bytes) + `stepOverheadBytes`. Disk usage is tracked separately (`diskBytes` = Σ file sizes). Within one payload, tiles are deduplicated by storage (`HistoryCost.storageKey`), so a storage shared by two places of one item is written and reloaded once and is still shared after reload. Across steps there is no dedup: a reloaded tile is a fresh storage (pixel-identical). The accounting stays per item and conservative, as in 0008 (`0008…:91`).
- **S-3 On-disk format.** One file per spilled step, `<stepID>.pdmh`, in a per-document directory `<Caches>/PaintDotMac/History/<documentUUID>/` (`<Caches>` = `FileManager.url(for: .cachesDirectory, in: .userDomainMask, …)`, i.e. `~/Library/Caches`, not sandboxed). Files are written once and never modified, and are deleted when their step leaves the history. Each tile is compressed with **LZ4** (`COMPRESSION_LZ4_RAW` from Apple's `Compression` framework) and stored raw when compression doesn't make it smaller; every tile carries a CRC-32 of its uncompressed bytes (0028's `CRC32`). Exact layout in Scope item 4. Per-step files (not an append-only pack) were chosen because a discarded or folded step frees its disk space with one `unlink`, with no compaction.
- **S-4 Selections are not spilled.** `SelectionHistoryItem` and the selections inside snapshots stay in memory: a selection step's mask tiles are 64 KiB each, are only allocated along the edge (`.partial` tiles), and are coupled to a `CGPath` that would need its own serializer. A `HistoryItem` kind that doesn't conform to `SpillableHistoryItem` (today: `SelectionHistoryItem`, `LayerPropertiesHistoryItem`, and any future kind that doesn't opt in) is never spilled; if non-spillable bytes alone keep the stack over budget, H-5 folding applies as before.
- **S-5 Writing is asynchronous; reading is synchronous for single steps.** Writes run on a background serial writer, never on the main actor, so a commit never waits for disk (NF-1). The step stays resident (state `.writing`) until its file is complete, then its tiles are released. Undo/redo of one step (⌘Z, ⇧⌘Z, Edit menu) reads that step's file **synchronously** on the main actor right before reverting/applying it (one file, decoded in parallel; target ≤ 150 ms for a full 4000×3000 layer step, see Performance). **History-panel jumps** that need more than 64 MiB of files read them **asynchronously** first with `UndoBridge.isBusy = true` (0031's busy state) and 0031's progress sheet after 0.5 s, then run the jump through the undo manager as before. Jumps needing ≤ 64 MiB read synchronously. This keeps 0008's UndoBridge contract: every step change still goes through `NSUndoManager` one-to-one.
- **S-6 Disk quota.** Per document, `diskBudgetBytes = 4 × budgetBytes` (4 GiB at the default; follows live budget changes from 0046). Before a write is requested, if `diskBytes + inFlightEstimate + payload estimate > diskBudgetBytes`, the oldest steps are folded (H-5) to free disk until it fits; if folding can't make room (only the candidate itself or protected steps left), the candidate isn't spilled and the memory fallback below applies. Independently, the store refuses a write that would leave less than **2 GiB** free on the volume (`volumeAvailableCapacityForImportantUsageKey`).
- **S-7 Failures fall back to H-5.** Any write failure (I/O error, disk full, refused for free space, store closed) deletes the partial file and **turns spilling off for this document until its history is reset** (open/revert/new). From then on the stack behaves exactly as 0008 (fold the oldest). This is silent, like H-5, with one `Logger` line (subsystem `com.thera-engineering.paintdotmac`, category `history`). A **read failure** (missing file, bad header, CRC mismatch, short read) when the user undoes or redoes into a spilled step can't be hidden: the unreadable step and every step that can only be reached through it are removed, as H-5 does (undo direction: steps 1…i fold into the base; redo direction: steps i…end are discarded), the image doesn't change, and an alert says so (Scope item 11; wording is Open question 3).
- **S-8 Lifetime and cleanup.** The store holds an exclusive `flock` on `<dir>/.lock` for as long as its document is open. Closing the document (`PaintDocument.close()`) cancels pending writes and deletes the directory. A history reset deletes all of the document's files. `applicationWillTerminate` closes every still-open store (safety net). At launch, `applicationWillFinishLaunching` (before any document opens or is restored) deletes every directory under `History/` whose lock can be taken (its owner is dead) and that wasn't modified in the last 60 s (protects a second app instance that is creating its directory). Spill files are never part of autosave or crash recovery: 0047 recovers only the image, with a fresh "Open Image" history (`0047…:75`), so a crashed session's files are garbage and are purged.
- **S-9 Autosave (0047) is unaffected.** Autosave writes `undoBridge.state.image` (always resident) and never reads history. It already skips while `isBusy` (`0047…:62`), which covers the async jump preload. Spilling never changes `state`, the saved marker, or the edited state.
- **S-10 Copy-on-write sharing.** Spilling a step never touches live tiles or other steps' tiles; it only drops the step's own references. If another step or the live image still shares a spilled tile's storage, that memory isn't freed until those references go too (the accounting remains the per-item rule of 0008). Snapshot steps spill only the tiles their cost counts, so "Add New Layer"/"Duplicate Layer" (cost 0) write nothing.

## Scope & changes

### Core (pure Swift, headless, unit-tested) — new folder `PaintDotMac/Core/History/Spill/`

1. **`Core/History/Spill/SpillableHistoryItem.swift`** (new):
   ```swift
   /// A history item whose tile payload can be written out and later rebuilt.
   public protocol SpillableHistoryItem: HistoryItem {
       /// The tiles this item alone keeps alive (exactly what `byteCost` counts as tile bytes), deduplicated by
       /// storage, in a deterministic order, plus a closure that rebuilds an equal item from tiles in that order.
       func makeSpillPayload() -> HistorySpillPayload
   }
   public struct HistorySpillPayload: Sendable {
       public let tiles: [Tile]
       /// Captures only metadata and tiles NOT in `tiles` (shared tiles that stay resident). Precondition: tiles.count matches.
       public let rebuild: @Sendable ([Tile]) -> any HistoryItem
       public var tileBytes: Int { tiles.count * Tile.byteCount }
       public var isEmpty: Bool { tiles.isEmpty }
   }
   ```
   Contract (tested for every kind): (a) `rebuild(payload.tiles)` is an item with the same `name`, `icon`, `change`, `byteCost`, `isNoOp`, whose `apply`/`revert` produce byte-identical states to the original's; (b) `rebuild(decodedCopies)` with pixel-equal tiles of fresh storage does the same; (c) calling `makeSpillPayload()` twice on the same item yields pixel-equal tiles in the same order (the stack recomputes the payload on write completion and eviction, S-1); (d) the rebuild closure retains no storage from `tiles` (test: a debug-only `HistorySpillPayload.retainedStorageKeys: Set<UInt>` filled by each implementation with the storage keys of the tiles its skeleton still holds; must be disjoint from `tiles`' keys).

2. **`Core/History/Spill/HistoryItem+Spill.swift`** (new): conformances.
   - `TileDiffHistoryItem: SpillableHistoryItem`: payload = every non-nil `before` then `after` tile, entry by entry in `diff.entries` order, deduplicated by `storageKey` (first occurrence wins). Skeleton = `[(layerID, coordinate, beforeSlot: Int?, afterSlot: Int?)]` + name/icon. Rebuild builds a `TileDiff` from entries with the same order. 0008 declares no explicit initializers for `TileDiff`/`TileDiff.Entry` (`0008…:95-110`; `isEmpty`, `byteCost`, `changedTiles` are computed from `entries`), so use Swift's synthesized internal memberwise initializers `TileDiff(entries:)` and `TileDiff.Entry(layerID:coordinate:before:after:)` (Core is in the app module); don't redeclare them.
   - `DocumentSnapshotHistoryItem: SpillableHistoryItem`: compute the storage-key sets of all allocated layer tiles on each side (0008's rule). Payload = for side in [before, after], for layer in `image.layers` (bottom → top), for coordinate in `allocatedTileCoordinates` (ascending): tiles whose key is absent from the other side, deduplicated. Skeleton = copies of both `DocumentState`s with those coordinates set to `nil` (via `setTile(nil, at:)`) + `[(side, layerIndex, coordinate, slot)]`. Selection and `floatingPixels` stay in the skeleton. Rebuild re-sets each tile. `Add New Layer`, `Duplicate Layer`, `Move Layer …` produce empty payloads (never candidates).
   - `CompositeHistoryItem: SpillableHistoryItem`: payload = concatenation of the payloads of the children that conform (no cross-child dedup); non-conforming children are kept as they are. Rebuild slices the tile array by each child's count, in child order.
   - `FloatingPixelsHistoryItem: SpillableHistoryItem`: when `before == nil && after != nil` (the only case with a tile cost, 0020 `…:106`): payload = `after.source`'s allocated tiles (ascending), then `after.underlay` tiles whose storage differs from `after.restore.layerSurface`'s tile at the same coordinate (ascending), deduplicated. Otherwise the payload is empty. Skeleton = `after` with those tiles set to nil. Add `func replacingSurfaces(source: TiledSurface, underlay: TiledSurface) -> FloatingPixels` in **`Core/History/Spill/FloatingPixels+Spill.swift`** (implemented as `var copy = self; copy.source = source; copy.underlay = underlay; return copy`; for that, change 0020's `public let source: TiledSurface` to `public internal(set) var source: TiledSurface` — no behavior change, `underlay` is already `var`).
   - `SelectionHistoryItem`, `LayerPropertiesHistoryItem`: no conformance (S-4).

3. **`Core/History/Spill/SpilledHistoryItem.swift`** (new, internal): the placeholder the stack stores in a spilled step.
   ```swift
   struct SpilledHistoryItem: HistoryItem {
       let name: String; let icon: HistoryIcon; let change: HistoryChange
       let byteCost: Int                    // residual bytes (S-2)
       let originalByteCost: Int
       let tileCount: Int
       let rebuild: @Sendable ([Tile]) -> any HistoryItem
       var isNoOp: Bool { false }
       func apply(to state: inout DocumentState) { assertionFailure("spilled step applied"); }  // unreachable through HistoryStack
       func revert(_ state: inout DocumentState) { assertionFailure("spilled step reverted") }
   }
   ```

4. **`Core/History/Spill/HistorySpillFileFormat.swift`** (new, pure; imports Foundation, Compression): encode/decode one step file. All integers little-endian.
   ```
   Header (32 bytes)
     0  4  magic  "PDMH" (0x50 0x44 0x4D 0x48)
     4  2  version = 1
     6  2  reserved = 0
     8  8  stepID (Int64)
    16  4  tileCount (UInt32)
    20  4  reserved = 0
    24  8  dataOffset (UInt64) = 32 + 20 × tileCount
   Tile table (20 bytes per tile, in payload order)
     0  8  offset of the stored bytes from the start of the file (UInt64)
     8  4  storedLength (UInt32)
    12  4  crc32 of the 262,144 uncompressed bytes (UInt32, 0028 CRC32)
    16  1  encoding: 0 = raw (storedLength must be 262,144), 1 = LZ4 raw
    17  3  reserved = 0
   Data: the stored tiles, back to back, in table order.
   ```
   ```swift
   public enum HistorySpillFileFormat {
       public static let magic: [UInt8]; public static let version: UInt16 = 1
       public static func encode(stepID: HistoryStep.ID, tiles: [Tile]) -> Data   // tiles compressed in parallel (concurrentPerform)
       public static func decode(_ data: Data, expectedStepID: HistoryStep.ID, expectedTileCount: Int) throws(HistorySpillError) -> [Tile]
   }
   public enum HistorySpillError: Error, Equatable, Sendable {
       case missing, corrupt(String), io(Int32), insufficientSpace, quotaExceeded, closed, disabled
   }
   ```
   `decode` throws `.corrupt(reason)` for: data shorter than the header, wrong magic, unknown version, step ID or tile count mismatch, table or data out of bounds, unknown encoding, raw length ≠ 262,144, LZ4 output ≠ 262,144 bytes, CRC mismatch. It never traps on malformed input. Decoding runs tiles in parallel.

5. **`Core/History/Spill/HistorySpillStore.swift`** (new; Foundation + Darwin `flock`):
   ```swift
   public protocol HistorySpillStoring: AnyObject, Sendable {
       func write(stepID: HistoryStep.ID, tiles: [Tile]) throws(HistorySpillError) -> HistorySpillRecord
       func read(_ record: HistorySpillRecord) throws(HistorySpillError) -> [Tile]
       func remove(_ records: [HistorySpillRecord])
       func removeAll()
       func close()
   }
   public struct HistorySpillRecord: Hashable, Sendable {
       public let stepID: HistoryStep.ID
       public let fileName: String          // "<stepID>.pdmh"
       public let fileBytes: Int
       public let tileCount: Int
   }
   public final class HistorySpillStore: HistorySpillStoring, @unchecked Sendable {  // internal NSLock guards state
       public static func defaultRoot() throws -> URL   // <Caches>/PaintDotMac/History (created if missing)
       public static let minimumFreeBytes = 2_147_483_648
       public static let lockFileName = ".lock"
       public init(root: URL, documentID: UUID = UUID(), minimumFreeBytes: Int = HistorySpillStore.minimumFreeBytes,
                   availableCapacity: @escaping @Sendable (URL) -> Int? = HistorySpillStore.volumeAvailableCapacity) throws(HistorySpillError)
       public let directory: URL            // root/<documentID uuidString>
       public static func purgeStale(root: URL, now: Date = Date(), minimumAge: TimeInterval = 60) -> [URL]
       public static func closeAllOpenStores()   // weak registry; used by applicationWillTerminate
   }
   ```
   - `init` creates `directory` (intermediate directories too), creates and opens `.lock`, and takes `flock(fd, LOCK_EX | LOCK_NB)`; failure → `.io(errno)`. Registers itself in a process-wide weak registry.
   - `write`: after `close()` → `.closed`. Encodes with `HistorySpillFileFormat.encode`; if `availableCapacity(directory)` is non-nil and `capacity − data.count < minimumFreeBytes` → `.insufficientSpace` (nothing written). Writes to `<stepID>.pdmh.partial`, then renames to `<stepID>.pdmh`; any error removes the partial file and throws `.io(errno)`. Returns the record with `fileBytes = data.count`.
   - `read`: after `close()` → `.closed`; no file → `.missing`; read with `Data(contentsOf:options: .alwaysMapped)`, `fileBytes` mismatch → `.corrupt("size")`, then `decode`.
   - `remove`/`removeAll`: delete files (ignore missing). `close()`: idempotent; deletes the directory, releases the lock, unregisters.
   - `purgeStale`: for each subdirectory of `root`: skip if its modification date is newer than `now − minimumAge`; open its `.lock` (missing lock file → stale) and try `LOCK_EX | LOCK_NB`; if acquired (or no lock file) → delete the directory; if `EWOULDBLOCK` → keep (owned by a live process; `flock` locks are per open file description, so this works within one process too). Returns the deleted URLs. Never throws; errors are skipped.

6. **`Core/History/Spill/HistorySpillWriter.swift`** (new): runs writes off the main actor.
   ```swift
   public final class HistorySpillWriter: @unchecked Sendable {
       public enum Mode: Sendable { case background, immediate }   // immediate: tests (write inline on the caller)
       public init(store: any HistorySpillStoring, mode: Mode = .background, maxInFlightBytes: Int = 536_870_912)
       public func enqueue(_ request: HistorySpillRequest, completion: @escaping @Sendable (HistoryStep.ID, Result<HistorySpillRecord, HistorySpillError>) -> Void)
       public func cancel(stepID: HistoryStep.ID)          // not started → skipped, completion called with .failure(.closed)
       public var inFlightBytes: Int { get }               // Σ estimates of queued + running requests
       public func waitUntilInFlight(below bytes: Int)     // blocks the caller; used for back-pressure
       public func drain()                                 // waits for all queued work (tests, close)
   }
   ```
   One serial `DispatchQueue(label: "…history-spill", qos: .utility)`. `inFlightBytes` is decremented on the writer queue when a request finishes, before its completion is delivered, so `waitUntilInFlight` on the main thread can't deadlock.

7. **`Core/History/HistoryStack.swift`** (extend 0008) — residency, spill decisions, and reload, with **no file I/O** (I/O goes through the bridge).
   ```swift
   public enum HistoryStepResidency: Equatable, Sendable {
       case resident                         // item in memory, no file
       case writing                          // item in memory, write in flight
       case spilled(HistorySpillRecord)      // only a SpilledHistoryItem in memory
       case reloaded(HistorySpillRecord)     // item in memory and its file is still valid (eviction is free)
   }
   public struct HistorySpillSettings: Equatable, Sendable {
       public var isEnabled: Bool
       public static let diskBudgetMultiplier = 4
       public static let disabled = HistorySpillSettings(isEnabled: false)
       public static let enabled = HistorySpillSettings(isEnabled: true)
   }
   public enum HistorySpillState: Equatable, Sendable { case disabled, active, failed(HistorySpillError) }
   public struct HistorySpillRequest: Sendable { public let stepID: HistoryStep.ID; public let tiles: [Tile]; public var estimatedBytes: Int }
   public struct HistorySpillEffects: Sendable {
       public var writes: [HistorySpillRequest] = []
       public var deletions: [HistorySpillRecord] = []
       public var cancelledWrites: [HistoryStep.ID] = []
       public var droppedStepIDs: [HistoryStep.ID] = []        // folds/discards caused by spill handling (bridge removes their undo actions)
       public var isEmpty: Bool
   }
   ```
   - `HistoryStep` (0008): `item` becomes `public internal(set) var item`; add `public internal(set) var residency: HistoryStepResidency` (`.resident` for new steps and the base).
   - `public init(base:budgetBytes:spill: HistorySpillSettings = .disabled)`. **Default is disabled**, so every 0008–0051 test that builds a `HistoryStack` or `UndoBridge` directly keeps its exact behavior (including 0037's `sharesStorage` assertions and 0010's `budgetDropRemovesOldestRows`).
   - New read-only properties: `spillState` (`.active` when enabled, else `.disabled`), `diskBudgetBytes` (= `diskBudgetMultiplier × budgetBytes`), `diskBytes` (Σ `fileBytes` of `.spilled`/`.reloaded` steps), `pendingSpillBytes` (Σ estimates of `.writing` steps), `func residency(ofStepAt index: Int) -> HistoryStepResidency`.
   - `totalBytes` keeps 0008's formula over `step.item.byteCost` + overhead; because a spilled step's item is a `SpilledHistoryItem` with the residual cost, it becomes the **resident** accounted bytes. With spilling disabled it is identical to 0008.
   - **Enforcement** (replaces the body of 0008's "enforce the budget" step; still run after `commit`, `setBudget`, and now also after `undo`, `redo`, `jump`, `completeSpill`, `installReloaded`):
     1. `projected = totalBytes − Σ byteCost of .writing steps`. If `projected ≤ budgetBytes` → stop.
     2. If `spillState == .active`: walk candidates (S-1 order; resident or reloaded; `item is SpillableHistoryItem`; payload non-empty; index ∉ {currentIndex, currentIndex + 1}) while `projected > budgetBytes`:
        - `.reloaded(record)` → **evict**: `item = SpilledHistoryItem(from: item.makeSpillPayload(), …)`, `residency = .spilled(record)`; no I/O.
        - `.resident` → disk check (S-6): while `diskBytes + pendingSpillBytes + estimate > diskBudgetBytes` and `steps[1]` is not this candidate and `currentIndex ≥ 2`, fold `steps[1]` (0008's fold, plus: its record → `deletions`, a `.writing` fold → `cancelledWrites`; its ID → `droppedStepIDs`). If it still doesn't fit → skip the candidate. Otherwise append a `HistorySpillRequest(stepID, tiles: payload.tiles, estimatedBytes: 32 + 20 × n + n × 262,144)` to `writes`, set `.writing`, `projected −= byteCost`.
     3. If still `projected > budgetBytes`: 0008's fold loop (`while totalBytes − writingBytes > budgetBytes && currentIndex >= 2 { fold steps[1] }`), with the same deletion/cancellation bookkeeping. With spilling disabled or failed, this is exactly 0008's rule.
   - **Discards** (commit after undo) and **resets** put the discarded steps' records in `deletions` and `.writing` IDs in `cancelledWrites`.
   - `public mutating func takeSpillEffects() -> HistorySpillEffects` — returns and clears the accumulated effects.
   - `public mutating func completeSpill(stepID:result:)`:
     - Step gone (folded/discarded): success → its record goes to `deletions`; failure → nothing.
     - Success, step `.writing`: recompute `payload = item.makeSpillPayload()`; if `payload.tiles.count != record.tileCount` → treat as failure. If index ∉ {currentIndex, currentIndex + 1} → `item = SpilledHistoryItem(...)`, `.spilled(record)`; else `.reloaded(record)`. Enforce.
     - Failure: step back to `.resident`, `spillState = .failed(error)`, enforce (folds per 0008).
   - `public func recordsNeeded(toReach index: Int) -> [HistorySpillRecord]` — records of the `.spilled` steps that the path from `currentIndex` to `index` reverts (`index+1…currentIndex`, descending) or applies (`currentIndex+1…index`, ascending), in that order; `[]` for out-of-range.
   - `public mutating func installReloaded(stepID:tiles:) throws(HistorySpillError)` — the step must be `.spilled`; `tiles.count != tileCount` → `.corrupt("tile count")`; `item = rebuild(tiles)`, `.reloaded(record)`. Does **not** enforce (the bridge enforces after the navigation, so a reloaded step isn't evicted before it is used).
   - `public mutating func dropUnreadable(stepID:) -> HistorySpillEffects` — if the step's index `i ≤ currentIndex`: fold steps 1…i into the base (0008 fold rule `i` times; `currentIndex −= i`; saved-marker rules as 0008); if `i > currentIndex`: discard steps i…end (as a commit's discard: saved marker nil if among them). Records → `deletions`, writes → `cancelledWrites`, IDs → `droppedStepIDs`. `state` is untouched.
   - `undo`/`redo`/`jump` (0008): if a step they would revert/apply is `.spilled`, they return `nil`/`[]` and change nothing (defined; the bridge always reloads first).
   - `setBudget` updates `diskBudgetBytes` too.
   - `public mutating func resetSpill(_ settings: HistorySpillSettings)` — re-enables after a failure (used by `UndoBridge.reset`).

8. **`Core/Settings/AppSettings.swift`**: no new key (the disk budget is derived, S-6; Open question 1).

### Platform glue — `PaintDotMac/Document/`, `App/`, `UI/`

9. **`Document/UndoBridge+Spill.swift`** (new; extends 0008's `UndoBridge`, `@MainActor`):
   - `UndoBridge.init` gains `spill: (any HistorySpillStoring)? = nil, spillWriterMode: HistorySpillWriter.Mode = .background`. With a store, the stack is created with `.enabled` and the bridge owns a `HistorySpillWriter`; without, behavior is 0008's.
   - `private func processSpillEffects()` — called at the end of `commit`, `perform`, `performUndo`, `performRedo`, `jump`, `setBudget`, `reset`, and each write completion. Loops `history.takeSpillEffects()` until empty: `deletions` → `store.remove`; `cancelledWrites` → `writer.cancel`; `writes` → `writer.enqueue(request) { id, result in Task { @MainActor in self?.spillDidFinish(id, result) } }` (immediate mode: inline write then `history.completeSpill`); `droppedStepIDs` → same as 0008's dropped path (`undoManager.removeAllActions(withTarget: token)`, forget token, bump `historyRevision` once per call, `onEditedChange`). After enqueuing, if `writer.inFlightBytes > 536_870_912`, `writer.waitUntilInFlight(below: 268_435_456)` (back-pressure; only reached when the disk can't keep up).
   - `spillDidFinish(_:_:)` → `history.completeSpill`, then `processSpillEffects()`. A completion arriving after `close`/`reset` is ignored (generation counter).
   - **Reload before single-step navigation:** `performUndo` (after `prepareForNavigation`, before `history.undo`) and `performRedo` call `ensureResident(index:)`: if the step is `.spilled(record)`, `let tiles = try store.read(record)` (synchronous) then `try history.installReloaded(...)`. After the step, `processSpillEffects()` (enforcement may evict far steps).
   - **Unreadable step (S-7):** on a read/install error inside `performUndo`/`performRedo`: don't change `state`, don't register the redo/undo action (the manager has already popped this group); `let effects = history.dropUnreadable(stepID:)`; forget the tokens of `effects.droppedStepIDs`; delete their files; then **on the next main-queue turn** (`DispatchQueue.main.async`, because `NSUndoManager` is mid-undo) remove the remaining actions of those tokens, bump `historyRevision` once, call `onEditedChange`, and call `onHistoryLoss?(.unreadableSteps(count:))`. After that turn, 0008's mirror invariants hold again (tested).
   - **Jump (S-5):** `jump(to:)` computes `history.recordsNeeded(toReach:)`. Σ `fileBytes` ≤ `UndoBridge.synchronousReloadLimitBytes` (`67_108_864`) → read and install them synchronously, then 0008's jump loop. Otherwise: `isBusy = true`; a detached task reads the records (`store` is `Sendable`), reporting `fraction = bytesRead / total` to `@Observable var historyLoadProgress: Double?` (nil when idle); on completion on the main actor: `isBusy = false`, `historyLoadProgress = nil`; if cancelled → nothing changes; if any read failed → `dropUnreadable` for the failing step nearest the current step, the async cleanup above, `onHistoryLoss`, and **no jump**; else install all and run 0008's jump loop (one revision bump, one `onStateChange`). `func cancelHistoryLoad()` cancels the task. `internal var pendingHistoryLoad: Task<Void, Never>?` lets tests await it. The 0031 rule that nothing else calls `commit`/`undo`/`jump` while busy still holds: the jump loop runs after `isBusy` is cleared.
   - `var onHistoryLoss: ((HistoryLossReason) -> Void)?` with `enum HistoryLossReason: Equatable { case unreadableSteps(count: Int) }`.
   - `reset(state:base:)` (0008): additionally cancels writes, `store.removeAll()`, `history.resetSpill(.enabled)` when a store exists.
   - `func shutDownSpill()` — cancels the history load, `writer.cancel` all, `writer.drain()`, `store.close()`. Idempotent.
   - The debug-only failure hook `-UITestHistorySpillFailReads YES` (item 13) wraps the store in `FailingReadsSpillStore` (in this file, `#if DEBUG`), whose `read` always throws `.corrupt("injected")`.

10. **`Document/PaintDocument.swift`** (extend):
   - `static var historySpillProvider: @MainActor () -> (any HistorySpillStoring)?` (internal; tests swap it, like 0046's `settingsProvider`). Default: `nil` when `LaunchOptions` (Debug) has `-UITestHistorySpill NO`; otherwise `try? HistorySpillStore(root: LaunchOptions.historySpillRoot ?? HistorySpillStore.defaultRoot())` — if the store can't be created (no caches directory, lock failure), the document simply runs without spill (H-5) and logs once.
   - The bridge is created with that store. `close()` calls `undoBridge.shutDownSpill()` before `super.close()` (alongside 0047's autosave cleanup).
   - 0046's `UndoBudgetLiveTests` keep testing the H-5 rules by setting `historySpillProvider = { nil }` (item 16); the spill behavior of a live budget change is tested by new tests.

11. **`Document/DocumentWindowController.swift`** (extend):
   - `undoBridge.onHistoryLoss` → a sheet `NSAlert` (identifier `historyLossAlert`, style `.warning`; its button identifier `historyLossAlert.ok`): message **"Some history steps couldn't be read and were removed."**, informative text **"The image wasn't changed. You can still undo the remaining steps."**, one button **"OK"**. If another sheet is attached, the alert is queued until it closes. (Wording: Open question 3.)
   - While `undoBridge.historyLoadProgress != nil` for more than **0.5 s**, present 0031's `EffectProgressView(title: "Loading History", fraction:, onCancel: { undoBridge.cancelHistoryLoad() })` as a sheet (identifier `effectProgress`); dismiss it when the load ends. Escape = Cancel. Menu validation is already disabled by `isBusy` (0031 `…:257`).

12. **`App/AppDelegate.swift`** (extend 0001): in `applicationWillFinishLaunching(_:)`, before `PaintDocumentController` exists, call `HistorySpillStore.purgeStale(root:)` for `LaunchOptions.historySpillRoot ?? (try? HistorySpillStore.defaultRoot())`. In `applicationWillTerminate(_:)`, `HistorySpillStore.closeAllOpenStores()`.

13. **`App/LaunchOptions.swift`** (extend; use gated by `#if DEBUG`, always nil/false in Release):
   - `-UITestHistorySpill NO` → `historySpillDisabled: Bool` (YES/true/1 → false; NO/false/0 → true; absent → false).
   - `-UITestHistorySpillRoot <path>` → `historySpillRoot: URL?` (absolute paths only; else nil).
   - `-UITestHistorySpillFailReads YES` → `historySpillFailReads: Bool`.
   The values don't consume other options' arguments (same rule as 0047's parser).

14. **`Core/Accessibility/AccessibilityCatalog.swift`** / **`KeyboardNavigationPlan.swift`** (extend 0049): new `AccessibilitySurface` case `historyLossAlert` (appended last) with entries `historyLossAlert` group "History Steps Removed" and `historyLossAlert.ok` button "OK"; plan: initial and default `historyLossAlert.ok`, tabOrder `[historyLossAlert.ok]`, no cancel (0049's `dialogsHaveDefaultAndCancel` applies to `*Dialog` surfaces only). The "Loading History" sheet reuses 0049's `effectProgress` entries (`effectProgress.bar`, dynamic label = its title "Loading History"; `effectProgress.cancel` "Cancel").
15. **`UI/SettingsView.swift`** (extend 0046): the footnote under "Undo memory limit:" changes from "When the limit is reached, the oldest history steps are removed." to **"When the limit is reached, older history steps are moved to disk."** (Open question 2.) No new control (Open question 1).

16. **Existing tests superseded by H-4** (rewritten here, as 0008 did for 0005):
   - 0046 `PaintDotMacTests/Document/UndoBudgetLiveTests.swift`: in its suite setup, set `PaintDocument.historySpillProvider = { nil }` (restored in teardown); every existing case then keeps asserting 0008's fold rules unchanged — they now document the H-5 fallback.
   - 0046 `SettingsUITests.testLoweringUndoLimitDropsOldSteps`: add `-UITestHistorySpill NO` to its launch arguments (unchanged assertions; it covers the fallback through the UI). Its spill counterpart is `HistorySpillUITests.testLoweringUndoLimitKeepsStepsUndoable` below.
   - 0046's spec text (`0046…:143`, the footnote) is superseded by item 15; no 0046 test asserts the footnote string, so no 0046 test changes for it. The new string is asserted by `HistorySpillUITests.testSettingsFootnoteMentionsDisk`.

17. `project.yml`: no target changes; new files are picked up by the source globs. Run `xcodegen generate`. `Compression` is already allowed in Core (AGENTS.md rule 1) and linked since 0028.

No PRD.md change in this spec (H-4 and H-5 already state the behavior); the open questions below may add one.

### Performance and memory (NF-1, NF-4)
- **NF-4:** the in-memory budget now bounds resident history (`totalBytes − writing ≤ budgetBytes` whenever a spillable candidate exists); disk use is bounded by `4 × budgetBytes` per document. 0048's `testBudgetBoundsFootprint` builds its stack without spill and keeps measuring H-5; the new benchmarks below measure spill.
- **NF-1:** commits never wait for disk (writes are on the writer queue; the only main-thread cost is computing the payload, O(tiles), no copying). Back-pressure blocks only when more than 512 MiB of writes are queued.
- Undo into a spilled step costs one synchronous file read + LZ4 decode on the main actor (S-5).

## Acceptance criteria
- [ ] With spilling enabled, exceeding the memory budget spills the oldest steps (farthest from the current step; never the base, the current, or the next redo step) instead of dropping them; the History panel keeps every step. → `HistorySpillStackTests.spillsOldestFirst`, `.protectsCurrentAndNextRedo`, `.candidateOrderAfterUndo`, `HistorySpillUITests.testUndoThroughSpilledSteps`
- [ ] Undo, redo, and jumps through spilled steps restore byte-identical pixels, selections, floating pixels, layer structure, and active layer index for every spillable item kind. → `SpillableHistoryItemTests.*`, `HistorySpillIntegrationTests.everyKindRoundTripsThroughDisk`, `HistorySpillPropertyTests.randomSessionsMatchOracle`
- [ ] Resident accounting: a spilled step costs only its residual bytes + 1,024; `diskBytes` equals the sum of file sizes; shared storages inside one item are written once and shared after reload; zero-cost steps write nothing. → `HistorySpillStackTests.accounting*`, `SpillableHistoryItemTests.snapshotSpillsOnlyUnsharedTiles`, `.dedupWithinPayload`
- [ ] The file format round-trips exactly, compresses with LZ4 or stores raw, and rejects every malformed input with `.corrupt` and no crash. → `HistorySpillFileFormatTests.*`
- [ ] The disk quota (4 × budget) is respected by folding the oldest steps; a full volume (< 2 GiB free), a write error, or an unusable store falls back to H-5 folding for the rest of the session, silently. → `HistorySpillStackTests.diskQuotaFoldsOldest`, `.writeFailureFallsBackToFolding`, `HistorySpillStoreTests.refusesBelowMinimumFree`, `HistorySpillIntegrationTests.writeErrorFallsBack`
- [ ] A missing or corrupt file met during undo/redo removes the unreachable steps (H-5 semantics), leaves the image unchanged, keeps `NSUndoManager` in sync, and shows the "couldn't be read" alert. → `HistorySpillIntegrationTests.missingFileOnUndo`, `.corruptFileOnRedo`, `.unreadableKeepsManagerInSync`, `HistorySpillUITests.testUnreadableStepShowsAlert`
- [ ] Large jumps load asynchronously with the document busy and a cancellable "Loading History" progress sheet after 0.5 s; cancel changes nothing. → `HistorySpillIntegrationTests.largeJumpLoadsAsync`, `.cancelLargeJump`, manual 2
- [ ] Commits never block on disk writes; completions after a discard, fold, reset, or close delete orphaned files and never crash. → `HistorySpillIntegrationTests.commitDoesNotWaitForWriter`, `.completionAfterDiscardDeletesFile`, `.completionAfterCloseIgnored`
- [ ] Closing a document deletes its directory; a history reset deletes its files; stale directories (lock free, older than 60 s) are purged at launch while live ones are kept. → `HistorySpillStoreTests.closeDeletesDirectory`, `.purgeStale*`, `HistorySpillIntegrationTests.resetDeletesFiles`, `HistorySpillUITests.testCloseDeletesSpillDirectory`, `.testStaleDirectoryPurgedAtLaunch`
- [ ] Autosave, the saved marker, and the edited state are unaffected by spilling. → `HistorySpillIntegrationTests.spillDoesNotTouchEditedState`, `.autosaveWhileSpilled`
- [ ] With spilling disabled (default `HistoryStack`, `-UITestHistorySpill NO`, `historySpillProvider = { nil }`), every 0008/0010/0046 history test passes unchanged. → quality gate
- [ ] Lowering the undo limit in Settings spills (doesn't drop) old steps, and all of them remain undoable. → `HistorySpillIntegrationTests.loweringBudgetSpills`, `HistorySpillUITests.testLoweringUndoLimitKeepsStepsUndoable`
- [ ] Settings' footnote under "Undo memory limit:" reads "When the limit is reached, older history steps are moved to disk." (replaces 0046's text). → `HistorySpillUITests.testSettingsFootnoteMentionsDisk`
- [ ] The history-loss alert and the Loading History sheet are catalogued for accessibility (0049). → `AccessibilityCatalogTests.historyLossAlertEntries`, `KeyboardNavigationPlanTests.historyLossAlertPlan`, `HistorySpillUITests.testUnreadableStepShowsAlert` (asserts `historyLossAlert.ok` label "OK"; it stands in for 0049's per-surface `AccessibilityCatalogUITests` test because the alert needs the `-UITestHistorySpillFailReads` hook)
- [ ] Spill write, reload, and commit-with-spill timings are reported and within their gates. → `HistorySpillBenchmarks.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases
- **Budget 0:** every spillable non-protected step spills; disk budget 0 → every candidate fails the disk check → fold fallback (keeps base + current, 0008). → `HistorySpillStackTests.zeroBudget`
- **A single step bigger than the budget** (H-6): it is the current step, so it's never spilled while current; after the next commit it becomes a candidate.
- **Step bigger than the disk budget:** skipped as a candidate; fold fallback.
- **Undo into a step whose write is still in flight:** the step is still resident (`.writing`), so undo works with no read; the completion then marks it `.reloaded`. → `HistorySpillIntegrationTests.undoWhileWriting`
- **Commit discards a `.writing` redo step:** the write is cancelled or, if it finished, its file is deleted on completion. → `.completionAfterDiscardDeletesFile`
- **Fold of a spilled step** (fallback or disk quota): its file is deleted; no tiles are read (folding needs none).
- **Saved step spilled:** the saved marker is unchanged (spilling is not folding); undo back to it makes the document clean. → `.spillDoesNotTouchEditedState`
- **Floating pixels step spilled while pixels still float:** `state.floatingPixels` is live state (not spilled); only the history item's copy spills. Undoing it reloads first. → `SpillableHistoryItemTests.floatingPixelsRoundTrip`
- **Edge tiles and sparse tiles:** a `nil` before/after stays `nil` (no slot); edge tiles are full 256×256 tiles (0002) and round-trip including their zero padding.
- **Fully transparent tiles and RGB under alpha 0** round-trip byte-exactly.
- **Incompressible tiles** (noise) are stored raw (`encoding 0`).
- **Document closed during an async jump load or with writes in flight:** load cancelled, writes cancelled/drained, directory deleted, late completions ignored. → `.completionAfterCloseIgnored`
- **Two app instances:** each document has its own UUID directory and lock; purge never deletes a locked directory. → `HistorySpillStoreTests.purgeKeepsLockedDirectory`
- **Caches directory unavailable / lock can't be taken:** the document runs with spilling disabled (H-5); no alert.
- **Settings budget change while writes are in flight:** enforcement accounts for `.writing` bytes, so nothing is spilled twice. → `HistorySpillStackTests.noDoubleSpill`
- **Every failure path** is a defined no-crash outcome: `.corrupt`/`.missing` on read → S-7; write errors → fallback; malformed files never trap.

## Test plan

Shared test support (new):
- `PaintDotMacTests/History/Spill/Support/InMemorySpillStore.swift`: a `HistorySpillStoring` keeping encoded `Data` per step (through the real `HistorySpillFileFormat`), with switches `failWrites: HistorySpillError?`, `failReads: HistorySpillError?`, `deleteOnRead: Set<HistoryStep.ID>` (simulates a missing file), `corruptByte(stepID:at:)`, and counters `writes`, `reads`, `removed`.
- `PaintDotMacTests/History/Spill/Support/SpillFixtures.swift`: builders for every item kind on a 600×520 two-layer image (0008's `SyntheticEdits`/`ReferenceCanvas` reused), seeded noise tiles (`SeededRandom`), and `assertStatesIdentical(_:_:)` (sizes, layer ids/names/visibility/opacity/blend modes, every tile's bytes, `activeLayerIndex`, selection `==`, floating pixels `==`).
- Temp directories under `FileManager.default.temporaryDirectory/PaintDotMacTests-<uuid>`, removed in teardown.

**Unit tests**
- `PaintDotMacTests/History/Spill/HistorySpillFileFormatTests.swift`
  - `roundTripsMixedTiles`: tiles [opaque white, transparent zero, seeded noise, half-alpha gradient with RGB under alpha 0] → `decode(encode)` equals byte for byte, order preserved.
  - `headerLayout`: encode 2 tiles with stepID 7 → bytes 0–3 `50 44 4D 48`, version `01 00`, stepID `07 00 00 00 00 00 00 00`, tileCount `02 00 00 00`, dataOffset `32 + 40 = 72`.
  - `uniformTileIsLZ4`: a white tile → table encoding 1, storedLength < 4,096. `noiseTileIsRaw`: encoding 0, storedLength 262,144.
  - `crcIsOfUncompressedBytes`: table CRC == `CRC32.checksum` of the tile's raw bytes.
  - `emptyPayload`: 0 tiles → 32-byte file, decodes to `[]`.
  - Failure cases, each → `.corrupt` and no trap: `truncatedHeader` (every length 0…31), `wrongMagic`, `unknownVersion`, `stepIDMismatch`, `tileCountMismatch`, `tableOutOfBounds`, `dataOutOfBounds`, `unknownEncoding`, `rawLengthWrong`, `lz4Garbage`, `crcMismatch` (flip one data byte), `truncatedData` (cut the last byte).
  - `fuzzNeverTraps`: 500 seeded random mutations (byte flips, truncations) of a valid 3-tile file → decode either returns tiles equal to the originals (mutation in a reserved byte) or throws; never crashes.
- `PaintDotMacTests/History/Spill/SpillableHistoryItemTests.swift` (for each: payload, `rebuild(payload.tiles)` and `rebuild(freshCopies)` — copies made with `Tile(bytes:)` so storages differ — then apply/revert on the before/after states with `assertStatesIdentical`; same `name`/`icon`/`change`/`byteCost`/`isNoOp`; `retainedStorageKeys` disjoint from payload keys; `makeSpillPayload()` twice → same order and bytes)
  - `tileDiffRoundTrip`: diff over 4 tiles crossing (250,250) on layer 1 with one `before == nil` entry → payload count 7 (4 after + 3 before), rebuild equal.
  - `tileDiffSparseNilStaysNil`: reverting the rebuilt item makes `tile(at:)` nil again.
  - `dedupWithinPayload`: a hand-built diff whose two entries' `after` tiles share storage → payload count 3 (not 4); after `rebuild(freshCopies)`, the two rebuilt `after` tiles `sharesStorage` with each other.
  - `snapshotSpillsOnlyUnsharedTiles`: "Delete Layer" of a layer with 3 tiles (others shared) → payload exactly those 3 tiles; "Add New Layer" and "Duplicate Layer" → empty payload; a canvas-resize-style snapshot (2 old tiles + 4 new) → 6 tiles; after rebuild, the shared tiles in the rebuilt states still `sharesStorage` with the originals.
  - `snapshotKeepsSelectionAndActiveLayer`: before/after with different selections and active indices → restored exactly; residual cost = selection bytes (`byteCost − 6 × 262,144`).
  - `compositeRoundTrip`: 0020-style composite (TileDiff + Selection + FloatingPixels lift) → payload = diff tiles then floating tiles; the selection child is the same value after rebuild; apply/revert identical.
  - `floatingPixelsRoundTrip`: lift of a 300×300 selection at (200,200) → payload = source tiles + changed underlay tiles (count computed independently from the surfaces: `source.allocatedTileCoordinates.count` + coordinates whose underlay storage differs from `restore.layerSurface`), byte count × 262,144 == `byteCost` (0020's formula); finish step (`f → nil`) → empty payload.
  - `nonSpillableKinds`: `SelectionHistoryItem` and `LayerPropertiesHistoryItem` are not `SpillableHistoryItem` (`(item as Any) is any SpillableHistoryItem == false`).
- `PaintDotMacTests/History/Spill/HistorySpillStackTests.swift` (`HistoryStack(base:budgetBytes:spill: .enabled)`, `FakeHistoryItem` from 0008 extended in support with a spillable variant `FakeSpillableItem(cost:tiles:)` whose payload is `tiles` and residual is `cost − tiles × 262,144`; writes completed by the test calling `completeSpill` with records it builds; exact oracles from Scope item 7)
  - `defaultIsDisabled`: `HistoryStack(base: .openImage).spillState == .disabled`; 0008's `fakeCostSequence` scenario gives 0008's exact results.
  - `spillsOldestFirst`: budget 3 tiles' worth (786,432); commit A, B, C, D each with 1 tile (cost 262,144) → after D: `takeSpillEffects().writes.map(\.stepID) == [A]` (projected 4 × 263,168 = 1,052,672 > budget; spilling A gives 789,504 > 786,432 → also B) — exact expected list `[A, B]`; A and B `.writing`; `totalBytes` unchanged until completion; after `completeSpill` for both → `.spilled`, `totalBytes == 2 × 1,024 + 2 × 263,168`, `diskBytes == Σ fileBytes`.
  - `protectsCurrentAndNextRedo`: budget 0, 4 steps, undo twice (current 2) → writes for steps 1 and 4 only (3 = next redo, 2 = current), order `[4, 1]`? — distance from current: step 4 → 2, step 1 → 1 → expected `[4, 1]`.
  - `candidateOrderAfterUndo`: 6 steps, current 3, budget 0 → write order `[6, 1, 5]` (distances 3, 2, 2 → tie → lower index first: 1 before 5).
  - `accountingResidualBytes`: a spillable item with cost 600,000 and 2 tiles → spilled cost 600,000 − 524,288 = 75,712 + 1,024.
  - `zeroCostStepsNeverWrite`: budget 0 with an "Add New Layer"-like empty-payload item → no write for it; fold fallback folds it if over budget.
  - `noDoubleSpill`: two enforcement passes while A is `.writing` → A requested once; `setBudget` during the write → no second request.
  - `reloadedEvictsWithoutIO`: spilled A, `installReloaded`, move current away, enforce → A back to `.spilled(sameRecord)`, `writes` empty.
  - `undoRefusesSpilledStep`: current step 2 spilled artificially (current moved by jump after spill) → `undo` returns nil, state unchanged; after `installReloaded` → undo works.
  - `recordsNeededOrder`: 5 steps, 1–3 spilled, current 5 → `recordsNeeded(toReach: 0)` == records of [3, 2, 1]; from 0 to 5 after undo → [1, 2, 3]; out of range → `[]`.
  - `installRejectsWrongCount` → `.corrupt`.
  - `diskQuotaFoldsOldest`: budget 262,144 → disk budget 1,048,576; each step's estimate 32 + 20 + 262,144 = 262,196; commit 6 one-tile steps completing every write with `fileBytes = 262,196` → once a fifth write wouldn't fit, `steps[1]` is folded first: expected step names, `droppedStepIDs`, and `deletions` computed by hand in the test from the rule; `diskBytes ≤ 1,048,576` always.
  - `writeFailureFallsBackToFolding`: `completeSpill(… .failure(.io(28)))` → `spillState == .failed(.io(28))`, the step `.resident`, then enforcement folds per 0008 (same steps as 0008's rule on the same costs); later commits request no writes.
  - `discardDeletesRecords`: spilled + writing redo steps discarded by a commit → their records in `deletions`, writing IDs in `cancelledWrites`.
  - `completionForGoneStepDeletesFile`: fold A while writing, then complete A with success → record in `deletions`.
  - `dropUnreadableUndoDirection`: 5 steps, current 4, step 3 unreadable → steps [base, 4, 5], `currentIndex 1`, saved marker per 0008 rules (saved at 2 → nil; saved at 3 → base); `dropUnreadableRedoDirection`: current 2, step 4 unreadable → steps [base,1,2,3], `canRedo` (step 3).
  - `zeroBudget`: budget 0 → disk budget 0 → no writes; result identical to 0008's fold rule.
  - `resetSpillReenables`: after `.failed`, `resetSpill(.enabled)` → `.active`.
- `PaintDotMacTests/History/Spill/HistorySpillStoreTests.swift` (real files in a temp root)
  - `writeReadRoundTrip`: 3 tiles → file `<id>.pdmh` exists, `fileBytes` == file size, no `.partial` left, `read` equal bytes.
  - `missingFile` → `.missing`; `sizeMismatch` (append a byte) → `.corrupt`; `readAfterClose`/`writeAfterClose` → `.closed`.
  - `refusesBelowMinimumFree`: `availableCapacity` stub returns `minimumFreeBytes + 100` → write of 1 tile throws `.insufficientSpace`, no file; stub nil → write succeeds.
  - `writeErrorRemovesPartial`: make the directory read-only (`chmod 0555`) → `.io`, no files left (restore permissions in teardown).
  - `removeAndRemoveAll`, `closeDeletesDirectory` (directory gone, `close()` twice is fine).
  - `lockIsHeld`: while a store is open, opening its `.lock` and `flock(LOCK_EX|LOCK_NB)` fails with `EWOULDBLOCK`.
  - `purgeStaleRemovesUnlockedOld`: a directory with an unlocked `.lock` and modification date 2 min ago → deleted and returned. `purgeStaleRemovesWithoutLockFile`. `purgeKeepsLockedDirectory`: an open store's directory (backdated) → kept. `purgeKeepsRecent`: unlocked but 10 s old → kept. `purgeIgnoresFilesAndMissingRoot` → no throw.
  - `closeAllOpenStores`: two stores open → both directories gone.
- `PaintDotMacTests/History/Spill/HistorySpillWriterTests.swift`: `immediateRunsInline`; `backgroundCompletesOffMain` (completion thread ≠ main; `drain()` returns after all); `cancelBeforeStart` (blocked first write via a gated store; cancel the second → completion `.failure(.closed)`, store never wrote it); `inFlightBytesTracks` (rises on enqueue, back to 0 after drain); `waitUntilInFlightReturns` (gated store released from another thread → returns).
- `PaintDotMacTests/App/LaunchOptionsTests.swift` (extend): `historySpillDisabled` (`NO`/`false`/`0` → true; `YES` → false; absent → false), `historySpillRoot` (absolute path → URL; relative/missing value → nil), `historySpillFailReads`; none consumes `-UITestOpen`'s path.

**Round-trip and property tests** — `PaintDotMacTests/History/Spill/HistorySpillPropertyTests.swift`
- `randomSessionsMatchOracle` (150 seeds × 50 ops, printed seed): 0008's `randomSessionsMatchOracle` model (edits, undo, redo, jump) plus random snapshot ops (add/delete layer) and random budget changes (0…8 tiles' worth), run through an `UndoBridge` with `InMemorySpillStore` and `spillWriterMode: .immediate`. After every op: pixels match the oracle for the expected index; step names/count equal the model (no step ever dropped while the disk quota isn't reached — quota set large); `totalBytes − writingBytes ≤ budgetBytes` or no candidate remains; `diskBytes == Σ stored file sizes in the fake`; `undoManager.canUndo/canRedo` and action names mirror the stack.
- `randomFailuresStayConsistent` (100 seeds): same model with random injected write failures, missing files, and corrupt bytes; after each op (and one main-queue turn): stack invariants (base ID 0, `0 ≤ currentIndex < count`), manager mirror, state equals the oracle of the surviving current step, and no step with an unreadable record is reachable without the alert callback having fired.

**Integration tests** (hosted, `@MainActor`, real `HistorySpillStore` in a temp root) — `PaintDotMacTests/History/Spill/HistorySpillIntegrationTests.swift`
- `everyKindRoundTripsThroughDisk`: a 1000×700 "New Image" bridge with budget 0 (all spillable steps spill), immediate writer; script: Paintbrush-style `TileDiffHistoryItem`, `SelectionHistoryItem` "Rectangle Select", 0018-style composite "Erase Selection", Add New Layer (snapshot), a stroke on layer 1, 0025 "Layer Properties" (opacity 128), 0020 lift-and-move "Move Pixels" + "Finish Pixels", 0037 "Rotate 90° Clockwise" (snapshot with all tiles rewritten). After the script: the directory holds a `.pdmh` for every step with a non-empty payload except the protected ones. Undo all the way (each undo reads from disk) → state identical to the "New Image" oracle at every step (compare to snapshots recorded at commit time); redo all the way → identical to each recorded after-state; `activeLayerIndex` never changes on the non-structural steps (H-6).
- `loweringBudgetSpills`: through `PaintDocument` with a real store (and `settingsProvider` from 0046), 3 one-tile steps at 1 GiB, set `settings.undoBudgetBytes = 1_048_576` → step names unchanged (4 rows), at least step 1 `.spilled` after `writer.drain()` + one main-queue turn; three undos restore the original pixels.
- `commitDoesNotWaitForWriter`: background writer with a gated store blocked on its first write; 5 commits complete on the main actor immediately (each commit returns while the gate is closed; `history.steps.count` grows); release → all completions processed.
- `undoWhileWriting`: gate closed; undo into a `.writing` step → works with 0 reads; release → step `.reloaded`.
- `completionAfterDiscardDeletesFile`: gate closed, undo, commit (discards the writing step), release → no file for that step remains.
- `completionAfterCloseIgnored`: gate closed, `shutDownSpill()`, release → no crash, directory gone, no history change.
- `resetDeletesFiles`: spilled steps, `reset(state:base:)` → directory empty (only `.lock`), `spillState == .active`.
- `missingFileOnUndo`: spill steps 1–3 of 5, delete `2.pdmh`, undo ×3 from 5 → third undo hits step 2: state stays equal to the after-step-2 oracle, steps after one main-queue turn = [base, 3, 4, 5] with the base standing for after-step-2, `onHistoryLoss == .unreadableSteps(count: 2)` once, `history.canUndo == false`, `undoManager.canUndo == false`.
- `corruptFileOnRedo`: undo to base (reloading), evict by budget, corrupt byte in `3.pdmh`, redo ×3 → third redo fails: steps [base, 1, 2], state = after step 2, `canRedo == false` in both stack and manager, alert callback once.
- `unreadableKeepsManagerInSync`: after each failure case above, `undoActionName`/`redoActionName` match `history.undoStep?.name`/`redoStep?.name`.
- `writeErrorFallsBack`: store with `failWrites: .io(28)` → after the first spill attempt `spillState == .failed`, later commits fold per 0008 (exact names), no alert, no files.
- `largeJumpLoadsAsync`: `synchronousReloadLimitBytes` set to 0 for the test; 6 spilled steps; `jump(to: 0)` returns with `isBusy == true` and `historyLoadProgress != nil`; await `pendingHistoryLoad` → `isBusy == false`, `currentIndex == 0`, state equals the oracle, `historyRevision` +1 exactly, `onStateChange` once.
- `cancelLargeJump`: same, `cancelHistoryLoad()` before completion → `currentIndex` unchanged, state unchanged, `isBusy == false`.
- `spillDoesNotTouchEditedState`: mark saved at step 2, spill it, undo/redo across it → `isDocumentEdited` toggles exactly as without spill; `savedStepID` unchanged by spilling.
- `autosaveWhileSpilled`: with 0047's `AutosaveDocumentTests` setup, spill steps then autosave → the `.ora` decodes to the live image exactly; history untouched.
- `closeRemovesDirectory`: `PaintDocument.close()` → the store's directory doesn't exist.

- `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift` / `KeyboardNavigationPlanTests.swift` (extend 0049): `historyLossAlertEntries` (the two entries of item 14, surface `.historyLossAlert`); `historyLossAlertPlan` (initial/default `historyLossAlert.ok`, tabOrder `[historyLossAlert.ok]`, cancel nil).

**UI tests** — `PaintDotMacUITests/HistorySpillUITests.swift` (every launch passes `-UITestHistorySpillRoot <tmp>/spill`; the runner reads that directory, which works because the app is not sandboxed)
- `testUndoThroughSpilledSteps`: 64×64 opaque white PNG, launch with `-settings.undoBudgetBytes 1048576` (argument domain). Four short Paintbrush drags at different rows (each touches tile (0,0), 525,312 bytes). History list shows 5 rows (`historyRow.0`…`historyRow.4`). Within 5 s, `<tmp>/spill/*/` contains at least one `.pdmh`. Press ⌘Z four times → Edit > Undo disabled, still 5 rows; Save As (0005 `saveThroughPanel`) to `undone.png` → every decoded pixel is (255,255,255,255). ⇧⌘Z four times, Save As `redone.png` → pixels along the four drag rows are black (sampled at the drag midpoints), the rest white.
- `testLoweringUndoLimitKeepsStepsUndoable`: 0046's scenario with `-UITestUndoLimitPreset 1048576`: three strokes; choose "1 MB" in Settings → History still shows 4 rows; ⌘Z three times works (Undo enabled for each, disabled after the third).
- `testCloseDeletesSpillDirectory`: as the first test until a `.pdmh` exists; ⌘W, "Don't Save" → within 2 s `<tmp>/spill` has no subdirectory.
- `testStaleDirectoryPurgedAtLaunch`: before launch, create `<tmp>/spill/<uuid>/1.pdmh` (4 bytes) and `.lock`, backdate the directory 2 minutes → launch with a fixture → after the window appears, the directory is gone.
- `testSettingsFootnoteMentionsDisk`: open Settings (⌘,) → the window contains a static text equal to "When the limit is reached, older history steps are moved to disk." and none containing "oldest history steps are removed".
- `testUnreadableStepShowsAlert`: launch with `-settings.undoBudgetBytes 1048576` and `-UITestHistorySpillFailReads YES`; four strokes; ⌘Z until a sheet `historyLossAlert` appears (at most 4 presses) → its text contains "couldn't be read" and `historyLossAlert.ok` has label "OK"; click it → the History list has fewer than 5 rows, Edit > Undo is disabled, the app is still running.

**Performance** — `PaintDotMacBenchmarks/HistorySpillBenchmarks.swift` (0048 harness; rows added to `BenchmarkCatalog`, informational with gates, not in `requiredIDs` because the PRD has no H-4 target)
| ID | Benchmark | Value | Target | Gate |
|---|---|---|---|---|
| `H-4.spill.write.full4k.noise` | `testSpillWriteFullLayerNoise` | ms to encode + write a 4000×3000 full-layer step (384 incompressible tiles) on the writer | — | 1,000 |
| `H-4.spill.write.full4k.flat` | `testSpillWriteFullLayerFlat` | same with uniform tiles | — | 300 |
| `H-4.reload.undo.full4k.noise` | `testUndoReloadFullLayerNoise` | ms for one ⌘Z-equivalent `undo()` that reads that step | 150 | 450 |
| `H-4.commit.withSpill` | `testCommitWhileSpilling` | ms main-actor time of a full-layer commit that triggers a spill | — | 150 (0008's commit gate) |

**Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.

**Manual verification**
1. Settings → Undo memory limit 256 MB. Open a 6000×4000 photo, apply Invert Colors 10 times (each ≈ 192 MiB accounted). Activity Monitor: memory stays near the image + 256 MB; Finder `~/Library/Caches/PaintDotMac/History/<uuid>/` fills with `.pdmh` files; all 10 History rows remain; ⌘Z ten times restores the original with no visible stall longer than a moment per step.
2. Same document: click the "Open Image" row → after 0.5 s a "Loading History" progress sheet appears; Escape cancels and nothing changes; click again and let it finish → the original image.
3. Close the document → its `History/<uuid>` folder disappears. Quit the app with a spilled document open → the folder disappears.
4. With a spilled document open, `kill -9` the app; relaunch → 0047 restores the document; the old `History/<uuid>` folder is deleted (check after ~1 min if it was created within the last 60 s).
5. Painting a 300 px brush on a 6000×4000 layer while spills run in the background stays smooth (NF-1).

## Open questions
1. **Disk quota default and whether Settings exposes it.** The PRD gives no disk limit. *Recommended (applied):* per document `4 × undo memory limit` (4 GiB at the default), plus never writing when it would leave less than 2 GiB free on the startup volume; no Settings control (the existing "Undo memory limit" drives both).
2. **Settings footnote under "Undo memory limit:".** 0046's text ("the oldest history steps are removed") becomes inaccurate. *Recommended (applied):* "When the limit is reached, older history steps are moved to disk."
3. **What the user sees when a spilled step can't be read** (file deleted by a cache cleaner, disk error). *Recommended (applied):* a warning sheet "Some history steps couldn't be read and were removed." / "The image wasn't changed. You can still undo the remaining steps." / OK; write failures (disk full) silently fall back to dropping, like H-5 today.
4. **Progress sheet title for long History-panel jumps.** *Recommended (applied):* "Loading History", shown after 0.5 s with Cancel, reusing 0031's progress sheet.
5. **Scratch folder name.** PRD H-4 says "the app's caches directory". *Recommended (applied):* `~/Library/Caches/PaintDotMac/History/<document UUID>/` (product name, as in the planning brief), rather than the bundle-ID folder `~/Library/Caches/com.thera-engineering.paintdotmac/`.

## Out of scope
- Spilling selection masks and paths (S-4), and persisting history across launches or into `.ora`/autosave files (PRD has no requirement; 0047 recovers images only).
- Background prefetch of the next undo step (single-step reloads are synchronous by design; revisit if `H-4.reload.undo.*` misses its target).
- Cross-step tile deduplication on disk.
- Any change to the in-memory budget default, the tile size, or the pixel format (NF-4, NF-9).
- The H-5 fallback's own rules (unchanged from 0008) and 0048's existing NF-4 footprint rows.
