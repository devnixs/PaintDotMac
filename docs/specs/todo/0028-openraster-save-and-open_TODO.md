# 0028 — Save and open layered images as OpenRaster (.ora), and make it the default format for new documents

> Source: PRD.md §5.11 F-1 (native layered format: OpenRaster), FMT-E (P0, OpenRaster details), §5.11 "Saving" (new documents default to `.ora`; ⌘S keeps the document's format), FMT-B (saving always embeds sRGB; input converted to sRGB), APP-5 (per-document DPI stored in `.ora` `xres`/`yres`), APP-10 (limits), §4 *Image I/O* (own ZIP reader/writer in `Core`, DEFLATE through Apple `Compression`, own CRC-32), §8 M3 exit ("an `.ora` round-trips through Krita"), §12 D-6, D-7, D-8, D-18, D-19, D-32. AGENTS.md *Testing expectations* ("An OpenRaster round-trip test must preserve layer names, order, opacity, visibility, and blend mode"; no binary fixtures over 1 MB). External references: OpenRaster 0.0.6, https://www.openraster.org/baseline/file-layout-spec.html (archive layout) and https://www.openraster.org/baseline/layer-stack-spec.html (`stack.xml`); PKWARE APPNOTE.TXT 6.3.x §4.3–4.4 (ZIP records); Apple *Compression* `COMPRESSION_ZLIB`; Krita's macOS `Info.plist.template` (https://invent.kde.org/graphics/krita/-/raw/master/krita/Info.plist.template) for the UTI.
> Milestone: M3 (Layers)
> Depends on: 0027-blend-modes-group-2 (all 14 L-3 `BlendMode` cases exist), and through it 0024 (multi-layer documents, `LayerNaming`, Layers menu), 0025 (Layers panel accessibility), 0012 (`CPUCompositor.flattened`), 0008 (`UndoBridge`, saved marker), 0005 (`FileFormat`, `ImageEncoder`, `SaveAction`, save glue), 0002 (`ImageDecoder`, `LayeredImage`, `Layer`, `TiledSurface`, `ImageLimits`).

## Context

Today (after 0027) a document can hold many layers with names, visibility, opacity 0–255, and 14 blend modes, but it can only be written as PNG, and 0024 made a multi-layer PNG save throw `ImageCodecError.layeredImageNeedsFlatten` ("This image has more than one layer.", recovery suggestion pointing at OpenRaster). So layered work can't be saved at all. PRD F-1 makes OpenRaster the native layered format; FMT-E fixes the details; PRD §5.11 "Saving" says new documents default to `.ora`.

Existing code this spec builds on (all specified, not yet on disk; names are binding):

- **0002** `Core/Model/Layer.swift` (`struct Layer { let id: UUID; var name; var isVisible; var opacity: UInt8; var blendMode: BlendMode; var surface: TiledSurface }`), `Core/Model/LayeredImage.swift` (`size`, `dpi: Double`, `layers` **index 0 = bottom**, `activeLayerIndex`, `isConsistent`, `isValidDPI`, `defaultDPI = 96`, `defaultLayerName = "Background"`), `Core/Model/TiledSurface.swift` (`init(size:)`, `init(size:rgba8:bytesPerRow:)`, `readPixels(in:)`, `writePixels(_:to:)` clipped to bounds, `allocatedTileCount`, `makeCGImage()`), `Core/Model/ImageLimits.swift` (`validate(width:height:)`, `memoryCapBytes`, `ImageLimitError`), `Core/IO/ImageDecoder.swift` (`decode(_:limits:) -> DecodedImage` sniffs content, converts to straight sRGB RGBA8, enforces limits, rejects truncated PNGs), `Core/IO/ImageCodecError.swift`.
- **0005** `Core/IO/FileFormat.swift` (`enum FileFormat: String, CaseIterable { case png, jpeg }`, `utType`, `typeIdentifier`, `preferredFilenameExtension`, `displayName`, `canRead`, `canWrite`, `init?(typeIdentifier:)`, `init?(fileExtension:)`, `writableFormats`, `defaultNewDocumentFormat { .png }` ("0028 → .openRaster"), `saveAction(for:)`, `suggestedFilename(original:untitledName:format:)`; `enum SaveAction`), `Core/IO/ImageEncoder.swift` (`encode(_ surface:size:dpi:as:)` writes straight RGBA8 PNG with sRGB profile + pHYs; `encode(_ image: LayeredImage, as:)`), `Document/PaintDocument.swift` (`writableTypes(for:)`, `fileNameExtension(forType:saveOperation:)`, `data(ofType:)`, `saveDocument(_:)`, `prepareSavePanel(_:)` with a hard-coded `format: .png` suggestion and `allowedContentTypes`), `PaintDocumentController.newDocument(_:)` (`makeUntitledDocument(ofType: FileFormat.defaultNewDocumentFormat.typeIdentifier)`), `PaintDotMacUITests/Support/UITestApp.swift` (`saveThroughPanel(directory:name:)`).
- **0001** `project.yml` Info.plist `CFBundleDocumentTypes` (PNG, JPEG; no `UTExportedTypeDeclarations`), `PaintDocument.readableTypes` (`["public.png", "public.jpeg"]`), test `SmokeTests.documentTypesMapPNGAndJPEGToPaintDocument` (`PaintDotMacTests/SmokeTests.swift`).
- **0008** `PaintDocument.read(from:ofType:)` → `undoBridge.reset(state: DocumentState(image:), base: .openImage)`; save bookkeeping marks the saved step for `.saveOperation`/`.saveAsOperation`; `PaintDocument.save` commits the active tool's pending edit first.
- **0012** `Core/Rendering/CPUCompositor.swift`: `CPUCompositor().flattened(_ image: LayeredImage) -> TiledSurface` (visible layers, opacity, blend ops, composited over transparent; extended to all modes by 0024/0026/0027).
- **0024** `ImageCodecError.layeredImageNeedsFlatten`; Layers menu "Add New Layer" ⇧⌘N (`menu.layers.addNewLayer`), new layers named "Layer N".
- **0025** Layers panel: `layersList`, rows `layerRow.<index>` (index = layer index, **0 = bottom**; label = layer name; value `"active"`/`"inactive"`), checkboxes `layerVisibility.<index>` (value 1/0), Layer Properties sheet `layerProperties` with `layerProperties.name`, `layerProperties.blendMode`, opacity field.
- **0026/0027** `BlendMode` cases and frozen raw values in L-3 order: `normal, multiply, additive, colorBurn, colorDodge, reflect, glow, overlay, difference, negation, lighten, darken, screen, xor`.

### OpenRaster facts this spec relies on (from openraster.org, version 0.0.6)

- Archive: a ZIP. `mimetype` must be the **first** entry, **stored** (no compression), and contain exactly `image/openraster` with no newline. `stack.xml` (UTF-8) is required. `mergedimage.png` (8- or 16-bit PNG, the final composite, no decoration) is required. `Thumbnails/thumbnail.png` is required: non-interlaced 8-bit PNG, **at most 256×256**, as large as possible without upscaling and keeping the aspect ratio; it is not referenced from `stack.xml`. Paths in `stack.xml` are full paths from the archive root (for example `data/layer2.png`).
- `stack.xml`: root `<image>` with required `w`, `h` (positive integers), `version` (SemVer string), optional `xres`, `yres` (`xsd:int` ≥ 1, pixels per inch; "if either is specified, the other must also be"; default 72 when unspecified). The image's single child `<stack>` is the root stack; its children are `<stack>` (groups), `<layer>`, or `<text>`, and **the first child is the uppermost**. `<layer>` requires `src`, and has optional `name`, `x`, `y` (signed integers, default 0), `opacity` (float 0.0–1.0, default 1.0), `visibility` (`visible` default, or `hidden`), `composite-op` (default `svg:src-over`). Content may extend beyond `(0, 0, w, h)`; display and export crop to it. Non-root stacks have `name`, `opacity`, `visibility`, `composite-op`, `isolation` (`isolate` default, or `auto`). The spec doesn't say what readers do with unknown `composite-op` values.
- Standard composite ops: `svg:src-over`, `svg:multiply`, `svg:screen`, `svg:overlay`, `svg:darken`, `svg:lighten`, `svg:color-dodge`, `svg:color-burn`, `svg:hard-light`, `svg:soft-light`, `svg:difference`, `svg:color`, `svg:luminosity`, `svg:hue`, `svg:saturation`, `svg:plus`, `svg:dst-in`, `svg:dst-out`, `svg:src-atop`, `svg:dst-atop`.
- **UTI:** OpenRaster defines no UTI. Krita (the M3 exit-criterion app) exports **`org.openraster.ora`** in its macOS Info.plist (`UTTypeReferenceURL` https://www.openraster.org/, extension `ora`, MIME `image/openraster`). **Decision:** this spec uses the same identifier so both apps agree on the type (the planning brief's `org.openraster.image` is not used).

### Apple Compression facts

`COMPRESSION_ZLIB` in Apple's *Compression* framework encodes and decodes **raw DEFLATE (RFC 1951) with no zlib header (RFC 1950) and no Adler-32 trailer**, which is exactly ZIP method 8. The encoder is zlib at level 5. Use the streaming API (`compression_stream_init` / `compression_stream_process` / `compression_stream_destroy`, operation `COMPRESSION_STREAM_ENCODE` or `COMPRESSION_STREAM_DECODE`, flag `COMPRESSION_STREAM_FINALIZE` on the last input). Don't use `compression_decode_buffer` for reading, because it silently truncates output that doesn't fit, so it can't detect an entry that inflates past its declared size (zip bomb). Don't use `NSData.decompressed(using:)`, which has no output cap.

## User story

As a PaintDotMac user, I press ⌘N, add layers, and press ⌘S: the save sheet suggests "Untitled.ora", and the file keeps every layer with its name, order, visibility, opacity, blend mode, and the image's DPI. I can open that file again in PaintDotMac, or in Krita or GIMP, and open `.ora` files made by Krita in PaintDotMac. Damaged, encrypted, or ZIP64 archives show a clear alert instead of crashing.

## Scope & changes

### Core: CRC-32 (pure, unit-tested)

- **`PaintDotMac/Core/IO/CRC32.swift`** (new). Imports only Foundation. It must compile on its own (the UI test target compiles it too).
  ```swift
  struct CRC32: Sendable {
      private(set) var value: UInt32            // the finalized CRC of everything fed so far
      init()
      mutating func update(_ bytes: UnsafeRawBufferPointer)
      mutating func update(_ data: Data)
      static func checksum(_ data: Data) -> UInt32
      static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32
  }
  ```
  IEEE 802.3 / ZIP CRC-32: reflected polynomial `0xEDB88320`, register initialized to `0xFFFFFFFF`, final XOR `0xFFFFFFFF`. Store the running register internally and expose the finalized `value`, so `update` can be called any number of times with the same result as one call. Implement **slicing-by-8** (eight 256-entry `UInt32` tables, built once in a `static let`) over `UnsafeRawBufferPointer`, with a byte-at-a-time tail. That keeps Debug builds fast enough for the performance test (no per-byte `Data` subscripting).

### Core: ZIP reader (pure, unit-tested)

- **`PaintDotMac/Core/IO/ZipReader.swift`** (new). Imports Foundation, Compression, and uses `CRC32`.
  ```swift
  enum ZipReadError: Error, Equatable, Sendable {
      case notAnArchive                              // no end-of-central-directory record
      case corrupt                                   // any structural inconsistency, bad bounds, bad deflate stream, size mismatch
      case multiDisk
      case zip64
      case encrypted(entry: String)
      case unsupportedCompressionMethod(entry: String, method: UInt16)
      case unsafeEntryName(String)
      case duplicateEntryName(String)
      case entryTooLarge(entry: String, uncompressedSize: Int, limit: Int)
      case crcMismatch(entry: String)
      case entryNotFound(String)
  }

  struct ZipEntry: Equatable, Sendable {
      let name: String
      let flags: UInt16
      let method: UInt16
      let crc32: UInt32
      let compressedSize: Int
      let uncompressedSize: Int
      let localHeaderOffset: Int
      var isEncrypted: Bool { flags & 0x0001 != 0 }
      var hasDataDescriptor: Bool { flags & 0x0008 != 0 }
      var isDirectory: Bool { name.hasSuffix("/") }
  }

  struct ZipReaderLimits: Equatable, Sendable {
      var maxEntryUncompressedSize: Int
      /// min(limits.memoryCapBytes, 0xFFFF_FFFE)
      static func forImage(_ limits: ImageLimits) -> ZipReaderLimits
  }

  struct ZipReader: Sendable {
      init(data: Data, limits: ZipReaderLimits) throws(ZipReadError)
      let entries: [ZipEntry]                        // central-directory order
      func entry(named name: String) -> ZipEntry?    // exact, case-sensitive match
      func contents(of entry: ZipEntry) throws(ZipReadError) -> Data
      func contents(named name: String) throws(ZipReadError) -> Data   // .entryNotFound(name) when missing
  }
  ```
  All multi-byte fields are little-endian. Every offset and length is bounds-checked with overflow-safe `Int` arithmetic before it is read. No input byte sequence may trap, assert, or log.

  **`init` (directory parse), in this order:**
  1. `data.count < 22` → `.notAnArchive`.
  2. Find the end-of-central-directory (EOCD) record: scan backwards from `data.count − 22` down to `max(0, data.count − 22 − 65_535)` for signature `50 4B 05 06`. Take the first match (from the end) whose comment length `c` satisfies `offset + 22 + c <= data.count`. None → `.notAnArchive`.
  3. A ZIP64 EOCD locator (signature `50 4B 06 07`) at `eocdOffset − 20` → `.zip64`.
  4. Parse the EOCD: disk number, disk with the central directory, entries on this disk, total entries, central-directory size, central-directory offset. Any of entries/total == `0xFFFF`, or size/offset == `0xFFFF_FFFF` → `.zip64`. Disk numbers ≠ 0, or entries on this disk ≠ total entries → `.multiDisk`. `cdOffset + cdSize > eocdOffset` → `.corrupt`.
  5. Parse exactly `total` central-directory headers starting at `cdOffset`, each with signature `50 4B 01 02` (else `.corrupt`), fixed part 46 bytes: version made by, version needed, flags, method, time, date, CRC-32, compressed size, uncompressed size, name length `n`, extra length `m`, comment length `k`, disk start, internal attributes, external attributes, local header offset, then name, extra, comment. Each record must end inside the central directory (else `.corrupt`). Any extra-field block with header ID `0x0001` (ZIP64 extended information), or a size/offset field equal to `0xFFFF_FFFF` → `.zip64`. Flag bit 6 (strong encryption) is treated like bit 0 (encrypted, reported when the entry is read).
  6. **Names.** Decode as strict UTF-8. If that fails and flag bit 11 is clear, decode as ISO Latin-1 (an approximation of CP437, sufficient because OpenRaster names are ASCII). Then reject the **whole archive** with `.unsafeEntryName(name)` when the name is empty, contains NUL (U+0000) or a backslash, starts with `/`, starts with a drive prefix (`^[A-Za-z]:`), or has a path component equal to `..`. A name that appears twice → `.duplicateEntryName(name)`. Directory entries (ending in `/`) are kept in `entries` but never read.
  7. Store each entry's fields as `Int`/`UInt` values. Method, encryption, and size limits are **not** checked here, so an unsupported entry that the caller never reads doesn't block the archive.

  **`contents(of:)`, in this order:**
  1. `isEncrypted` (bit 0 or bit 6) → `.encrypted(entry:)`.
  2. Method not 0 (stored) or 8 (deflate) → `.unsupportedCompressionMethod(entry:method:)`.
  3. `uncompressedSize > limits.maxEntryUncompressedSize` → `.entryTooLarge(entry:uncompressedSize:limit:)`, **before** any allocation.
  4. Local header at `localHeaderOffset`: signature `50 4B 03 04` (else `.corrupt`); read its flags, name length `n'`, extra length `m'`. The local name bytes must equal the central name bytes (else `.corrupt`). Local flag bit 0 set → `.encrypted`. Data starts at `localHeaderOffset + 30 + n' + m'` and must satisfy `dataStart + compressedSize <= cdOffset` (else `.corrupt`). **The central directory's CRC and sizes are authoritative.** The local header's CRC/size fields are ignored, which is what makes entries written with a **data descriptor** (flag bit 3: local CRC/sizes are zero and a descriptor, optionally with signature `50 4B 07 08`, follows the data) readable without parsing the descriptor.
  5. Method 0: `compressedSize` must equal `uncompressedSize` (else `.corrupt`); copy the bytes.
  6. Method 8: inflate with `compression_stream` (`COMPRESSION_STREAM_DECODE`, `COMPRESSION_ZLIB`) into a buffer of exactly `uncompressedSize` bytes, plus a 1-byte overflow probe: feed all `compressedSize` input bytes with `COMPRESSION_STREAM_FINALIZE`. Producing more than `uncompressedSize` bytes, `COMPRESSION_STATUS_ERROR`, or not reaching `COMPRESSION_STATUS_END` with exactly `uncompressedSize` bytes produced → `.corrupt`. (A zero-length deflated entry is valid when the stream is a valid empty block.) Always destroy the stream (`defer`).
  7. `CRC32.checksum(result) != crc32` → `.crcMismatch(entry:)`.

### Core: ZIP writer (pure, unit-tested)

- **`PaintDotMac/Core/IO/ZipWriter.swift`** (new). Imports Foundation and Compression and uses only `CRC32`, so the UI test target can compile it alongside `CRC32.swift` (see *UI test support*).
  ```swift
  enum ZipCompressionMethod: UInt16, Sendable { case stored = 0, deflated = 8 }
  enum ZipWriteError: Error, Equatable, Sendable {
      case invalidEntryName(String)       // same rules as the reader's unsafe-name check
      case duplicateEntryName(String)
      case archiveTooLarge                // a size, offset, or count would need ZIP64
      case compressionFailed
  }
  struct ZipWriter: Sendable {
      init(modificationDate: Date, timeZone: TimeZone = .current)
      mutating func addEntry(named name: String, data: Data, method: ZipCompressionMethod) throws(ZipWriteError)
      func finish() throws(ZipWriteError) -> Data
      static func dosDateTime(for date: Date, timeZone: TimeZone) -> (date: UInt16, time: UInt16)
      static func deflate(_ data: Data) throws(ZipWriteError) -> Data   // raw DEFLATE via COMPRESSION_ZLIB stream
  }
  ```
  - The archive is built in memory, and entries are written in the order they were added. The writer **never** writes data descriptors, ZIP64 records, encryption, extra fields, or comments. It honors the requested method exactly. It doesn't fall back to stored when deflate grows the data.
  - **Local file header** (30 bytes + name + data): `50 4B 03 04`; version needed `10` (stored) or `20` (deflated); flags `0x0000`, or `0x0800` (UTF-8) when the name has any non-ASCII byte; method; DOS time; DOS date; CRC-32 of the uncompressed data; compressed size; uncompressed size; name length; extra length `0`; name bytes (UTF-8); data.
  - **Central directory header** (46 bytes + name): `50 4B 01 02`; version made by `0x031E` (Unix, 3.0); version needed, flags, method, time, date, CRC, sizes, and name length as in the local header; extra `0`; comment `0`; disk start `0`; internal attributes `0`; external attributes `0x81A4_0000` (Unix regular file 0644 in the high 16 bits); local header offset; name.
  - **EOCD** (22 bytes): `50 4B 05 06`; disk `0`; central-directory disk `0`; entries on this disk = total = count; central-directory size; central-directory offset; comment length `0`.
  - `archiveTooLarge` when any compressed/uncompressed size or offset (including the central-directory offset and size) would exceed `0xFFFF_FFFE`, or the entry count would exceed `0xFFFE`. Detect sizes in `addEntry` and offsets in `addEntry`/`finish`, before writing.
  - **DOS date/time** in `timeZone`: `time = hour << 11 | minute << 5 | second / 2`; `date = (year − 1980) << 9 | month << 5 | day`. Dates before 1980-01-01 00:00:00 clamp to that value (`date = 0x0021`, `time = 0`); dates after 2107-12-31 23:59:58 clamp to that value.
  - `deflate`: one `compression_stream` (`COMPRESSION_STREAM_ENCODE`, `COMPRESSION_ZLIB`) with `FINALIZE`, output grown in 64 KiB chunks. Any `COMPRESSION_STATUS_ERROR` → `.compressionFailed`. Empty input still produces a valid (non-empty) raw DEFLATE stream from the finalized encoder.

### Core: blend-mode mapping (pure, unit-tested)

- **`PaintDotMac/Core/IO/OpenRasterBlendMap.swift`** (new):
  ```swift
  enum OpenRasterBlendMap {
      static func compositeOp(for mode: BlendMode) -> String          // exhaustive switch, no default
      static func blendMode(forCompositeOp op: String?) -> BlendMode  // nil, empty, or unknown → .normal
  }
  ```
  Exact table (PRD FMT-E). Reading matches the string exactly (case-sensitive, after trimming ASCII whitespace):

  | `BlendMode` | `composite-op` |
  |---|---|
  | `.normal` | `svg:src-over` |
  | `.multiply` | `svg:multiply` |
  | `.additive` | `svg:plus` |
  | `.colorBurn` | `svg:color-burn` |
  | `.colorDodge` | `svg:color-dodge` |
  | `.reflect` | `paintdotmac:reflect` |
  | `.glow` | `paintdotmac:glow` |
  | `.overlay` | `svg:overlay` |
  | `.difference` | `svg:difference` |
  | `.negation` | `paintdotmac:negation` |
  | `.lighten` | `svg:lighten` |
  | `.darken` | `svg:darken` |
  | `.screen` | `svg:screen` |
  | `.xor` | `paintdotmac:xor` |

  Every other value (for example `svg:hard-light`, `svg:dst-in`, `krita:dissolve`, `SVG:MULTIPLY`) reads as `.normal`. The exhaustive `switch` makes 0059 (L-4) fail to compile until it adds `svg:hard-light`, `svg:soft-light`, `svg:color`, `svg:luminosity`, `svg:hue`, and `svg:saturation`.

### Core: OpenRaster codec (pure, unit-tested)

- **`PaintDotMac/Core/IO/OpenRasterCodec.swift`** (new). Imports Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers (no AppKit).
  ```swift
  struct OpenRasterLayerRecord: Equatable, Sendable {
      var name: String?            // nil when the attribute is missing
      var src: String
      var x: Int
      var y: Int
      var opacity: Double          // effective (product with the ancestor groups), clamped 0...1
      var isVisible: Bool          // effective (false if any ancestor group is hidden)
      var compositeOp: String?
      var isSelected: Bool
  }
  struct OpenRasterStack: Equatable, Sendable {
      var width: Int
      var height: Int
      var dpi: Double              // resolved, always LayeredImage.isValidDPI
      var layers: [OpenRasterLayerRecord]   // TOP-FIRST, as in the file
  }
  enum OpenRasterCodec {
      static let mimeType = "image/openraster"
      static let specVersion = "0.0.6"
      static let maxStackXMLBytes = 8 << 20
      static let maxNestingDepth = 64
      static let thumbnailMaxSide = 256

      static func encode(_ image: LayeredImage, modificationDate: Date = Date(),
                         processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                         memoryCap: Int = ImageLimits.standard.memoryCapBytes) throws(ImageCodecError) -> Data
      static func decode(_ data: Data, limits: ImageLimits = .standard,
                         processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) throws(ImageCodecError) -> LayeredImage
      static func isZipArchive(_ data: Data) -> Bool        // first 4 bytes == 50 4B 03 04

      static func stackXML(for image: LayeredImage) -> String
      static func parseStackXML(_ data: Data) throws(ImageCodecError) -> OpenRasterStack
      static func layerPath(forIndex index: Int) -> String  // "data/layer\(index).png", index bottom-first
      static func opacityString(_ opacity: UInt8) -> String
      static func opacity(fromUnitValue f: Double) -> UInt8
      static func parseOpacity(_ attribute: String?) -> Double
      static func escapeXMLAttribute(_ s: String) -> String
      static func thumbnailSize(for size: PixelSize) -> PixelSize
      static func concurrency(canvasBytes: Int, memoryCap: Int, processorCount: Int) -> Int
      static func place(_ surface: TiledSurface, at origin: PixelPoint, onCanvas canvas: PixelSize) -> TiledSurface
  }
  ```

  **Writing (`encode`)**
  1. `image.isConsistent` false → `.encodingFailed`.
  2. **Layer PNGs.** Each layer `i` (bottom-first index) is encoded **at full canvas size, at offset (0, 0)** with `ImageEncoder.encode(layer.surface, size: image.size, dpi: image.dpi, as: .png)`. That gives straight RGBA8 with an sRGB profile and pHYs (FMT-B), and preserves the color under alpha 0. The PNG is stored at `layerPath(forIndex: i)`. Hidden and zero-opacity layers are written like any other layer (their pixels are kept).
  3. **`mergedimage.png`:** `ImageEncoder.encode(CPUCompositor().flattened(image), size:, dpi:, as: .png)`. The composite goes over transparent, with no background, hidden layers excluded, and opacity and blend modes applied by 0012/0024–0027's compositor.
  4. **`Thumbnails/thumbnail.png`:** `thumbnailSize(for: image.size)`. If that equals `image.size`, reuse the `mergedimage.png` bytes. Otherwise make the merged surface's `makeCGImage()`, draw it into a `CGContext` of the thumbnail size (8 bpc, sRGB, `premultipliedLast`, `interpolationQuality = .high`), and write a non-interlaced PNG through `CGImageDestination` (`UTType.png`) from the context's image. The thumbnail is lossy (premultiplied scaling), and only Krita/Finder previews use it. Any failure → `.encodingFailed`.
  5. **`thumbnailSize`:** if both sides ≤ 256, return the size unchanged. Otherwise `s = 256 / max(w, h)`, and each side is `max(1, Int((Double(side) × s).rounded()))`, with the longer side exactly 256. Examples: 800×600 → 256×192; 600×800 → 192×256; 3840×2160 → 256×144; 65,535×1 → 256×1; 256×256 → 256×256; 1×1 → 1×1.
  6. **Concurrency:** encode the layer PNGs and the merged PNG in parallel with `DispatchQueue.concurrentPerform`, with at most `concurrency(…)` encodes in flight (a `DispatchSemaphore`). Results go into a preallocated array guarded by an `NSLock`, so there is no `Synchronization` import in Core. `concurrency(canvasBytes:memoryCap:processorCount:)` = `max(1, min(processorCount, memoryCap / max(canvasBytes, 1)))`. This bounds the contiguous per-encode buffers (`canvasBytes` = w × h × 4 each) to about the memory cap (APP-10, D-32). Examples: (33_177_600, 4 << 30, 10) → 10; (4 << 30, 4 << 30, 10) → 1; (0, x, 8) → 8; (x, 0, 8) → 1. The first error wins and is rethrown after the loop.
  7. **`stack.xml`** is `stackXML(for:)` as UTF-8, written **exactly** as follows (lines joined with `"\n"`, a trailing `"\n"`, a one-space indent for `<stack>`, a two-space indent for `<layer>`, layers **top-first**, so the loop runs `i = layers.count − 1 … 0`):
     ```xml
     <?xml version="1.0" encoding="UTF-8"?>
     <image version="0.0.6" w="W" h="H" xres="R" yres="R">
      <stack>
       <layer name="NAME" visibility="visible|hidden" opacity="O" composite-op="OP" x="0" y="0" src="data/layerI.png"/>
      </stack>
     </image>
     ```
     **Decision:** the active layer's element gets ` selected="true"` appended after `src` (MyPaint/Krita convention; other readers ignore it), and no other layer gets it; on read, the topmost `selected` layer becomes active (step 9). `R = max(1, Int(image.dpi.rounded()))` (`xsd:int`; see Open question 1). `O = opacityString(layer.opacity)`. `OP = OpenRasterBlendMap.compositeOp(for:)`. `NAME = escapeXMLAttribute(layer.name)`.
  8. **`escapeXMLAttribute`:** `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`, `'` → `&apos;`, TAB → `&#9;`, LF → `&#10;`, CR → `&#13;` (so attribute-value normalization can't turn them into spaces). Characters invalid in XML 1.0 (U+0000–U+0008, U+000B, U+000C, U+000E–U+001F, U+FFFE, U+FFFF) are dropped. Everything else, including non-ASCII and emoji, is written as raw UTF-8.
  9. **`opacityString`:** `String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(x) / 255)`, which is FMT-E's `round(x / 255, 3 decimals)` and always has 3 decimals: 0 → `"0.000"`, 1 → `"0.004"`, 127 → `"0.498"`, 128 → `"0.502"`, 255 → `"1.000"`.
  10. **Archive** (`ZipWriter(modificationDate:)`), entries in exactly this order: `mimetype` (stored, bytes `image/openraster`, no newline), `stack.xml` (deflated), `data/layer0.png` … `data/layer<n−1>.png` (stored, since PNG data is already deflate-compressed), `Thumbnails/thumbnail.png` (stored), `mergedimage.png` (stored). The result is that `mimetype`'s local header is at offset 0, its name is at bytes 30–37, and `image/openraster` is at bytes 38–53. Map `ZipWriteError.archiveTooLarge` → `ImageCodecError.archiveTooLarge`, and other `ZipWriteError`s → `.encodingFailed`.

  **Reading (`decode`)**
  1. `ZipReader(data:limits: .forImage(limits))`. Map errors per the table below.
  2. If a `mimetype` entry exists, its contents, decoded as UTF-8 and trimmed of ASCII whitespace/newlines, must equal `image/openraster`, else `.unrecognizedFormat`. A missing `mimetype` entry, or one that is not first, is tolerated (lenient read).
  3. A missing `stack.xml` → `.unrecognizedFormat`. If its `uncompressedSize > maxStackXMLBytes` → `.corrupt`. Read it, then `parseStackXML`.
  4. `limits.validate(width:height:)` on `w`, `h` → `.limitExceeded(error)` on failure (before any layer is read).
  5. Every `src` must name an existing, non-directory entry (exact match; no `./` normalization), else `.corrupt` (missing layer PNG: see Open question 3). Sum `uncompressedSize` over the **distinct** referenced entries plus `stack.xml`. If it exceeds `limits.memoryCapBytes` → `.limitExceeded(.exceedsMemoryCap(requiredBytes: sum, capBytes: cap))` before inflating any layer (zip-bomb guard 2; guard 1 is the per-entry cap in `ZipReader`, guard 3 is the inflate-size check).
  6. Decode each layer (bounded parallelism as in writing, with `canvasBytes` = w × h × 4): `ImageDecoder.decode(entryData, limits: limits)` (content sniffed, ICC → sRGB, 16-bit → 8-bit, limits on the layer's own size). `.limitExceeded` passes through. `.unrecognizedFormat` and `.corrupt` from a layer → `.corrupt`. The layer PNG's own DPI is ignored. Then `place(decoded.surface, at: PixelPoint(x: record.x, y: record.y), onCanvas: canvasSize)`.
  7. **`place`** (FMT-E cropping): if the surface size equals the canvas and the origin is (0, 0), return the surface unchanged (tiles shared, no copy). Otherwise create `TiledSurface(size: canvas)`, compute `r = PixelRect(origin: origin, size: surface.size).intersection(canvas.bounds)`, and if `r` is non-empty copy `surface.readPixels(in: r.offsetBy(dx: −origin.x, dy: −origin.y))` to `r` with `writePixels`. A layer completely outside the canvas becomes an empty, transparent layer that keeps its properties.
  8. **Cumulative memory guard:** after placing all layers, if `Σ allocatedTileCount × Tile.byteCount > limits.memoryCapBytes` → `.limitExceeded(.exceedsMemoryCap(requiredBytes:capBytes:))`.
  9. **Build the image.** Reverse the top-first records to **bottom-first** (`layers[0]` = the last `<layer>` in document order). Each layer gets a fresh `UUID` and `name = record.name ?? "Layer \(bottomFirstIndex + 1)"` (an explicitly empty `name=""` stays empty). Also `isVisible = record.isVisible`, `opacity = opacity(fromUnitValue: record.opacity)`, `blendMode = OpenRasterBlendMap.blendMode(forCompositeOp: record.compositeOp)`. `activeLayerIndex` is the bottom-first index of the **topmost** record with `isSelected`, or else the top layer (`layers.count − 1`). `dpi = stack.dpi`. A stack with **zero** layers yields one transparent layer named `LayeredImage.defaultLayerName` ("Background") at canvas size. The result is `isConsistent`.

  **`parseStackXML`** (Foundation `XMLParser`, `shouldResolveExternalEntities = false`, `shouldProcessNamespaces = false`; a delegate class private to the file; event-driven with an explicit ancestor stack, no recursion):
  - The document element must be `image`, else `.corrupt`. `w`/`h` must parse as `Int` > 0 (leading/trailing ASCII whitespace allowed), else `.corrupt`. Values above 65,535 parse fine and are then refused by step 4 with `.limitExceeded(.dimensionsOutOfRange)`. `version` is ignored.
  - **DPI:** parse `xres` and `yres` as `Double` (decimals accepted on read). Use `xres` if `LayeredImage.isValidDPI`, else `yres` if valid, else **96** (`LayeredImage.defaultDPI`). **Decision:** PRD APP-5 / D-7 ("read from the file's metadata or defaulting to 96 DPI") overrides OpenRaster's own default of 72, for consistency with every other format; PaintDotMac and Krita always write `xres`/`yres`.
  - The first `stack` child of `image` is the root stack. Its attributes are ignored (Krita writes `name="root" opacity="1" …` there). Other children of `image`, any `text` elements, and unknown elements are ignored, with their subtrees.
  - **Nested stacks (groups) are flattened into plain layers** (PaintDotMac has no layer groups; see Open question 2). Each layer's effective opacity = the product of its own `parseOpacity` and every ancestor group's `parseOpacity`. Its effective visibility = its own visibility AND every ancestor's. The group's `composite-op`, `isolation`, and `name` are ignored. The layer keeps its own `composite-op`. Document order is preserved (depth-first, top-first). Nesting deeper than `maxNestingDepth` (64 `stack` levels below the root) → `.corrupt`.
  - `layer` without `src` (or with an empty `src`) → `.corrupt`. `x`/`y`: parse as `Int`; if that fails, parse as `Double` and round (`.toNearestOrAwayFromZero`); missing or unparsable → 0. Values are clamped to ±1,000,000,000 so `place` can't overflow.
  - `visibility`: exactly `hidden` → hidden; anything else, or missing → visible.
  - `selected`: `true` or `1` (case-insensitive) → selected.
  - **`parseOpacity`:** missing, unparsable, or NaN → 1.0; otherwise clamp to 0…1 (`"1.5"` → 1, `"-0.2"` → 0, `"inf"` → 1).
  - **`opacity(fromUnitValue:)`:** `UInt8((f × 255).rounded())` (FMT-E `round(f × 255)`, ties away from zero) after clamping: 0.5 → 128, 0.25 → 64, 0.502 → 128, 0.498 → 127, 0.004 → 1, 0 → 0, 1 → 255.
  - Any `XMLParser` failure (malformed XML, bad encoding, undefined entity) → `.corrupt`.

  **Error mapping (read):**

  | `ZipReadError` | `ImageCodecError` |
  |---|---|
  | `.notAnArchive` | `.unrecognizedFormat` |
  | `.zip64` | `.unsupportedArchive(.zip64)` |
  | `.encrypted` | `.unsupportedArchive(.encryption)` |
  | `.unsupportedCompressionMethod(_, m)` | `.unsupportedArchive(.compressionMethod(m))` |
  | `.multiDisk` | `.unsupportedArchive(.multiDisk)` |
  | `.entryTooLarge(_, size, _)` | `.limitExceeded(.exceedsMemoryCap(requiredBytes: size, capBytes: limits.memoryCapBytes))` |
  | `.corrupt`, `.unsafeEntryName`, `.duplicateEntryName`, `.crcMismatch`, `.entryNotFound` | `.corrupt` |

- **`PaintDotMac/Core/IO/ImageCodecError.swift`** (extend). Add:
  ```swift
  enum UnsupportedArchiveFeature: Equatable, Sendable { case zip64, encryption, compressionMethod(UInt16), multiDisk }
  case unsupportedArchive(UnsupportedArchiveFeature)
  case archiveTooLarge
  ```
  Exact strings (typographic apostrophe U+2019):

  | Case | `errorDescription` | `recoverySuggestion` |
  |---|---|---|
  | `.unsupportedArchive(.zip64)` | `This OpenRaster file uses a ZIP feature PaintDotMac doesn’t support.` | `ZIP64 archives aren’t supported.` |
  | `.unsupportedArchive(.encryption)` | same | `Encrypted archives aren’t supported.` |
  | `.unsupportedArchive(.compressionMethod(m))` | same | `Compression method <m> isn’t supported. Only stored and Deflate entries can be read.` |
  | `.unsupportedArchive(.multiDisk)` | same | `Split archives aren’t supported.` |
  | `.archiveTooLarge` | `The image is too large to save as OpenRaster.` | `OpenRaster files written by PaintDotMac are limited to 4 GB.` |

  Also update 0024's `.layeredImageNeedsFlatten` recovery suggestion to `Choose Image > Flatten, then save again, or save as OpenRaster (.ora) to keep the layers.` (0029 still removes the case.)

- **`PaintDotMac/Core/IO/FileFormat.swift`** (extend 0005):
  - Add `case openRaster` **first**: `case openRaster, png, jpeg`. Then `writableFormats == [.openRaster, .png]` and the save panel's format popup lists OpenRaster first. (0028 uses `NSDocument`'s built-in format popup; 0029 replaces it with its own "Format:" accessory, see `prepareSavePanel` below.)
  - `.openRaster`: `utType = UTType(exportedAs: "org.openraster.ora", conformingTo: .image)`, `typeIdentifier "org.openraster.ora"`, `preferredFilenameExtension "ora"`, `displayName "OpenRaster"`, `canRead true`, `canWrite true`. `init(fileExtension:)` maps `"ora"` case-insensitively.
  - `defaultNewDocumentFormat` → `.openRaster` (PRD §5.11 Saving, D-6).
  - New `static func suggestedSaveFormat(for documentFormat: FileFormat?) -> FileFormat`: the document's format when it `canWrite`, else `defaultNewDocumentFormat`. `saveAction(for:)` uses it for `suggested`.
- **`PaintDotMac/Core/IO/ImageEncoder.swift`** (extend 0005/0024): `encode(_ image: LayeredImage, as: .openRaster)` → `OpenRasterCodec.encode(image)`, for any layer count ≥ 1. `encode(_ surface:size:dpi:as: .openRaster)` wraps the surface in `LayeredImage(surface:dpi:)` and encodes that. PNG behavior is unchanged (multi-layer PNG still throws `.layeredImageNeedsFlatten` until 0029).

### Platform glue (Document / project; covered by hosted and UI tests)

- **`project.yml`** (Info.plist properties of target `PaintDotMac`):
  - `CFBundleDocumentTypes`: insert **first** `{ CFBundleTypeName: "OpenRaster image", LSItemContentTypes: [org.openraster.ora], CFBundleTypeRole: Editor, LSHandlerRank: Default, NSDocumentClass: $(PRODUCT_MODULE_NAME).PaintDocument }`, followed by 0005's PNG and JPEG entries. `NSDocumentController.shared.defaultType` becomes `org.openraster.ora`.
  - `UTExportedTypeDeclarations`: `[{ UTTypeIdentifier: org.openraster.ora, UTTypeDescription: "OpenRaster image", UTTypeConformsTo: [public.image, public.data], UTTypeReferenceURL: "https://www.openraster.org/", UTTypeTagSpecification: { public.filename-extension: [ora], public.mime-type: [image/openraster] } }]`. No icon (0050 may add one).
  - Target `PaintDotMacUITests` `sources`: add `PaintDotMac/Core/IO/CRC32.swift` and `PaintDotMac/Core/IO/ZipWriter.swift` (as extra source paths), so the UI tests can build `.ora` fixtures. Both files depend on nothing else from the app.
  - Run `xcodegen generate`.
- **`PaintDotMac/Document/PaintDocument.swift`** (extend):
  - `override class var readableTypes: [String]` → `FileFormat.allCases.filter(\.canRead).map(\.typeIdentifier)` (`["org.openraster.ora", "public.png", "public.jpeg"]`).
  - `read(from:ofType:)`: keep the unknown-type check, then `let image = OpenRasterCodec.isZipArchive(data) ? try OpenRasterCodec.decode(data, limits: Self.imageLimits) : try ImageDecoder.decodeImage(from: data, limits: Self.imageLimits)` (content is sniffed, as in 0002), then 0008's `undoBridge.reset(state: DocumentState(image: image), base: .openImage)`. The document opens clean with one "Open Image" step, and the active layer comes from the file. `ImageCodecError` propagates, so `NSDocumentController` shows its standard "couldn't be opened" alert with our description and recovery suggestion. Revert To Saved uses the same path.
  - `data(ofType:)` already routes through `ImageEncoder.encode(image, as:)`, so `.ora` saving needs no new code there. `writableTypes(for:)` now returns `["org.openraster.ora", "public.png"]`. `fileNameExtension(forType:…)` returns `"ora"`.
  - `prepareSavePanel(_:)`: `nameFieldStringValue = FileFormat.suggestedFilename(original: fileURL?.lastPathComponent, untitledName: displayName, format: FileFormat.suggestedSaveFormat(for: FileFormat(typeIdentifier: fileType ?? "")))`. **Stop setting `allowedContentTypes`**, because `NSDocument`'s built-in file-format accessory popup sets it for the selected type and switches the name's extension when the user picks another format. Keep `directoryURL`. **Decision (save panel):** 0028 keeps `NSDocument`'s built-in popup (its item titles are the UTType descriptions, "OpenRaster image" and "PNG image"; it preselects the document's `fileType`). 0029 replaces it with its own "Format:" accessory (`savePanel.format`, items titled by `FileFormat.displayName`, preselecting OpenRaster for layered images) and updates this spec's save-panel UI tests and `saveThroughPanel` helper accordingly.
  - Results: an untitled document (its `fileType` is `org.openraster.ora` through 0005's `makeUntitledDocument(ofType: defaultNewDocumentFormat…)`) suggests `Untitled.ora` with "OpenRaster image" selected. An opened `.ora` saves in place on ⌘S (`.writeInPlace(.openRaster)`). An opened PNG still saves in place as PNG, and Save As suggests `<name>.png`. An opened JPEG (not writable until 0029) goes through Save As with `<name>.ora` suggested.
  - Saving runs synchronously on the main thread, as in 0005. Background saving is 0048's call (see Performance).
- **`PaintDotMacUITests/Support/UITestApp.swift`** (extend 0005's helper): `saveThroughPanel(directory:name:format:)`, where `format: String? = nil` is the title of the save sheet's file-format popup item to select first (`sheet.popUpButtons.firstMatch`, then click the item with that title). Every existing caller that saves an **untitled or JPEG-backed** document as PNG (grep `saveThroughPanel(` in `PaintDotMacUITests/`: 0008's `SaveUITests.saveAsNewImageWritesWhitePNG`, 0021's `ClipboardUITests.testPasteIntoNewImageWithoutDocument`, 0005's `SaveUITests.jpegSaveGoesThroughSaveAsPNG`) passes `format: "PNG image"`. (0029 switches this helper to its `savePanel.format` popup and these callers to `"PNG"`.) Update those tests' expected suggested names: `jpegSaveGoesThroughSaveAsPNG` now expects the name field to read `photo.ora` before the format is switched, and `photo.png` after.
- **`PaintDotMacUITests/Support/UITestFixtures.swift`** (extend 0002's): `static func writeOpenRaster(width:height:xres:layers: [UITestORALayer], mutate: ((inout Data) -> Void)? = nil) throws -> URL`, where `struct UITestORALayer { name; pngData; opacity: String; visibility: String; compositeOp: String }` (top-first). It writes `mimetype`, a hand-built `stack.xml`, the layer PNGs (from its own `writePNG` helper), and `mergedimage.png` = the first layer's PNG, using the compiled-in `ZipWriter`. Also `static func setEncryptedFlag(_ data: inout Data, entryName: String)` (sets bit 0 of the flags in that entry's local and central headers, found by scanning for the signatures followed by the name).

## Acceptance criteria

- [ ] CRC-32 matches the IEEE reference values and is the same whether computed in one call or incrementally. → `CRC32Tests.*`
- [ ] The ZIP writer produces byte-exact local, central, and EOCD records, puts `mimetype` first and stored, and its archives pass `/usr/bin/unzip -t`. → `ZipWriterTests.singleStoredEntryBytes`, `.dosDateTime*`, `.deflatedEntryRoundTrips`, `.limitsRaiseArchiveTooLarge`, `ExternalZipToolTests.unzipAcceptsOurArchive`
- [ ] The ZIP reader reads stored and deflated entries, entries written with data descriptors, and archives made by `/usr/bin/zip`. It verifies CRC and sizes. → `ZipReaderTests.*`, `ExternalZipToolTests.readsInfoZipArchive`
- [ ] ZIP64, encrypted, multi-disk, and unsupported-method archives are refused with the FMT-E alert texts. Path-traversal and duplicate names are refused. → `ZipReaderTests.zip64*`, `.encrypted*`, `.multiDisk`, `.unsupportedMethod`, `.unsafeNames`, `.duplicateNames`, `ExternalZipToolTests.infoZipZip64IsRefused`, `.infoZipEncryptedIsRefused`, `ImageCodecErrorTests.archiveMessages`, `OpenRasterUITests.testEncryptedArchiveShowsAlert`
- [ ] Zip bombs are refused before large allocations: per-entry declared size cap, total declared size cap, and inflate-past-declared-size detection. → `ZipReaderTests.entryTooLarge`, `.inflateOverflowIsCorrupt`, `OpenRasterCodecReadTests.totalDeclaredSizeOverCap`, `.realDeflateBomb`
- [ ] Saved `.ora` files have the exact OpenRaster 0.0.6 layout: `mimetype` first/stored, `stack.xml` in the exact format, top-first layers, `data/layerN.png`, `mergedimage.png` = the CPU composite, `Thumbnails/thumbnail.png` ≤ 256 with aspect kept. → `OpenRasterCodecWriteTests.*`
- [ ] Composite ops map per FMT-E both ways, and unknown ops read as Normal. → `OpenRasterBlendMapTests.*`
- [ ] Opacity is written as `round(x/255, 3 dp)` and read as `round(f × 255)`, round-tripping all 256 values. → `OpenRasterCodecTests.opacityRoundTripsAll256`, `.opacitySpotValues`, `.parseOpacityEdgeCases`
- [ ] A round trip preserves layer count, order, names (including XML-special and non-ASCII characters), visibility, opacity, blend mode, every pixel (including color under alpha 0), the active layer, and integer DPI (AGENTS.md *Testing expectations*). → `OpenRasterRoundTripTests.*`
- [ ] Krita-style files open: groups are flattened (opacity multiplied, hidden propagated), offset and oversized layers are cropped to the canvas (FMT-E), hidden layers are kept, missing names get "Layer N", `selected` sets the active layer, text and unknown elements are ignored. → `OpenRasterCodecReadTests.kritaStyleFixture`, `.placeCrops*`
- [ ] Damaged input (truncations, bit flips, bad XML, missing `stack.xml`, missing layer PNG, bad `w`/`h`, oversized canvas) never traps and gives the specified error. → `OpenRasterCodecReadTests.*Failure*`, `OpenRasterFuzzTests.randomMutationsNeverTrap`
- [ ] New documents default to `.ora`: ⌘N then ⌘S suggests "Untitled.ora". The saved file reopens with its layers. ⌘S on an opened `.ora` writes in place. → `FileFormatTests.*` (updated), `PaintDocumentOpenRasterTests.*`, `OpenRasterUITests.testNewImageSavesAsOpenRasterAndReopens`
- [ ] `.ora` is a declared, openable document type (`org.openraster.ora`, Editor, exported UTI). → `SmokeTests.documentTypes` (updated), `PaintDocumentOpenRasterTests.utiIsDeclared`
- [ ] Opening an `.ora` fixture shows its layers with names, visibility, opacity, and blend mode in the Layers panel and Layer Properties. → `OpenRasterUITests.testOpensFixtureWithLayerProperties`
- [ ] A damaged `.ora` shows the "damaged or incomplete" alert and the app keeps running. → `OpenRasterUITests.testCorruptOpenRasterShowsAlert`
- [ ] Save and open of a 10-layer 3840×2160 document are measured and within the gross-regression gate. → `OpenRasterPerformanceTests.testSave10Layer4K`, `.testOpen10Layer4K`
- [ ] M3 exit: an `.ora` saved by PaintDotMac opens in Krita with the same layers, and a Krita-saved `.ora` opens in PaintDotMac. → manual 1–2 (needs Krita)
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Layer order:** ORA lists top-first and PaintDotMac stores bottom-first. Writing iterates `layers.reversed()`. Reading reverses. `data/layer0.png` is always the bottom layer.
- **Single layer, 1×1 canvas, 65,535×1 canvas:** all encode and decode (thumbnail 1×1 and 256×1).
- **Empty (no allocated tiles) layers** encode as a fully transparent PNG and decode back to zero allocated tiles (0002's bulk import skips zero tiles).
- **Color under alpha 0** survives layer PNGs (straight RGBA, 0005/0002). `mergedimage.png` may differ there (compositor output), and is never read.
- **Hidden layers, opacity 0:** written and read like any layer. Excluded from `mergedimage.png` by the compositor.
- **Names:** `& < > " '`, tab/LF/CR, emoji, and RTL text round-trip. XML-invalid control characters are dropped on write (so the reread name lacks them). A missing `name` → `"Layer N"` (bottom-first 1-based). `name=""` stays empty. Duplicate names are allowed.
- **DPI:** integer DPI round-trips exactly. A non-integer DPI is written rounded (72.5 → `73`, Open question 1). DPI < 0.5 → `1`. Missing/invalid `xres` and `yres` → 96 (APP-5 decision above). Only one present → that one. Decimal `xres="72.5"` in a foreign file → 72.5.
- **Offsets / oversized layers:** negative `x`/`y`, layers larger than the canvas, layers fully outside the canvas (→ empty layer), and huge offsets (clamped, no overflow) are all cropped to `(0, 0, w, h)` (FMT-E).
- **Groups:** nested stacks flattened (Open question 2). Isolated groups with non-Normal child modes or a non-Normal group op will composite differently from Krita, which is accepted and documented. A hidden group hides its children. Nesting > 64 → corrupt.
- **Unknown/unsupported composite ops**, including standard ones without a PaintDotMac mode yet (`svg:hard-light` … until 0059, `svg:dst-in`, `svg:src-atop`), read as Normal.
- **Missing `mergedimage.png` / thumbnail** in a foreign file: ignored (never read). **Missing `mimetype`:** tolerated. **Wrong `mimetype`:** "isn’t a supported image".
- **A ZIP that isn't OpenRaster** (no `stack.xml`) → "The file isn’t a supported image." **A `.ora` that is really a PNG** → opens as a one-layer PNG image (content sniffing). Its `fileType` stays `.ora`, so ⌘S writes a real `.ora`.
- **Missing layer PNG, undecodable layer PNG, `src` with `../`** → "The image is damaged or incomplete." (Open question 3).
- **Encrypted / unsupported method on an entry that is never read** (for example an extra `preview.bin`): the file opens.
- **Data descriptors** (bit 3) with zeroed local CRC/sizes: read correctly from central-directory values.
- **Truncated archive** (any length 0 … n−1): `.unrecognizedFormat` (EOCD missing) or `.corrupt`, never a trap.
- **Archive > 4 GB on save** (huge canvas × many layers): `.archiveTooLarge` alert. The document stays open and edited, and `NSDocument`'s safe save leaves any existing file untouched.
- **Memory:** layer and canvas limits (APP-10) are checked before decoding. The cumulative tile-bytes guard refuses stacks whose decoded layers exceed the cap. Parallel encode/decode is bounded by `concurrency(…)`.
- **Multi-layer document saved as PNG:** still `.layeredImageNeedsFlatten` (0024) until 0029. The alert now suggests `.ora`.
- **Undo/redo:** opening and saving add no history steps. Saving marks the saved step (0008), so after ⌘S undo makes the document dirty and redo makes it clean again (covered by 0008's tests; re-checked for `.ora` in `PaintDocumentOpenRasterTests.saveMarksCleanAndUndoDirties`).
- **Pending tool edit at save time:** committed first (0008/0009), so the `.ora` includes it.

## Test plan

Expected values are hand-computed or come from the OpenRaster/PKWARE specs and external tools, never from running the code under test. Swift Testing unless stated. Fixtures are generated in tests (no binary fixtures in git).

- **Unit: `PaintDotMacTests/IO/CRC32Tests.swift`**
  - `referenceValues`: `""` → `0x00000000`; `"a"` → `0xE8B7BE43`; `"123456789"` → `0xCBF43926`; `"hello"` → `0x3610A686`; `"The quick brown fox jumps over the lazy dog"` → `0x414FA339`.
  - `incrementalEqualsOneShot`: 10 seeded random buffers (1 … 100_000 bytes), each split at 3 random points and fed in 4 `update` calls, equal `checksum` of the whole buffer. Also every split of `"123456789"` (0…9) gives `0xCBF43926`.
  - `slicingMatchesBitwiseReference`: a bit-by-bit reference CRC in the test file (8 shifts per byte with `0xEDB88320`) equals `CRC32.checksum` for 20 seeded buffers of lengths 0…1,031 (covers every tail length mod 8).
- **Unit: `PaintDotMacTests/IO/ZipWriterTests.swift`**
  - `singleStoredEntryBytes`: `ZipWriter(modificationDate: 2024-03-15 13:45:30 UTC, timeZone: UTC)`, `addEntry(named: "a.txt", data: "hello", method: .stored)`, `finish()` equals exactly these 113 bytes:
    - local (0–39): `50 4B 03 04 0A 00 00 00 00 00 AF 6D 6F 58 86 A6 10 36 05 00 00 00 05 00 00 00 05 00 00 00 61 2E 74 78 74 68 65 6C 6C 6F`;
    - central (40–90): `50 4B 01 02 1E 03 0A 00 00 00 00 00 AF 6D 6F 58 86 A6 10 36 05 00 00 00 05 00 00 00 05 00 00 00 00 00 00 00 00 00 00 00 A4 81 00 00 00 00 61 2E 74 78 74`;
    - EOCD (91–112): `50 4B 05 06 00 00 00 00 01 00 01 00 33 00 00 00 28 00 00 00 00 00`.
  - `dosDateTimeEncoding`: 2024-03-15 13:45:30 UTC → (date `0x586F`, time `0x6DAF`); 1980-01-01 00:00:00 → (`0x0021`, `0`); 1975-06-01 → (`0x0021`, `0`); 2107-12-31 23:59:58 → (`0xFF9F`, `0xBF7D`); 2200-01-01 → the same clamped values; odd seconds round down (13:45:31 → `0x6DAF`).
  - `deflatedEntryRoundTrips`: entries `stack.xml` (2 KB of repetitive XML, `.deflated`), `empty` (0 bytes, `.deflated`), and `b.bin` (64 KB seeded random, `.stored`). Read back with `ZipReader`: contents equal, central methods `[8, 8, 0]`, the version-needed field is `20` for deflated and `10` for stored, compressed size < uncompressed for the XML.
  - `utf8NameSetsFlag`: name `"données/é.png"` → flags `0x0800` in local and central. ASCII names → `0x0000`.
  - `invalidNamesRejected`: `""`, `"/abs"`, `"../x"`, `"a/../../b"`, `"a\\b"`, `"C:x"`, `"a\u{0}b"` → `.invalidEntryName`. Adding `"x"` twice → `.duplicateEntryName("x")`.
  - `limitsRaiseArchiveTooLarge`: the writer's size check is a pure helper, `ZipWriter.fitsWithoutZip64(size:offset:count:)`, tested with `0xFFFF_FFFE` (fits), `0xFFFF_FFFF` (doesn't), and count `0xFFFE`/`0xFFFF`. Adding 65,535 empty stored entries → `finish()` throws `.archiveTooLarge`. (No multi-GB allocation in tests.)
- **Unit: `PaintDotMacTests/IO/ZipReaderTests.swift`**, using `PaintDotMacTests/Support/ZipTestBuilder.swift`: an independent, test-only raw record builder. It writes local/central/EOCD records from explicit field values (flags, method, CRC, sizes, names, extra fields, optional data descriptor with or without signature, optional ZIP64 locator, arbitrary EOCD counts), with no shared code with `ZipWriter`.
  - `readsStoredEntry`: the 113-byte archive above (written literally in the test) → one entry `"a.txt"`, method 0, CRC `0x3610A686`, contents `"hello"`.
  - `readsKnownDeflateStream`: an entry `"h"` with method 8, compressed bytes `CB 48 CD C9 C9 07 00` (raw DEFLATE of "hello"), CRC `0x3610A686`, sizes 7/5 → `"hello"`.
  - `inflateOverflowIsCorrupt`: the same stream with declared uncompressed size 4 → `.corrupt`. With size 6 → `.corrupt`. With CRC `0` → `.crcMismatch(entry: "h")`.
  - `dataDescriptorEntries`: entries with flag bit 3, local CRC/sizes zero, and a descriptor after the data (once with signature `50 4B 07 08`, once without) → contents correct, both stored and deflated.
  - `archiveComment`: an EOCD with a 100-byte comment → parses. With a comment length that runs past the end → `.notAnArchive`.
  - `notAnArchive`: `Data()`, 21 bytes, a PNG file, 1 KB random → `.notAnArchive`.
  - `zip64Locator`, `zip64EOCDMarkers` (`0xFFFF` total entries; `0xFFFF_FFFF` cd offset), `zip64ExtraField` (central extra block ID `0x0001`) → `.zip64`.
  - `multiDisk`: EOCD disk number 1 → `.multiDisk`. Entries-on-disk ≠ total → `.multiDisk`.
  - `encryptedEntry`: central flag bit 0 on `"s"` → `ZipReader.init` succeeds and `contents(named: "s")` throws `.encrypted(entry: "s")`. Bit 6 → the same. Central clear but local bit 0 set → `.encrypted`.
  - `unsupportedMethod`: method 12 → `.unsupportedCompressionMethod(entry:method: 12)`. Method 14 → method 14. Another stored entry in the same archive still reads.
  - `unsafeNames`: each of `"../evil.png"`, `"/abs.png"`, `"a\\b.png"`, `"data/../../x.png"`, `"C:evil"`, `""` → `init` throws `.unsafeEntryName`. `"data/..x.png"` and `"a..b"` are accepted.
  - `duplicateNames`: two `"stack.xml"` entries → `.duplicateEntryName("stack.xml")`.
  - `entryTooLarge`: limits `maxEntryUncompressedSize = 1_000`, entry declaring 1_001 → `.entryTooLarge(entry:uncompressedSize: 1001, limit: 1000)`. Declaring 1_000 → reads.
  - `structuralCorruption`: central signature wrong; cd offset + size past EOCD; local signature wrong; local name differs from central; data running past the central directory; stored entry with compressed ≠ uncompressed; garbage deflate bytes `FF FF FF` → each `.corrupt`.
  - `forImageLimits`: `ZipReaderLimits.forImage(ImageLimits(memoryCapBytes: 10)).maxEntryUncompressedSize == 10`; with cap `Int.max` → `0xFFFF_FFFE`.
- **Unit: `PaintDotMacTests/IO/ExternalZipToolTests.swift`** (independent oracle: Info-ZIP `/usr/bin/zip` and `/usr/bin/unzip`, which ship with macOS; run through `Process` in a temp directory):
  - `unzipAcceptsOurArchive`: an `OpenRasterCodec.encode` of a 3-layer 300×200 image → `unzip -t` exits 0 and prints "No errors detected". `unzip -Z1` lists exactly `mimetype, stack.xml, data/layer0.png, data/layer1.png, data/layer2.png, Thumbnails/thumbnail.png, mergedimage.png` in that order. `unzip -p x.ora stack.xml` equals `stackXML(for:)`.
  - `readsInfoZipArchive`: `zip -X t.zip a.txt b.bin` (deflated text, stored-or-deflated random data as zip chooses) and `zip -0 -X s.zip a.txt` → `ZipReader` contents equal the source files.
  - `infoZipZip64IsRefused`: `zip -fz z.zip a.txt` → `ZipReader.init` throws `.zip64`.
  - `infoZipEncryptedIsRefused`: `zip -P secret e.zip a.txt` → `contents(named: "a.txt")` throws `.encrypted`. Through `OpenRasterCodec.decode` (an encrypted `stack.xml` made the same way next to a stored `mimetype`) → `.unsupportedArchive(.encryption)`.
- **Unit: `PaintDotMacTests/IO/OpenRasterBlendMapTests.swift`**
  - `everyModeHasTheFMTEOp`: the full 14-row table, asserted literally, row by row.
  - `readBackIsIdentity`: for every `BlendMode.allCases`, `blendMode(forCompositeOp: compositeOp(for: m)) == m`. The ops are unique.
  - `unknownOpsAreNormal`: `nil`, `""`, `"svg:hard-light"`, `"svg:dst-in"`, `"svg:src-atop"`, `"krita:dissolve"`, `"SVG:MULTIPLY"`, `"paintdotmac:unknown"` → `.normal`. `" svg:multiply "` → `.multiply`.
- **Unit: `PaintDotMacTests/IO/OpenRasterCodecTests.swift`** (pure helpers)
  - `opacityRoundTripsAll256`: for x in 0…255, `opacity(fromUnitValue: parseOpacity(opacityString(x))) == x`.
  - `opacitySpotValues`: 0 → `"0.000"`, 1 → `"0.004"`, 127 → `"0.498"`, 128 → `"0.502"`, 254 → `"0.996"`, 255 → `"1.000"`. `opacity(fromUnitValue:)`: 0.5 → 128, 0.25 → 64, 0.004 → 1, 0.001 → 0, 0.002 → 1.
  - `parseOpacityEdgeCases`: `nil` → 1, `"abc"` → 1, `"nan"` → 1, `"inf"` → 1, `"1.5"` → 1, `"-0.2"` → 0, `" 0.25 "` → 0.25, `"1e-1"` → 0.1.
  - `escapeXMLAttribute`: `a&b<c>"d'e` → `a&amp;b&lt;c&gt;&quot;d&apos;e`; `"x\ty\nz\r"` → `x&#9;y&#10;z&#13;`; `"a\u{1}b\u{FFFE}c"` → `abc`; `"日本🎨"` unchanged.
  - `thumbnailSizes`: the six examples in Scope.
  - `concurrencyBound`: the four examples in Scope.
  - `placeCropsOffsetAndOversized`: a 10×10 surface with pixel (x,y) = (x, y, 7, 255) placed at (−1, −2) on a 8×6 canvas → canvas pixel (cx, cy) == (cx+1, cy+2, 7, 255) for all 48 pixels. Placed at (6, 4) → only (6..7, 4..5) set, equal to the source's (0..1, 0..1), and everything else (0,0,0,0). Placed at (8, 0) or (−10, 0) → zero allocated tiles. Placed at (1_000_000_000, −1_000_000_000) → zero allocated tiles, no trap.
  - `placeFastPathSharesTiles`: same size at (0,0) → the returned surface's tile (0,0) `sharesStorage(with:)` the input's.
  - `placeAcrossTileSeams`: a 600×600 seeded random surface at (−100, −50) on 512×512 → equals a per-pixel reference copy.
- **Unit: `PaintDotMacTests/IO/OpenRasterCodecWriteTests.swift`**
  - `stackXMLExact`: an image 800×600 at dpi 96, layers bottom-first `Background` (visible, 255, normal), `Ink & "Notes"` (hidden, 128, multiply), `Glow` (visible, 0, glow), with active index 1 → `stackXML(for:)` equals literally:
    ```
    <?xml version="1.0" encoding="UTF-8"?>
    <image version="0.0.6" w="800" h="600" xres="96" yres="96">
     <stack>
      <layer name="Glow" visibility="visible" opacity="0.000" composite-op="paintdotmac:glow" x="0" y="0" src="data/layer2.png"/>
      <layer name="Ink &amp; &quot;Notes&quot;" visibility="hidden" opacity="0.502" composite-op="svg:multiply" x="0" y="0" src="data/layer1.png" selected="true"/>
      <layer name="Background" visibility="visible" opacity="1.000" composite-op="svg:src-over" x="0" y="0" src="data/layer0.png"/>
     </stack>
    </image>
    ```
    (with a trailing newline).
  - `dpiIsRoundedInteger`: dpi 72.5 → `xres="73" yres="73"`; 300 → `"300"`; 0.4 → `"1"`.
  - `archiveLayout`: encode the image above with a fixed date. With `ZipReader`: entry names in order `mimetype, stack.xml, data/layer0.png, data/layer1.png, data/layer2.png, Thumbnails/thumbnail.png, mergedimage.png`; methods `0, 8, 0, 0, 0, 0, 0`. Raw bytes: 0–3 = `50 4B 03 04`, 8–9 = `00 00`, 26–27 = `08 00`, 28–29 = `00 00`, 30–53 = ASCII `mimetypeimage/openraster`. `mimetype` contents have no trailing newline.
  - `layerPNGsAreExactLayers`: each `data/layerN.png` decodes (with `ImageDecoder`) to exactly layer N's pixels at 800×600, including a pixel `(10,20,30,0)` placed in `Ink`. It has an sRGB profile name (0005's `PNGChunks` helper finds `iCCP`/`sRGB`) and DPI within 0.05 of 96.
  - `mergedImageIsCPUComposite`: `mergedimage.png` decodes to `CPUCompositor().flattened(image)` exactly (hidden `Ink` excluded), checked against a hand-computed pixel: Background (200,100,50,255) under an invisible Ink and a 0-opacity Glow → (200,100,50,255) everywhere.
  - `thumbnailFitsAndKeepsAspect`: the 800×600 image → thumbnail PNG 256×192, 8 bits per component, not interlaced (`kCGImagePropertyPNGInterlaceType` 0 or absent). A 200×100 image → thumbnail bytes == mergedimage bytes. The thumbnail of a solid opaque red image is red (±1) at its center.
  - `encodesSingleOneByOneLayer`: a 1×1 one-layer image encodes, and decodes back equal.
  - `inconsistentImageFails`: an image with `activeLayerIndex` out of range (mutated after init) → `.encodingFailed`.
- **Unit: `PaintDotMacTests/IO/OpenRasterCodecReadTests.swift`** (archives built with `ZipTestBuilder` or `ZipWriter` plus hand-written `stack.xml`; layer PNGs from `TestImages`)
  - `kritaStyleFixture`: the golden fixture, built in the test. Canvas `w="8" h="6"`, `version="0.0.1"`, `xres="150" yres="150"`, a `<!DOCTYPE image>`, and a root `<stack name="root" opacity="1" visibility="visible" composite-op="svg:src-over" x="0" y="0">`. Children top-first:
    1. `<layer name="Top" src="data/a.png" x="6" y="4" opacity="0.5" composite-op="svg:multiply"/>` with a.png 4×4 solid (255,0,0,255).
    2. `<stack name="Group" opacity="0.5" composite-op="svg:screen">` containing `<layer name="Child" src="data/b.png" opacity="0.5" composite-op="svg:screen"/>` (b.png 8×6 solid (0,255,0,255)) and `<layer name="Hidden child" src="data/c.png" visibility="hidden" composite-op="krita:dissolve"/>` (c.png 2×2 solid (0,0,255,255)).
    3. `<stack visibility="hidden"><layer name="In hidden group" src="data/c.png"/></stack>`.
    4. `<text>ignored</text>`.
    5. `<layer src="data/d.png" x="-1" y="-2" selected="true"/>` (d.png 10×10 solid (10,20,30,40)).

    The `data/b.png` entry is written with a data descriptor, `stack.xml` is deflated, and there is no `mergedimage.png`. Expected `LayeredImage` (bottom-first): `[("Layer 1", visible, 255, .normal, all 48 pixels (10,20,30,40)), ("In hidden group", hidden, 255, .normal, (0..1,0..1) blue, rest clear), ("Hidden child", hidden, 128, .normal, (0..1,0..1) blue), ("Child", visible, 64, .screen, all green), ("Top", visible, 128, .multiply, (6..7,4..5) red, rest clear)]`, `activeLayerIndex == 0`, `dpi == 150`, `size == 8×6`, `isConsistent`.
  - `noSelectedMeansTopActive`; `twoSelectedTopmostWins`.
  - `missingNameNumbering`: three unnamed layers → bottom-first names `Layer 1`, `Layer 2`, `Layer 3`. `name=""` → `""`.
  - `dpiResolution`: (`xres="300" yres="300"`) → 300; (`xres="72.5"`) → 72.5; (no xres/yres) → 96; (`xres="0" yres="200"`) → 200; (`xres="abc"`, `yres="-1"`) → 96.
  - `emptyStackGivesBackground`: `<stack/>` → one transparent "Background" layer at canvas size, active 0.
  - `mimetypeChecks`: `mimetype` = `image/png` → `.unrecognizedFormat`; `image/openraster\n` → opens; no mimetype → opens; mimetype not first → opens.
  - `notOpenRaster`: a ZIP with only `readme.txt` → `.unrecognizedFormat`. A PNG's bytes → `isZipArchive == false`.
  - `layerFailures` (each → `.corrupt`): `src` missing from the archive; `src="../x.png"`; layer PNG that is random bytes; layer PNG truncated (half); `<layer>` without `src`; `stack.xml` not well-formed (`<image w="1"`); document element `<stack>`; `w="0"`, `w="-5"`, `w="abc"`, missing `h`; 65 nested `<stack>` levels (64 → opens).
  - `limitFailures`: `w="70000" h="1"` → `.limitExceeded(.dimensionsOutOfRange(width: 70000, height: 1))`. A layer PNG of 70,000×1 (header made by `TestImages` IHDR patch) → `.limitExceeded(.dimensionsOutOfRange)`. `ImageLimits(memoryCapBytes: 8×6×4)` with two full 8×6 layers → `.limitExceeded(.exceedsMemoryCap)` (cumulative tile guard, 2 × 262,144 > 192).
  - `totalDeclaredSizeOverCap`: cap 1_000_000. Two layer entries declaring 600_000 bytes each (stored, real data) → `.limitExceeded(.exceedsMemoryCap(requiredBytes: ≥1_200_000, capBytes: 1_000_000))`, thrown before decoding (assert via a layer whose PNG is invalid: the limit error wins over `.corrupt`).
  - `realDeflateBomb`: an entry of 64 MiB zeros deflated with `ZipWriter.deflate` (≈64 KiB) as `data/layer0.png` with cap 1 MiB → `.limitExceeded`, and the call returns in < 1 s.
  - `unsupportedFeatures`: `stack.xml` encrypted → `.unsupportedArchive(.encryption)`; `stack.xml` method 12 → `.unsupportedArchive(.compressionMethod(12))`; a ZIP64 locator → `.unsupportedArchive(.zip64)`; an encrypted entry `extra.bin` that is never referenced → opens.
  - `truncationsNeverTrap`: the encoded image from `archiveLayout`, truncated to lengths 0, 1, 4, 21, 22, n/4, n/2, n−22, n−1 → each throws `.unrecognizedFormat` or `.corrupt` (asserted per length: lengths that lose the EOCD → `.unrecognizedFormat`).
- **Round-trip and property tests: `PaintDotMacTests/IO/OpenRasterRoundTripTests.swift`**
  - `preservesLayerProperties`: the AGENTS.md test. A 5-layer 300×260 image (crosses tile seams) with names `["Background", "Ink & \"Notes\" <1>", "日本 🎨", "tab\there", "Layer 2"]`, visibility `[t, f, t, t, f]`, opacity `[255, 128, 0, 1, 254]`, blend modes `[.normal, .multiply, .xor, .reflect, .difference]`, active 3, dpi 300, seeded pixels including alpha-0 pixels with non-zero RGB → `decode(encode(x))` equals `x` in size, dpi, layer count, order, names, visibility, opacity, blend mode, every pixel, and `activeLayerIndex` (ids excepted: compare everything but `id`).
  - `everyBlendModeRoundTrips`: one layer per `BlendMode.allCases` (14 layers, 16×16) → blend modes equal in order.
  - `randomImagesRoundTrip`: 20 seeds from `SeededRandom` (seed printed on failure): 1–5 layers, size 1…600 per side, random names from a pool (ASCII, XML specials, Unicode, tab/LF/CR), random opacity 0…255, visibility, blend mode, active index, integer dpi 1…1000, random pixels with 20% alpha 0 and 20% alpha 255 → equal after round trip (ids excepted).
  - `doubleRoundTripIsStable`: `encode(decode(encode(x)))` and `encode(x)` (same date) have identical `stack.xml` and identical layer PNG entry bytes.
- **Fuzz: `PaintDotMacTests/IO/OpenRasterFuzzTests.swift`**
  - `randomMutationsNeverTrap`: 300 seeds: take a valid 2-layer 64×64 `.ora`, overwrite 1–8 random bytes with random values (seed printed) → `decode` either throws an `ImageCodecError` or returns an image that `isConsistent`, with size 64×64. Never traps. The whole loop finishes in < 20 s in Debug.
- **Unit: `PaintDotMacTests/IO/FileFormatTests.swift`** (update 0005's)
  - `typeIdentifiers`: adds `.openRaster.typeIdentifier == "org.openraster.ora"`, and `FileFormat(typeIdentifier: "org.openraster.ora") == .openRaster`.
  - `fileExtensions`: adds `"ora"`, `"ORA"` → `.openRaster`.
  - `capabilities`: `allCases == [.openRaster, .png, .jpeg]`; `.openRaster` reads and writes; `writableFormats == [.openRaster, .png]`; `defaultNewDocumentFormat == .openRaster`; `.openRaster.displayName == "OpenRaster"`, extension `"ora"`.
  - `saveActionUntitled` → `.saveAs(offering: [.openRaster, .png], suggested: .openRaster)`; `saveActionForOpenRasterWritesInPlace` → `.writeInPlace(.openRaster)`; `saveActionForPNGWritesInPlace` unchanged; `saveActionForJPEGIsSaveAs` → `.saveAs(offering: [.openRaster, .png], suggested: .openRaster)`.
  - `suggestedSaveFormat`: nil → `.openRaster`; `.png` → `.png`; `.jpeg` → `.openRaster`; `.openRaster` → `.openRaster`.
  - `suggestedFilenameUntitled`: (nil, "Untitled", `.openRaster`) → `"Untitled.ora"`; ("photo.jpg", `.openRaster`) → `"photo.ora"`.
- **Hosted: `PaintDotMacTests/Document/PaintDocumentSavingTests.swift`** (update 0005's): `writableTypesArePNGOnly` → renamed `writableTypesAreAllWritableFormats`: for a PNG-read and a JPEG-read document, `writableTypes(for:)` == `["org.openraster.ora", "public.png"]` for `.saveOperation`, `.saveAsOperation`, and `.saveToOperation` (0029 updates its expectation to the seven writable formats; no further rename). `dataOfTypeJPEGThrows` and `jpegDocumentSaveActionIsSaveAs` are unchanged here (0029 changes them).
- **Unit: `PaintDotMacTests/IO/ImageCodecErrorTests.swift`** (extend): `archiveMessages` asserts the five rows of the new table literally (method 12 → `Compression method 12 isn’t supported. Only stored and Deflate entries can be read.`), and the updated `.layeredImageNeedsFlatten` recovery suggestion.
- **Unit: `PaintDotMacTests/IO/ImageEncoderTests.swift`** (extend): `openRasterAcceptsMultipleLayers`: `encode(twoLayerImage, as: .openRaster)` decodes back with 2 layers. `encode(surface, size:, dpi: 72, as: .openRaster)` → one "Background" layer, dpi 72.
- **Hosted integration: `PaintDotMacTests/Document/PaintDocumentOpenRasterTests.swift`**
  - `utiIsDeclared`: `UTType(filenameExtension: "ora")?.identifier == "org.openraster.ora"`; `UTType("org.openraster.ora")?.conforms(to: .image) == true`; `Bundle.main` `UTExportedTypeDeclarations` contains exactly the declared dictionary (identifier, description, conformsTo, tags, reference URL).
  - `readableAndWritableTypes`: `PaintDocument.readableTypes == ["org.openraster.ora", "public.png", "public.jpeg"]`; `writableTypes(for:)` == `["org.openraster.ora", "public.png"]` for save, save-as, and save-to; `fileNameExtension(forType: "org.openraster.ora", …) == "ora"`.
  - `untitledDocumentIsOpenRaster`: a document made through the 0005/0008 New Image path → `fileType == "org.openraster.ora"`. `NSDocumentController.shared.defaultType == "org.openraster.ora"`.
  - `saveAsAndReopen`: a 3-layer document (state set through `undoBridge.reset`) → `save(to: tmp/x.ora, ofType: "org.openraster.ora", for: .saveAsOperation)` (awaited) → no error, clean, `fileType` ora. `NSDocumentController.shared.makeDocument(withContentsOf:ofType:)` → the same layers/properties/pixels/dpi/active layer, one "Open Image" history step, `isDocumentEdited == false`.
  - `saveInPlaceKeepsOpenRaster`: open a temp `.ora` → `FileFormat.saveAction(for: .openRaster)` is in place; `save(to: fileURL, ofType: fileType!, for: .saveOperation)` rewrites the file (modification date advances) and it re-decodes equal.
  - `saveMarksCleanAndUndoDirties`: open `.ora`, commit a paint step (a `TileDiffHistoryItem` built in the test), save → clean; undo → dirty; redo → clean.
  - `zipSniffingIgnoresTypeName`: `.ora` bytes read with type `public.png` → layered image. PNG bytes read with type `org.openraster.ora` → one-layer image.
  - `damagedFileThrowsCodecError`: `read(from: Data([0x50,0x4B,0x03,0x04,0,0]), ofType: ora)` throws `ImageCodecError.unrecognizedFormat`. An encrypted `stack.xml` → `.unsupportedArchive(.encryption)`.
  - `pngSaveOfLayeredImageSuggestsOra`: a 2-layer document, `data(ofType: "public.png")` throws `.layeredImageNeedsFlatten` whose recovery suggestion contains "OpenRaster (.ora)".
- **Unit: `PaintDotMacTests/SmokeTests.swift`** (update 0001's `SmokeTests.documentTypesMapPNGAndJPEGToPaintDocument` → renamed `SmokeTests.documentTypes`; 0029 extends the same test): three `CFBundleDocumentTypes` entries in order `org.openraster.ora`, `public.png`, `public.jpeg`; all `Editor`; the ORA rank is `Default`; every `NSDocumentClass` resolves to `PaintDocument`. Update any 0001 assertion that there are no exported type declarations.
- **UI tests: `PaintDotMacUITests/OpenRasterUITests.swift`** (`UITestApp`, `-UITestResetDefaults YES`, fixtures in a per-test temp dir)
  - `testNewImageSavesAsOpenRasterAndReopens`: launch empty; ⌘N, Return; ⇧⌘N (Add New Layer, 0024); ⌘S → the save sheet's name field reads `Untitled.ora` and the format popup's selected title is "OpenRaster image". `saveThroughPanel(directory: tmp, name: "layers.ora")` → the window title is `layers.ora`. The file's bytes 0–3 are `50 4B 03 04` and bytes 30–53 are ASCII `mimetypeimage/openraster`. ⌘W closes with no save sheet (clean). Relaunch with `-UITestOpen tmp/layers.ora` → `layerRow.0` label "Background", `layerRow.1` label "Layer 2" with value "active", and the history list has one row ("Open Image").
  - `testOpensFixtureWithLayerProperties`: `UITestFixtures.writeOpenRaster(width: 64, height: 48, xres: 72, layers: [Off (hidden, "1.0", svg:src-over), Ink ("0.502", visible, svg:multiply), Base ("1.0", visible, svg:src-over)])` → launch with `-UITestOpen` → `layerRow.0` "Base", `layerRow.1` "Ink", `layerRow.2` "Off" (value "active": top layer, no `selected`); `layerVisibility.2` value 0, `layerVisibility.1` value 1. Double-click `layerRow.1` → `layerProperties.blendMode` shows "Multiply" and the opacity field "128"; Escape closes it. The status bar's units popup set to Inches shows the image size `0.89 × 0.67 in` (64/72, 48/72; proves xres was read), following 0004's status-bar format.
  - `testSaveAsOffersOpenRasterAndPNG`: open a PNG fixture `photo.png`, ⇧⌘S → the name field reads `photo.png`, and the format popup contains "OpenRaster image" and "PNG image". Choose "OpenRaster image" → the name field reads `photo.ora`. Cancel.
  - `testCorruptOpenRasterShowsAlert`: a fixture with `stack.xml` = `<image w="1"` → launch with `-UITestOpen` → an alert whose text contains "The image is damaged or incomplete." Dismiss it → the app is still running and there are no document windows.
  - `testEncryptedArchiveShowsAlert`: a valid fixture passed through `setEncryptedFlag(_, entryName: "stack.xml")` → the alert contains "This OpenRaster file uses a ZIP feature PaintDotMac doesn’t support." and "Encrypted archives aren’t supported."
- **Performance: `PaintDotMacTests/Performance/OpenRasterPerformanceTests.swift`** (XCTest `measure`, 5 iterations; the fixture is built once in `setUp`). A 10-layer 3840×2160 image: layer i has a seeded random-noise 512×512 patch at a seeded position, a horizontal gradient over the left half of the canvas, and transparent elsewhere (about half the tiles allocated, realistic for a layered drawing). There is no PRD target for save/open. The **targets** are save ≤ 3 s and open ≤ 2 s on an M1 (sized after NF-2's "open a 24 MP JPEG in under 1 s"). **Gate** at 3× in the Debug test run: `testSave10Layer4K` average < 9 s; `testOpen10Layer4K` average < 6 s. The open test also asserts the decoded image equals the source (once, outside `measure`). Report the measured averages in the Verification status. NF-1–NF-4 are not affected (no canvas, compositing-path, or history changes; saving is a one-off main-thread operation; if the measured save exceeds 1 s, record it for 0048 to consider `canAsynchronouslyWrite(to:ofType:for:)`).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with zero warnings, every test passes with none skipped (including the updated 0001/0005/0008/0021/0024 tests and `ExternalZipToolTests`), UI tests ran, launch smoke passes.
- **Manual verification** (needs third-party apps or Finder):
  1. **Krita round trip (M3 exit, part 1).** In PaintDotMac, make an 800×600 image with four layers: "Background" (white), "Multiply 50%" (a red stroke, Multiply, opacity 128), "Hidden" (a blue stroke, hidden), "Reflect" (a green stroke, Reflect). Save it as `test.ora`. Open it in Krita (5.x): there are four layers, in the same order, with the same names; Multiply shows as Multiply at about 50% opacity; "Hidden" is hidden; Reflect shows as Normal (expected, FMT-E); the canvas looks like PaintDotMac's except for the Reflect layer's blending.
  2. **Krita round trip (part 2).** In Krita, change the "Multiply 50%" opacity to 25%, add a layer "Krita layer" with a stroke near the top-left corner partly off canvas, and a group containing one layer. Save as `.ora` (Krita's own writer). Open it in PaintDotMac: the layers are present (the group's layer is flattened into the list), the opacity is 64 (25%), "Krita layer" is cropped at the canvas edge, Reflect is now Normal (Krita wrote `svg:src-over`), and nothing crashes.
  3. **GIMP:** open `test.ora` in GIMP 2.10/3.x → four layers with the same names and order.
  4. **Finder:** `test.ora` shows Kind "OpenRaster image" (when Krita isn't overriding it). Double-clicking opens it in PaintDotMac when PaintDotMac is chosen as the default app via Get Info → Open with.
  5. **Archive Utility / `unzip -l test.ora`** lists `mimetype` first and `Thumbnails/thumbnail.png`. The thumbnail opened in Preview shows the image at ≤ 256 px.

## Open questions

These are user-facing decisions that PRD §12 doesn't settle. The spec already applies the recommended answer to each, so it is implementable as written. Confirm or change each one.

1. **Non-integer DPI on save.** OpenRaster defines `xres`/`yres` as `xsd:int`, so 72.5 DPI can't be stored exactly. **Recommendation (applied): write the DPI rounded to the nearest integer (minimum 1)**, keeping the file valid for Krita/GIMP. On read, decimals are still accepted. (The layer PNGs carry the exact pHYs, but they aren't used for the document DPI.)
2. **Nested stacks (layer groups) on import.** PaintDotMac has no groups. **Recommendation (applied): flatten groups into plain layers.** Each child keeps its own blend mode, its opacity is multiplied by the group's opacities, a hidden group hides its children, and the group's own blend mode/isolation is ignored. The alternatives (composite each group into one layer, or refuse the file) either lose editability or block Krita users.
3. **A layer whose PNG is missing or undecodable.** **Recommendation (applied): refuse the whole file** with "The image is damaged or incomplete." The alternative is to open with that layer empty and warn. Refusing is safer, because re-saving a silently emptied layer would lose data.

Settled (stated as decisions in the body): default DPI 96 when `xres`/`yres` are missing (PRD APP-5 / D-7); UTI `org.openraster.ora` (matches Krita); `selected="true"` on the active layer, topmost `selected` wins on read; 0028 uses `NSDocument`'s built-in format popup and 0029 replaces it.

## Out of scope

- Crash-recovery autosave as `.ora` (`autosavingFileType`) → 0047. Background (asynchronous) saving and save progress → 0048 if the measured save time warrants it.
- Flatten-on-export to flat formats and the FMT-A confirmation (multi-layer PNG save still throws `.layeredImageNeedsFlatten`) → 0029. JPEG/HEIC/TIFF/BMP/GIF writing → 0029.
- Opening `.ora` by drag and drop onto the Dock/app, and Import From File as a layer → 0030.
- `composite-op` names for L-4 modes (`svg:hard-light`, `svg:soft-light`, `svg:color`, `svg:luminosity`, `svg:hue`, `svg:saturation`) → 0059 (the exhaustive switch forces it).
- Real layer groups, text layers, isolation semantics, `svg:dst-in`/`dst-out`/`src-atop`/`dst-atop` compositing (PRD §2.2 non-goals / not in L-3).
- Writing cropped layer PNGs with `x`/`y` offsets (every layer is written at full canvas size), 16-bit PNG output, writing ZIP64, reading ZIP64 or encrypted archives (FMT-E: refused).
- A Quick Look / Finder thumbnail extension for `.ora`, and a document icon → 0050 if wanted.
- Selections are not stored in `.ora` (OpenRaster has none; 0013 Out of scope).
