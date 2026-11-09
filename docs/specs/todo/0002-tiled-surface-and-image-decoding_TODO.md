# 0002 — Add the sparse tiled RGBA8 surface, layer model, and ImageIO decoding

> Source: PRD.md NF-9 (8-bit straight sRGB RGBA working space), Q-2 resolved in §10 (a `PixelFormat` abstraction with RGBA8 only), NF-4 (256×256 tiled storage), APP-10 (image limits, sparse tiles), FMT-B (ICC conversion, untagged = sRGB, EXIF orientation applied on open, color under alpha 0 preserved for straight-alpha sources, CMYK/gray/16-bit/float → 8-bit sRGB RGBA, no warning), FMT-D (animated GIF/WebP open as the first frame), APP-5 (per-document DPI from the file, default 96), §7 (Core model: Document → [Layer] → TiledSurface), §12 D-2, D-7, D-8, D-24, D-32, D-33. AGENTS.md *Architecture rules* 1, 3, 4.
> Milestone: M0
> Depends on: 0001-project-and-document-shell

## Context

There is no application code yet. Spec 0001 creates the project (`project.yml`), the AppKit document app, `PaintDotMac/Document/PaintDocument.swift` (an `NSDocument` subclass that reads PNG and JPEG), `PaintDotMac/Document/DocumentWindowController.swift`, a temporary `PaintDotMac/Canvas/PlaceholderImageView.swift` (accessibility identifier `canvas`), `PaintDotMac/App/LaunchOptions.swift` (the `#if DEBUG` hooks `-UITestOpen <path>`, `-ApplePersistenceIgnoreState YES`, and `-UITestResetDefaults`), and `PaintDotMacUITests/Support/UITestApp.swift`. In 0001 the document holds whatever ImageIO hands back (a `CGImage`) and the placeholder view shows it.

This spec adds the pixel model that every later spec builds on, plus the decoder that fills it:

- **Pixel format (NF-9, Q-2):** pixels are 8 bits per channel, sRGB, **straight** (non-premultiplied) RGBA. Premultiplication happens only inside the compositor (0012, 0024). The format is named by a `PixelFormat` type so 16-bit or P3 can be added later, but v1 has exactly one case and no other code paths.
- **Tiles (NF-4, AGENTS rule 3):** a `TiledSurface` stores pixels in 256×256 tiles. Tiles are **sparse**: a fully transparent tile is not allocated (APP-10). Tiles are **copy-on-write**, so copying a surface is cheap and a mutation copies only the tiles it touches. That is what 0008's `TileDiff` (per-tile before/after), 0003's per-tile texture upload, 0012's `CPUCompositor`, and 0013's `SelectionMask` rely on.
- **Image limits (APP-10):** each side must be 1–65,535 px. An image whose width × height × 4 overflows, or exceeds an injectable memory cap, is refused with an alert, never a crash.
- **Decoding (FMT-B, FMT-D, APP-5):** ImageIO + Accelerate (vImage) decode any ImageIO-readable file into straight sRGB RGBA8: embedded ICC profiles are honoured, untagged images are treated as sRGB, CMYK, grayscale, 16-bit, and float images are converted without a warning, animated images give their first frame, and the DPI comes from the file (default 96). Corrupt or truncated files throw an error that the document turns into an alert.

The decoder's ImageIO behavior was checked on this Mac (macOS 26, 2026-11-04) while writing this spec. The implementer must not rely on anything else:
- ImageIO decodes a **truncated PNG** without reporting an error (status `complete`, the missing rows come back blank or garbage). PNG completeness therefore needs our own chunk walk (see `ImageDecoder.pngChunksAreComplete`).
- For a **truncated JPEG** (baseline or progressive), `CGImageSourceCreateImageAtIndex(…, [kCGImageSourceShouldCacheImmediately: true])` still returns an image, but `CGImageSourceGetStatusAtIndex(source, 0)` then reports `.statusUnexpectedEOF` (−5). A complete JPEG reports `.statusComplete`.
- A PNG with damaged IDAT data, or one with only the signature and IHDR, makes `CGImageSourceCreateImageAtIndex` return `nil`. Random bytes and empty data give a source with `CGImageSourceGetCount == 0`.
- ImageIO tags untagged PNGs and JPEGs with `kCGColorSpaceSRGB`, so "untagged = sRGB" comes for free on the CGImage path.
- `vImageBuffer_InitWithCGImage` with a destination format of 8 bpc / 32 bpp / sRGB / `CGImageAlphaInfo.last` converts exactly for 8-bit straight sRGB input, and converts 16-bit (`0x1234 → 18`), float (`0.5 → 128`), gray, CMYK, Display P3, and premultiplied input. Animated GIFs report `CGImageSourceGetCount == 2` and index 0 is the first frame.
- `kCGImagePropertyDPIWidth`/`DPIHeight` round-trip through PNG (pHYs) and JPEG. A PNG without pHYs has no DPI keys. `kCGImagePropertyOrientation` round-trips through PNG and JPEG.

## User story

As a PaintDotMac user, I can open any PNG or JPEG, including transparent PNGs, 16-bit and grayscale PNGs, CMYK JPEGs, wide-gamut (Display P3) images, and phone photos with an EXIF rotation, and see it with the right colors, the right way up, and at the right size. A damaged file, or one too large to edit, shows a clear alert instead of crashing the app.

## Scope & changes

All paths are relative to `/Users/raphael/Projects/CSharp/Paint.NetMac`. `Core/` means `PaintDotMac/Core/`. Every `Core` file imports only the frameworks allowed by AGENTS.md rule 1 (here: `Foundation`, `CoreGraphics`, `ImageIO`, `Accelerate`, `UniformTypeIdentifiers`), never AppKit. All `Core` types in this spec are value types (or enums), `Sendable`, and nonisolated, so they can be used from any thread. Visibility: the app is a single module that the tests use through `@testable import PaintDotMac`, so the default `internal` access is fine everywhere. "Public API" below means the API that later specs may call.

### Core — geometry and color (pure, unit-tested)

- **`Core/Model/PixelSize.swift`** — three small integer geometry types (`Hashable`, `Sendable`, `CustomStringConvertible`):
  - `struct PixelPoint { var x: Int; var y: Int }`, `static let zero`.
  - `struct PixelSize { var width: Int; var height: Int }`. `init(width:height:)` has `precondition(width >= 0 && height >= 0)`. `var bounds: PixelRect` (origin 0,0). `var isEmpty: Bool` (either side 0). `description` is `"\(width) × \(height)"` (U+00D7, spaces on both sides).
  - `struct PixelRect { var x: Int; var y: Int; var width: Int; var height: Int }`, half-open: it covers columns `x..<x+width` and rows `y..<y+height`. `init(x:y:width:height:)` has `precondition(width >= 0 && height >= 0)`. `init(origin: PixelPoint, size: PixelSize)`. `static let zero`. `minX`, `minY`, `maxX` (= `x + width`, exclusive), `maxY` (exclusive), `size`, `origin`, `isEmpty` (width or height 0), `contains(_ point: PixelPoint) -> Bool`, `contains(_ rect: PixelRect) -> Bool` (an empty `rect` is contained in any rect), `intersection(_ other: PixelRect) -> PixelRect` (returns `.zero` when they don't overlap, including when they only touch at an edge), `union(_ other: PixelRect) -> PixelRect` (the smallest rect covering both; an empty operand is ignored; both empty → `.zero`), `offsetBy(dx:dy:) -> PixelRect`.
- **`Core/Model/ColorRGBA8.swift`** — `struct ColorRGBA8: Hashable, Sendable { var red: UInt8; var green: UInt8; var blue: UInt8; var alpha: UInt8 }`, always straight alpha.
  - `init(red:green:blue:alpha: UInt8 = 255)`.
  - `static let clear = (0,0,0,0)`, `black = (0,0,0,255)`, `white = (255,255,255,255)`.
  - `var isTransparent: Bool { alpha == 0 }`.
  - `static func unpremultiply(_ component: UInt8, alpha: UInt8) -> UInt8` — **the one rounding rule for un-premultiplying in the whole app:** `alpha == 0 → 0`, otherwise `min(255, (Int(component) * 255 + Int(alpha) / 2) / Int(alpha))` in integer arithmetic, which is round-half-up of `c × 255 / a`, clamped (a premultiplied component larger than its alpha is invalid input and clamps to 255). Example: `unpremultiply(50, alpha: 100) == 128` (127.5 rounds up), `unpremultiply(25, alpha: 100) == 64` (63.75).
  - `func unpremultiplied() -> ColorRGBA8` — treats `self` as premultiplied and applies `unpremultiply` to each color channel. An `alpha == 0` input gives `.clear`.
- **`Core/Model/PixelFormat.swift`** — the Q-2 abstraction:
  ```swift
  enum PixelFormat: Hashable, Sendable {
      /// 8 bits per channel, R G B A byte order, sRGB, straight (non-premultiplied) alpha. NF-9.
      case rgba8
      var bytesPerPixel: Int { 4 }
      var isPremultiplied: Bool { false }
      var colorSpaceName: CFString { CGColorSpace.sRGB }
      /// `CGBitmapInfo` for a CGImage that holds this format: `CGImageAlphaInfo.last`, default byte order.
      var cgBitmapInfo: CGBitmapInfo
  }
  ```
  Every byte-size calculation in this spec (`ImageLimits`, `Tile`, `TiledSurface`) goes through `bytesPerPixel`. There are no 16-bit or P3 cases or code paths (Q-2).
- **`Core/Model/BlendMode.swift`** — `enum BlendMode: String, CaseIterable, Codable, Sendable { case normal }` with `var displayName: String` (`"Normal"`). The raw value is the Metal function name (AGENTS.md *Code style*). Specs 0026, 0027, and 0059 add cases.

### Core — limits (pure, unit-tested)

- **`Core/Model/ImageLimits.swift`**:
  ```swift
  enum ImageLimitError: Error, Equatable, Sendable {
      case dimensionsOutOfRange(width: Int, height: Int)   // a side < 1 or > 65,535
      case byteCountOverflow(width: Int, height: Int)      // width × height × bytesPerPixel overflows Int
      case exceedsMemoryCap(requiredBytes: Int, capBytes: Int)
  }

  struct ImageLimits: Equatable, Sendable {
      static let minimumSide = 1
      static let maximumSide = 65_535                    // Paint.NET's limit (APP-10)
      var memoryCapBytes: Int                            // injectable; compared with width × height × 4
      init(memoryCapBytes: Int)
      /// The limits the app uses: `defaultMemoryCap(physicalMemory: ProcessInfo.processInfo.physicalMemory)`.
      static var standard: ImageLimits { get }
      /// physicalMemory / 4, clamped to Int.max (PRD APP-10, D-32). Decoding briefly holds about three copies
      /// of the pixels (ImageIO's cache, the vImage buffer, the tiles), so a quarter of RAM keeps the peak below
      /// physical memory. Not exposed in Settings (0046).
      static func defaultMemoryCap(physicalMemory: UInt64) -> Int
      /// width × height × bytesPerPixel with overflow checks (`multipliedReportingOverflow`); nil when it
      /// overflows or any factor is negative.
      static func byteCount(width: Int, height: Int, bytesPerPixel: Int) -> Int?
      /// Checks in this order and throws the first failure:
      /// 1. both sides in minimumSide...maximumSide, else .dimensionsOutOfRange;
      /// 2. byteCount(...) != nil, else .byteCountOverflow;
      /// 3. byteCount <= memoryCapBytes (equal is allowed), else .exceedsMemoryCap.
      /// Returns the byte count.
      @discardableResult
      func validate(width: Int, height: Int, format: PixelFormat = .rgba8) throws(ImageLimitError) -> Int
  }
  ```
  Step 2 can't fail on a 64-bit Mac once step 1 passes (65,535² × 4 ≈ 1.7 × 10¹⁰), but the checked arithmetic is still required and `byteCount` is tested directly with overflowing inputs. `validate` takes raw `Int`s because it runs on header values before any `PixelSize` exists. Specs 0005 (New Image), 0021 (paste), and 0035/0036 (resize) call the same `validate`.

### Core — tiles, surface, layers (pure, unit-tested)

- **`Core/Model/TiledSurface.swift`** — `Tile`, `TileCoordinate`, and `TiledSurface`.
  - `struct TileCoordinate: Hashable, Comparable, Sendable { var column: Int; var row: Int }`. `<` is row-major (row first, then column).
  - `struct Tile: Equatable, Sendable` — one 256×256 RGBA8 tile.
    - `static let size = 256`, `static let bytesPerRow = 256 * PixelFormat.rgba8.bytesPerPixel` (1,024), `static let byteCount = 256 * bytesPerRow` (262,144).
    - Storage: `private(set) var bytes: [UInt8]` of exactly `byteCount` bytes, row-major, R G B A per pixel. Swift's array copy-on-write is the tile's copy-on-write: copying a `Tile` shares the buffer until one copy is mutated.
    - `init()` (all zero), `init(filledWith color: ColorRGBA8)`, `init(bytes: [UInt8])` (`precondition(bytes.count == byteCount)`).
    - `func pixel(x: Int, y: Int) -> ColorRGBA8` and `mutating func setPixel(_ color: ColorRGBA8, x: Int, y: Int)`, both with `precondition` that `x`, `y` are in `0..<256` (tile-local coordinates).
    - `var isFullyTransparent: Bool` — every byte is 0. (Scan 8 bytes at a time, as `UInt64`.)
    - `func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R` and `mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R`.
    - `func sharesStorage(with other: Tile) -> Bool` — true when both use the same buffer (compare base addresses). Used by tests and by 0008 to prove that diffs share memory.
  - `struct TiledSurface: Equatable, Sendable`:
    - `let size: PixelSize`, `let format: PixelFormat` (always `.rgba8`), `var bounds: PixelRect`.
    - `static let tileSize = Tile.size` (256).
    - `let tileColumns: Int` (= ⌈width / 256⌉), `let tileRows: Int` (= ⌈height / 256⌉), `var tileCount: Int`.
    - Storage: `private var tiles: [Tile?]`, row-major, `tileColumns × tileRows` entries; `nil` means fully transparent. `private var tileGenerations: [UInt64]` (same count).
    - **Invariant (edge tiles):** tiles on the right and bottom edges are full 256×256 tiles, and their pixels outside `bounds` are always `(0,0,0,0)`. No API ever writes outside `bounds`. (This keeps every tile the same size for 0003's texture upload and 0008's diffs.)
    - `init(size: PixelSize, format: PixelFormat = .rgba8)` — `precondition` that both sides are in `ImageLimits.minimumSide...ImageLimits.maximumSide`. No tiles are allocated. Callers validate user-supplied sizes with `ImageLimits.validate` first; the precondition only catches programmer errors.
    - `init(size: PixelSize, rgba8 source: UnsafeRawBufferPointer, bytesPerRow: Int)` — bulk import from a tightly or loosely packed straight RGBA8 buffer (`bytesPerRow >= width × 4`, `source.count >= bytesPerRow × (height − 1) + width × 4`, both `precondition`s). It copies row segments with `memcpy`/`copyMemory` (not per pixel, so it stays fast in Debug builds) and **does not allocate any tile whose pixels are all zero**. Used by the decoder and later by 0021's clipboard codec.
    - `func pixelRect(of tile: TileCoordinate) -> PixelRect` — the tile's rectangle clipped to `bounds`.
    - `func tileCoordinate(containing point: PixelPoint) -> TileCoordinate` (`precondition(bounds.contains(point))`).
    - `func tileCoordinates(intersecting rect: PixelRect) -> [TileCoordinate]` — row-major; `rect` is clipped to `bounds` first; empty result for an empty or fully out-of-bounds rect.
    - `func tile(at coordinate: TileCoordinate) -> Tile?` and `mutating func setTile(_ tile: Tile?, at coordinate: TileCoordinate)` (`precondition` that the coordinate is in the grid). `setTile` is the low-level hook for 0008 (undo/redo restores whole tiles). It stamps the tile as changed (see generations). In Debug builds it `assert`s the edge-tile invariant for the tile it receives.
    - `var allocatedTileCoordinates: [TileCoordinate]` (row-major) and `var allocatedTileCount: Int`.
    - `func pixel(at point: PixelPoint) -> ColorRGBA8` — `.clear` for an unallocated tile **and for any point outside `bounds`** (no trap).
    - `mutating func setPixel(_ color: ColorRGBA8, at point: PixelPoint)` — a no-op outside `bounds`. Writing a color with **all four bytes zero** into an unallocated tile is a no-op (no allocation, no generation stamp). Any other write allocates the tile if needed.
    - `func readPixels(in rect: PixelRect) -> [UInt8]` — `rect.width × rect.height × 4` bytes, row-major, tightly packed. Pixels outside `bounds` and in unallocated tiles read as zero.
    - `func readPixels(in rect: PixelRect, into destination: UnsafeMutableRawBufferPointer, bytesPerRow: Int)` — same, into a caller buffer (`precondition` on its size).
    - `mutating func writePixels(_ source: UnsafeRawBufferPointer, bytesPerRow: Int, to rect: PixelRect)` and the convenience `mutating func writePixels(_ bytes: [UInt8], to rect: PixelRect)` (tightly packed, `precondition(bytes.count == rect.width * rect.height * 4)`). Source row `r`, column `c` lands at `(rect.x + c, rect.y + r)`. The parts of `rect` outside `bounds` are **clipped** (silently skipped). For each touched unallocated tile, if the bytes destined for that tile are all zero the tile stays unallocated.
    - `mutating func fill(_ color: ColorRGBA8, in rect: PixelRect? = nil)` — `nil` means `bounds`; clipped to `bounds`. Filling with an all-zero color sets every **fully covered** tile to `nil` (releases it) and zeroes partly covered allocated tiles, without allocating anything. Filling with any other color: every tile whose in-bounds area is fully covered is set to **one shared `Tile` value** (interior tiles share storage until written; edge tiles get their own tile whose out-of-bounds pixels stay zero); partly covered tiles are written pixel by pixel. 0005's New Image ("one opaque white layer") uses this.
    - `mutating func releaseTransparentTiles()` — sets every allocated tile whose `isFullyTransparent` is true to `nil` and stamps it as changed. Writes never free tiles on their own; operations that may clear large areas (0018 Erase Selection, 0008 after a diff) call this.
    - **Change tracking (generations):** `private(set) var generation: UInt64`, starting at 0. Every mutating call that touches at least one tile increments `generation` by exactly 1 and sets the touched tiles' generation to the new value. A call that touches nothing (fully clipped, or a zero write into unallocated tiles) leaves `generation` unchanged. "Touched" means written or replaced, even if the bytes happen to be the same. `func changedTiles(since generation: UInt64) -> [TileCoordinate]` returns, row-major, every tile whose generation is greater than the argument. Consumers (0003's renderer, 0025's thumbnails) remember the `generation` they last saw and ask for the tiles changed since. Copies of a surface carry their generations with them.
    - **`==`** (custom, not synthesized): equal `size` and equal pixels, where an unallocated tile equals an allocated all-zero tile. Generations are ignored.
    - `func makeCGImage() -> CGImage?` — a straight-alpha sRGB CGImage (8 bpc, 32 bpp, `format.cgBitmapInfo`, `CGColorSpace(name: format.colorSpaceName)`) of the whole surface, built from `readPixels(in: bounds)`. Returns `nil` only if `CGImage(...)` fails. 0001's placeholder view and 0005's PNG encoder use it until 0012's compositor exists.
    - **Copy-on-write discipline (performance):** mutate tiles in place through the array (`tiles[i]!.withUnsafeMutableBytes { … }` on an index known to be allocated — each such `!` carries a comment, per AGENTS.md *Code style*; or use a `switch`/`if case` that assigns back only once per call). Never copy a tile out into a local, mutate it, and store it back for each pixel: that would duplicate 256 KB per write when the storage is shared.
- **`Core/Model/Layer.swift`**:
  ```swift
  struct Layer: Identifiable, Equatable, Sendable {
      let id: UUID
      var name: String
      var isVisible: Bool
      var opacity: UInt8            // 0–255, as in Paint.NET (L-2)
      var blendMode: BlendMode
      var surface: TiledSurface
      init(id: UUID = UUID(), name: String, surface: TiledSurface,
           isVisible: Bool = true, opacity: UInt8 = 255, blendMode: BlendMode = .normal)
      var size: PixelSize { surface.size }
  }
  ```
  `==` compares every property, including pixels (through `TiledSurface.==`).
- **`Core/Model/LayeredImage.swift`**:
  ```swift
  struct LayeredImage: Equatable, Sendable {
      static let defaultDPI: Double = 96                   // Paint.NET's default (APP-5)
      static let defaultLayerName = "Background"          // Paint.NET's name for an opened/new image's layer
      var size: PixelSize
      var dpi: Double                                      // finite and > 0
      var layers: [Layer]                                  // index 0 = bottom, last = top (Paint.NET order)
      var activeLayerIndex: Int
      init(size: PixelSize, dpi: Double = defaultDPI, layers: [Layer], activeLayerIndex: Int)
      init(surface: TiledSurface, dpi: Double = defaultDPI, layerName: String = defaultLayerName)
      static func blank(size: PixelSize, dpi: Double = defaultDPI, fill: ColorRGBA8,
                        layerName: String = defaultLayerName) -> LayeredImage
      var activeLayer: Layer { get set }
      /// True when layers is non-empty, every layer's surface size equals `size`, layer ids are unique,
      /// activeLayerIndex is a valid index, and dpi is finite and > 0.
      var isConsistent: Bool { get }
      static func isValidDPI(_ dpi: Double) -> Bool        // finite && > 0
  }
  ```
  The designated `init` has `precondition(isConsistent)` (programmer error). `init(surface:…)` makes one visible, opacity 255, Normal layer and sets `activeLayerIndex = 0`. `blank` makes a surface of `size` filled with `fill` (through `TiledSurface.fill`). Later specs that mutate `layers`/`size` (0024 layer ops, 0035/0036 resize) keep `isConsistent` true and test it. Compositing several layers is 0012/0024's job, not this type's.

### Core — decoding (pure, unit-tested)

- **`Core/IO/ImageCodecError.swift`**:
  ```swift
  enum ImageCodecError: Error, Equatable, Sendable, LocalizedError {
      case unrecognizedFormat              // ImageIO can't identify the data, or it holds no image
      case corrupt                         // damaged, truncated, or undecodable
      case limitExceeded(ImageLimitError)  // APP-10
      var errorDescription: String? { get }
      var recoverySuggestion: String? { get }
  }
  ```
  Exact strings (typographic apostrophes U+2019 and multiplication sign U+00D7; numbers formatted by a `NumberFormatter` with `locale = Locale(identifier: "en_US")` and `numberStyle = .decimal`, so 65535 is "65,535" on every machine whatever its region settings):

  | Case | `errorDescription` | `recoverySuggestion` |
  |---|---|---|
  | `.unrecognizedFormat` | `The file isn’t a supported image.` | `nil` |
  | `.corrupt` | `The image is damaged or incomplete.` | `The file may be truncated or corrupted.` |
  | `.limitExceeded(.dimensionsOutOfRange(w, h))` with both sides ≥ 1 | `The image is too large.` | `Images can be up to 65,535 × 65,535 pixels. This one is <w> × <h> pixels.` |
  | `.limitExceeded(.dimensionsOutOfRange(w, h))` with a side < 1 | `The image has no pixels.` | `nil` |
  | `.limitExceeded(.byteCountOverflow(w, h))` | `The image is too large.` | `An image of <w> × <h> pixels can’t be held in memory.` |
  | `.limitExceeded(.exceedsMemoryCap(r, c))` | `The image is too large.` | `Opening it needs <r> of memory, but the limit is <c>.` where `<r>`/`<c>` come from `ByteCountFormatter.string(fromByteCount:countStyle: .memory)` |

  The `exceedsMemoryCap` wording says "Opening" because 0002 only opens; 0005/0021/0035 may add a context-specific wording when they reuse the error and are free to rephrase this row.
- **`Core/IO/ImageOrientation.swift`** — `enum ImageOrientation: Int, Sendable { case up = 1, upMirrored = 2, down = 3, downMirrored = 4, leftMirrored = 5, right = 6, rightMirrored = 7, left = 8 }` (EXIF/TIFF values, same as `CGImagePropertyOrientation`).
  - `init(exifValue: Int?)` — `nil` or any value outside 1…8 gives `.up`.
  - `var swapsDimensions: Bool` — true for 5–8.
  - `func orientedSize(_ size: PixelSize) -> PixelSize`.
  - `func sourcePoint(forDestination point: PixelPoint, sourceSize: PixelSize) -> PixelPoint` — the reference mapping (w, h = source size): 1 `(x, y)`; 2 `(w−1−x, y)`; 3 `(w−1−x, h−1−y)`; 4 `(x, h−1−y)`; 5 `(y, x)`; 6 `(y, h−1−x)`; 7 `(w−1−y, h−1−x)`; 8 `(w−1−y, x)`.
  - An `apply` function that reorients a tightly packed RGBA8 buffer of a given size and returns the new buffer and size (exact signature is the implementer's choice). Implement it with vImage (`vImageRotate90_ARGB8888`, `vImageHorizontalReflect_ARGB8888`, `vImageVerticalReflect_ARGB8888`; the ARGB8888 functions only move 4-byte pixels, so they work for RGBA) so that it is fast in Debug builds. It must produce exactly the pixels that `sourcePoint` defines (tested against it). The orientation is applied to the pixels and the size on open and is never written back on save, so saved files are upright with orientation 1 (PRD FMT-B, D-33).
- **`Core/IO/ImageDecoder.swift`**:
  ```swift
  struct DecodedImage: Equatable, Sendable {
      var surface: TiledSurface
      var dpi: Double            // always valid (LayeredImage.isValidDPI)
  }

  enum ImageDecoder {
      /// Decodes the first image in `data` into a single-layer LayeredImage named "Background".
      static func decodeImage(from data: Data, limits: ImageLimits = .standard) throws(ImageCodecError) -> LayeredImage
      /// Same pipeline, returning the surface and DPI (0021 clipboard, 0030 Import from File reuse it).
      static func decode(_ data: Data, limits: ImageLimits = .standard) throws(ImageCodecError) -> DecodedImage
      /// Converts an already-decoded CGImage (no orientation, DPI 96). Same conversion paths and limit check.
      static func surface(from image: CGImage, limits: ImageLimits = .standard) throws(ImageCodecError) -> TiledSurface
      /// PNG integrity check; see step 4.
      static func pngChunksAreComplete(_ data: Data) -> Bool
      /// DPI rule; see step 7.
      static func resolvedDPI(properties: [CFString: Any], orientation: ImageOrientation) -> Double
  }
  ```
  `decode` runs these steps, in this order:
  1. `CGImageSourceCreateWithData(data, [kCGImageSourceShouldCache: false])`. If it is `nil`, `CGImageSourceGetType` is `nil`, or `CGImageSourceGetCount == 0` → `.unrecognizedFormat`.
  2. Read `CGImageSourceCopyPropertiesAtIndex(source, 0, nil)`. Missing or non-integer `kCGImagePropertyPixelWidth`/`PixelHeight` → `.corrupt`. Read `kCGImagePropertyOrientation` into `ImageOrientation(exifValue:)`.
  3. `limits.validate(width:height:)` on the **oriented** size, **before** any pixel memory is allocated. A failure → `.limitExceeded(error)`.
  4. If the source type conforms to `UTType.png`: `pngChunksAreComplete(data)` must be true, else `.corrupt`. The check: the 8-byte PNG signature, then a walk over chunks (4-byte big-endian length ≤ 2³¹−1, 4-byte type, `length` data bytes, 4-byte CRC; CRCs are not verified) that must reach an `IEND` chunk with all of its bytes present. Bytes after `IEND` are ignored. (ImageIO silently decodes truncated PNGs; see Context.)
  5. `CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true])` (index 0 = the first frame of an animated GIF/WebP, FMT-D). `nil` → `.corrupt`. If its `width`/`height` differ from the properties → `.corrupt`.
  6. Convert to straight sRGB RGBA8 (the **conversion paths**, the same in `surface(from:)`):
     - **Path P (premultiplied 8-bit sRGB):** when `bitsPerComponent == 8`, the color space model is RGB, the color space name is `kCGColorSpaceSRGB`, and `alphaInfo` is `.premultipliedLast` or `.premultipliedFirst`: convert with `vImageBuffer_InitWithCGImage` to 8 bpc / 32 bpp / sRGB / **`.premultipliedLast`** (a pure byte reorder, no rounding), then un-premultiply every pixel with `ColorRGBA8.unpremultiply`. This makes the rounding exactly the documented rule.
     - **Path S (everything else):** `vImageBuffer_InitWithCGImage` to 8 bpc / 32 bpp / sRGB / **`.last`** (straight), default byte order, `renderingIntent .defaultIntent`. vImage performs the ICC/ColorSync conversion (embedded profiles, Display P3, CMYK, gray, linear gray), the bit-depth reduction (16-bit, float), palette expansion, and any un-premultiplication of non-sRGB sources. Images without alpha come out with alpha 255.
     - Any vImage error → `.corrupt`. The vImage buffer is freed on every path (`defer { free(buffer.data) }`).
  7. `CGImageSourceGetStatusAtIndex(source, 0)` after the pixels were decoded must be `.statusComplete`, else `.corrupt` (catches truncated JPEGs; see Context).
  8. **Transparent pixels (PRD FMT-B, D-33):** the color stored under a pixel with alpha 0 is **preserved** when the source has straight alpha (`alphaInfo` `.last`, `.first`, or no alpha), so a straight PNG pixel `(10,20,30,0)` decodes to `(10,20,30,0)`. Premultiplied sources carry no color under alpha 0: on Path P `ColorRGBA8.unpremultiply` already yields `(0,0,0,0)`; on Path S, when the source `alphaInfo` is `.premultipliedLast` or `.premultipliedFirst`, every pixel with alpha 0 is set to `(0,0,0,0)` after conversion (scan as `UInt32` words), so the result doesn't depend on what vImage leaves there. Straight sources skip the scan. Fully transparent pixels stored as `(0,0,0,0)` still leave their tiles unallocated (step 10); alpha-0 pixels with a non-zero color allocate their tile, which is the price of preserving them.
  9. Apply the orientation (step 2) with `ImageOrientation`.
  10. Build the `TiledSurface` with `init(size:rgba8:bytesPerRow:)` (zero tiles stay unallocated), then release the intermediate buffers before returning.
  11. DPI (`resolvedDPI`): take `kCGImagePropertyDPIWidth` and `kCGImagePropertyDPIHeight` as `Double`s; for orientations 5–8 swap them (the displayed horizontal axis was the stored vertical one). Use the horizontal value if `LayeredImage.isValidDPI`, else the vertical one if valid, else `LayeredImage.defaultDPI` (96). No rounding (72.5 stays 72.5). Non-square resolutions collapse to the horizontal value because a document has one DPI (APP-5, decision 10).

  The decoder never logs to the console, never asserts on input data, and never traps on any byte sequence.

### Platform glue (Document/App/Canvas — covered by integration and UI tests)

- **`PaintDotMac/Document/PaintDocument.swift`** (0001): replace 0001's `private(set) var image: CGImage?` and `imagePixelSize` with `private(set) var image: LayeredImage` (`DocumentWindowController.init(image:)` takes the document's `LayeredImage`). A document that hasn't read anything yet holds `LayeredImage.blank(size: PixelSize(width: 1, height: 1), fill: .clear)` until 0005 adds New Image. `read(from data: Data, ofType typeName: String)` keeps 0001's unknown-type check (`CocoaError(.fileReadUnknown)`), then does `image = try ImageDecoder.decodeImage(from: data, limits: Self.imageLimits)`; the content is sniffed, not taken from `typeName`, so a JPEG named `.png` still opens. `ImageCodecError` propagates unchanged as the thrown error, so `NSDocumentController` shows its standard "couldn't be opened" alert with our `errorDescription` and `recoverySuggestion`. `static var imageLimits: ImageLimits` (nonisolated, computed): `ImageLimits(memoryCapBytes: cap)` when the Debug launch option below is present, else `ImageLimits.standard`. `canConcurrentlyReadDocuments` stays `false` (0001), so reading happens on the main thread; `LayeredImage` is `Sendable`, so a later switch to background reads stays safe.
- **`PaintDotMac/App/LaunchOptions.swift`** (0001): add `memoryCapBytes: Int?`, parsed from `-UITestMemoryCapBytes <decimal>` in `#if DEBUG` builds only (always `nil` in Release; a missing, non-numeric, or ≤ 0 value gives `nil`). It exists so a UI test can trigger the APP-10 alert with a small fixture.
- **Opening failures from `-UITestOpen`:** 0001's hook already presents a non-nil open error with `NSApp.presentError(_:)` (the same alert as File > Open); `ImageCodecError` flows through it unchanged. The app stays running with no document window afterwards.
- **`PaintDotMac/Document/DocumentWindowController.swift` and `PaintDotMac/Canvas/PlaceholderImageView.swift`** (0001; the placeholder is replaced in 0003): the placeholder now shows `document.image.activeLayer.surface.makeCGImage()` (a decoded file has exactly one layer, so this is the whole image until 0012/0024 composite layers). Set the placeholder's `accessibilityValue` to `image.size.description` (for example `"300 × 200"`), so UI tests can check the decoded size. 0003's `CanvasView` should keep that accessibility value (noted for 0003).

### Test support (test targets)

- **`PaintDotMacTests/Support/SeededRandom.swift`**:
  ```swift
  struct SeededRandom: RandomNumberGenerator, Sendable {
      let seed: UInt64
      init(seed: UInt64)
      mutating func next() -> UInt64          // SplitMix64, exactly as below
      /// "seed=0x2A — rerun with PAINTDOTMAC_TEST_SEED=0x2A"; pass it as the comment of every #expect in a property test.
      var comment: Comment { get }
      /// The default seed, unless the environment variable PAINTDOTMAC_TEST_SEED (decimal or 0x-hex) overrides it.
      static func resolvedSeed(default seed: UInt64) -> UInt64
      mutating func int(in range: ClosedRange<Int>) -> Int
      mutating func byte() -> UInt8
      mutating func color() -> ColorRGBA8
      /// A random rect that may extend past `size` on any side (for clipping tests), width/height 0...maxSide.
      mutating func rect(around size: PixelSize, maxSide: Int) -> PixelRect
  }
  ```
  SplitMix64: `state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31)`, with `state` initialized to `seed`. Every property test uses a fixed default seed (so runs are reproducible), calls `resolvedSeed(default:)`, and includes `rng.comment` in each `#expect`, so a failure prints the seed. (`xcodebuild` passes the override to tests as `TEST_RUNNER_PAINTDOTMAC_TEST_SEED=…`.)
- **`PaintDotMacTests/Support/TestImages.swift`** — synthetic fixtures and pixel assertions (CoreGraphics/ImageIO only; no binary fixture files are committed):
  - `static let sRGB: CGColorSpace`
  - `static func rgbaBytes(width: Int, height: Int, _ pixel: (Int, Int) -> ColorRGBA8) -> [UInt8]`
  - `static func surface(width: Int, height: Int, _ pixel: (Int, Int) -> ColorRGBA8) -> TiledSurface` (built with `init(size:rgba8:bytesPerRow:)`)
  - `static func cgImage(width: Int, height: Int, bitsPerComponent: Int = 8, bytes: [UInt8], colorSpace: CGColorSpace = sRGB, alphaInfo: CGImageAlphaInfo = .last, byteOrder: CGBitmapInfo = []) -> CGImage` (component count from the color space plus alpha; float formats pass `.floatComponents` in `byteOrder`)
  - `static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data` and `static func encodeFrames(_ frames: [CGImage], as type: UTType) -> Data` (CGImageDestination)
  - `static func pngHeaderOnly(width: UInt32, height: UInt32) -> Data` — the PNG signature, an IHDR chunk (8-bit RGBA) and an IEND chunk, with correct CRCs from a small test-local CRC-32 (IEEE, reflected polynomial 0xEDB88320). Used to test limits without allocating huge images.
  - `static func expectPixels(_ surface: TiledSurface, match expected: (Int, Int) -> ColorRGBA8, tolerance: Int = 0, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation)` — checks every pixel in `bounds`; records one issue listing the mismatch count and the first 10 mismatches as `(x, y): got … expected …`.
  - `static func expectColor(_ actual: ColorRGBA8, _ expected: ColorRGBA8, tolerance: Int = 0, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation)`
  - `static func temporaryFile(named: String, contents: Data) throws -> URL` (a fresh directory under `FileManager.default.temporaryDirectory`).
- **`PaintDotMacUITests/Support/UITestFixtures.swift`** — the UI test target can't see app types, so it writes its own fixtures with CoreGraphics/ImageIO: `static func writePNG(width:height:pixel:properties:) throws -> URL`, `static func writeJPEG(width:height:pixel:properties:) throws -> URL`, `static func writeTruncatedPNG() throws -> URL` (a valid 64×64 PNG cut to half its bytes). 0001's `UITestApp.makePNG`/`makeJPEG` write only solid colors without properties, so these writers live here; pass their URLs to `UITestApp.launch(opening:extraArguments:)`, which already accepts extra arguments such as `-UITestMemoryCapBytes`.

### Project

- `project.yml`: no change; 0001's targets use recursive folder sources. Run `xcodegen generate` after adding the files.
- No PRD.md or AGENTS.md change in this spec. The memory cap, EXIF orientation, and alpha-0 decisions are already in PRD APP-10 and FMT-B (D-32, D-33).

## Acceptance criteria

- [ ] `PixelFormat.rgba8` is the only pixel format; it is 4 bytes per pixel, straight, sRGB, and every byte-size calculation uses it. → `PixelFormatTests.rgba8Properties`
- [ ] `ColorRGBA8.unpremultiply` follows the documented round-half-up rule for all 65,536 inputs. → `ColorRGBA8Tests.unpremultiplyMatchesFormulaExhaustively`, `ColorRGBA8Tests.unpremultiplyExamples`
- [ ] `PixelRect` intersection, union, containment, and emptiness behave as specified, including edge-touching and empty rects. → `PixelGeometryTests.*`
- [ ] `ImageLimits` accepts sides 1–65,535 and a byte count equal to the cap, and refuses 0, negative, 65,536, overflowing products, and byte counts above the cap with the specified error and order. → `ImageLimitsTests.*`
- [ ] A new `TiledSurface` of any valid size allocates no tiles and reads `(0,0,0,0)` everywhere; tile grid sizes are ⌈w/256⌉ × ⌈h/256⌉. → `TiledSurfaceTests.newSurfaceIsEmptyAndSparse`, `TiledSurfaceTests.tileGridDimensions`
- [ ] Pixel and region reads/writes round-trip exactly, cross tile boundaries correctly, and clip at the canvas edge without trapping. → `TiledSurfaceTests.*`, `TiledSurfacePropertyTests.randomOperationsMatchFlatReference`
- [ ] Transparent writes never allocate tiles; `releaseTransparentTiles` frees all-zero tiles; filling shares one tile buffer among interior tiles. → `TiledSurfaceTests.transparentWritesDoNotAllocate`, `…releaseTransparentTilesFreesZeroTiles`, `…fillSharesInteriorTileStorage`
- [ ] Copying a surface is copy-on-write per tile: mutating the copy leaves the original unchanged and only copies the touched tile. → `TiledSurfaceTests.copyOnWriteIsPerTile`, `TiledSurfacePropertyTests.copiesAreIndependent`
- [ ] Every mutation bumps `generation` once and `changedTiles(since:)` returns exactly the touched tiles; no-op mutations don't bump it. → `TiledSurfaceTests.generationTracksTouchedTiles`, `…noOpWritesDoNotBumpGeneration`
- [ ] Edge tiles keep zero pixels outside the image bounds after every operation. → `TiledSurfacePropertyTests.edgeTilePaddingStaysZero`
- [ ] `LayeredImage` and `Layer` hold size, DPI, ordered layers, an active index, and layer properties; `isConsistent` detects every invalid state. → `LayeredImageTests.*`
- [ ] PNG (8-bit straight alpha) decodes to the exact stored bytes, including the color under alpha-0 pixels (FMT-B), and tiles that are entirely `(0,0,0,0)` are left unallocated. → `ImageDecoderTests.straightAlphaPNGDecodesExactly`, `…alphaZeroColorAllocatesItsTile`, `…transparentTilesStayUnallocated`, `TiledSurfacePropertyTests.pngRoundTrip`
- [ ] Premultiplied 8-bit sRGB input is un-premultiplied with the documented rounding, and its alpha-0 pixels decode to `(0,0,0,0)`. → `ImageDecoderTests.premultipliedTIFFUsesDocumentedRounding`
- [ ] ICC conversion: Display P3, linear gray, and CMYK are converted to sRGB; untagged images are treated as sRGB; gray, 16-bit, and float input becomes 8-bit RGBA. → `ImageDecoderTests.displayP3IsConvertedToSRGB`, `…grayscaleIsExpandedToRGBA`, `…linearGrayIsConvertedToSRGBTransfer`, `…cmykIsConvertedToRGB`, `…sixteenBitIsReducedToEightBit`, `…floatIsReducedToEightBit`, `…untaggedImageIsTreatedAsSRGB`
- [ ] Animated GIFs open as their first frame. → `ImageDecoderTests.animatedGIFUsesFirstFrame`
- [ ] DPI is read from the file (PNG pHYs and JPEG), defaults to 96 when missing or invalid, and follows the orientation swap rule. → `ImageDecoderTests.dpiIsReadFromPNG`, `…dpiIsReadFromJPEG`, `…missingDPIDefaultsTo96`, `ImageDecoderTests.resolvedDPIRules`
- [ ] EXIF orientations 1–8 are applied so the image opens upright (FMT-B, D-33). → `ImageOrientationTests.*`, `ImageDecoderTests.orientationIsAppliedToPixelsAndSize`
- [ ] Empty data, random bytes, a header-only PNG, a truncated PNG, a PNG with no IEND, a PNG with damaged IDAT, and a truncated JPEG (baseline and progressive) each throw the specified `ImageCodecError` and never trap; a valid PNG with trailing bytes still opens. → `ImageDecoderFailureTests.*`
- [ ] Images over 65,535 px on a side, or over the memory cap, are refused before pixel memory is allocated; exactly 65,535 px opens. → `ImageDecoderFailureTests.oversizedHeaderIsRefusedBeforeDecoding`, `…memoryCapIsEnforced`, `ImageDecoderTests.maximumWidthOpens`
- [ ] Error messages match the table. → `ImageCodecErrorTests.messages`
- [ ] `PaintDocument` reads PNG and JPEG data into a one-layer `LayeredImage` named "Background" with the file's DPI, and throws `ImageCodecError` for bad data. → `PaintDocumentLoadingTests.*`
- [ ] Opening a transparent PNG and a rotated JPEG in the app shows them at the decoded size. → `ImageDecodingUITests.opensTransparentPNGAtItsSize`, `ImageDecodingUITests.rotatedJPEGOpensUpright`
- [ ] Opening a truncated file, or an image above the memory cap, shows an alert and the app keeps running. → `ImageDecodingUITests.corruptFileShowsAlert`, `ImageDecodingUITests.imageAboveMemoryCapShowsAlert`
- [ ] Decoding a 24 MP JPEG stays well inside NF-2's 1 s open budget (gate: < 3 s in the Debug test run). → `ImageDecoderPerformanceTests.testDecode24MegapixelJPEG`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke.

## Edge cases

- **1×1 and non-multiple-of-256 sizes:** a 1×1 surface has one tile; a 257×1 surface has 2×1 tiles; a 65,535×1 surface has 256×1 tiles. Edge tiles keep their out-of-bounds padding zero.
- **Out-of-bounds access:** `pixel(at:)` returns `.clear`, `setPixel` is a no-op, region reads return zeros, region writes and fills are clipped. Rects with negative origins, rects larger than the surface, empty rects, and fully outside rects are all valid input and never trap. Only programmer errors (invalid tile coordinates passed to `tile(at:)`/`setTile`, malformed buffer sizes, invalid sizes in `TiledSurface.init`) hit a `precondition`.
- **Straight alpha:** a pixel `(10, 20, 30, 0)` is written as given by `setPixel` and read back unchanged; it is a non-zero write, so it allocates its tile. The decoder preserves such pixels from straight sources and zeroes them only for premultiplied sources (step 8). Semi-transparent pixels keep their exact straight color through read/write and decoding.
- **Overflow:** `ImageLimits.byteCount(width: Int.max, height: 2, bytesPerPixel: 4)` and `(width: 2, height: Int.max / 2 + 1, …)` return `nil`; negative factors return `nil`; `validate` never traps on any `Int` input, including `Int.min`.
- **Memory cap:** checked against the header before decoding; `byteCount == memoryCapBytes` is accepted. A 65,535 × 65,535 header with a 1 GiB cap gives `.exceedsMemoryCap(requiredBytes: 17_179_344_900, capBytes: 1_073_741_824)`.
- **Truncated or damaged files:** see the failure table in the test plan; each produces `.corrupt` or `.unrecognizedFormat`, and the document shows the alert. Trailing bytes after a PNG's IEND are accepted.
- **Animated images:** only frame 0 is decoded; no warning (FMT-D).
- **Color:** images without a profile are sRGB; out-of-gamut wide-gamut colors are clipped by ColorSync's default rendering intent (P3 pure red → about `(255, 0, 0)`); CMYK uses the embedded profile, or ImageIO's default CMYK profile when there is none.
- **DPI:** missing, zero, negative, NaN, or infinite values fall back to the other axis, then to 96. A 72 DPI JPEG reports 72 (that is the file's metadata).
- **Orientation:** values outside 1–8 (or missing) are treated as 1. For 5–8 the width and height swap, and the limits are checked on the swapped size.
- **Wrong extension:** a JPEG's bytes saved as `.png` decode as a JPEG (content sniffing); the document still opens.
- **Read before load:** a `PaintDocument` that hasn't read a file holds a 1×1 transparent image; no code path force-unwraps an image.
- **Threading:** all new Core types are `Sendable` values, and `ImageDecoder` has no shared mutable state, so concurrent decodes on different threads are safe.

## Test plan

Expected values come from hand calculation, the formulas above, or simple reference code in the test target, never from running the code under test.

- **Unit tests**
  - `PaintDotMacTests/Model/PixelFormatTests.swift`
    - `rgba8Properties`: `bytesPerPixel == 4`, `isPremultiplied == false`, `colorSpaceName == CGColorSpace.sRGB`, `cgBitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue == CGImageAlphaInfo.last.rawValue`.
  - `PaintDotMacTests/Model/ColorRGBA8Tests.swift`
    - `constants`: `.clear == (0,0,0,0)`, `.black == (0,0,0,255)`, `.white == (255,255,255,255)`; `ColorRGBA8(red: 1, green: 2, blue: 3).alpha == 255`.
    - `unpremultiplyExamples`: `(50, 100) → 128`, `(25, 100) → 64`, `(0, 0) → 0`, `(200, 0) → 0`, `(255, 255) → 255`, `(1, 1) → 255`, `(200, 100) → 255` (clamp), `(127, 255) → 127`, `(64, 128) → 128` (127.5 → 128).
    - `unpremultiplyMatchesFormulaExhaustively`: for every `c` and `a` in 0…255, compare with the Double oracle `a == 0 ? 0 : min(255, Int((Double(c) * 255 / Double(a) + 0.5).rounded(.down)))`.
    - `unpremultipliedColor`: `ColorRGBA8(red: 50, green: 25, blue: 0, alpha: 100).unpremultiplied() == (128, 64, 0, 100)`; alpha 0 → `.clear`.
  - `PaintDotMacTests/Model/PixelGeometryTests.swift`
    - `rectEdges`: `PixelRect(x: 2, y: 3, width: 4, height: 5)` has `maxX == 6`, `maxY == 8`; contains `(2,3)` and `(5,7)` but not `(6,7)` or `(5,8)`.
    - `intersection`: overlapping `(0,0,10,10) ∩ (5,5,10,10) == (5,5,5,5)`; edge-touching `(0,0,10,10) ∩ (10,0,5,5) == .zero`; disjoint → `.zero`; contained → the inner rect.
    - `union`: `(0,0,2,2) ∪ (5,5,1,1) == (0,0,6,6)`; with an empty operand returns the other; both empty → `.zero`.
    - `containsRect`: empty rect is contained; `(0,0,10,10)` contains itself and `(9,9,1,1)` but not `(9,9,2,1)`.
    - `sizeDescription`: `PixelSize(width: 300, height: 200).description == "300 × 200"`; `PixelSize(width: 0, height: 5).isEmpty`.
  - `PaintDotMacTests/Model/ImageLimitsTests.swift`
    - `acceptsBoundaries`: with cap `Int.max`, `(1,1)` returns 4, `(65_535, 1)` returns 262_140, `(65_535, 65_535)` returns 17_179_344_900.
    - `rejectsOutOfRangeSides`: `(0, 10)`, `(10, 0)`, `(-1, 10)`, `(65_536, 1)`, `(1, 65_536)`, `(Int.min, 1)` each throw `.dimensionsOutOfRange` with the same width/height.
    - `byteCountOverflow`: `byteCount(width: Int.max, height: 2, bytesPerPixel: 4) == nil`; `byteCount(width: 2, height: Int.max / 2 + 1, bytesPerPixel: 1) == nil`; `byteCount(width: -1, height: 1, bytesPerPixel: 4) == nil`; `byteCount(width: 3, height: 5, bytesPerPixel: 4) == 60`.
    - `memoryCapIsInclusive`: cap 1,024: `(16, 16)` passes and returns 1,024; `(16, 17)` throws `.exceedsMemoryCap(requiredBytes: 1_088, capBytes: 1_024)`; cap 1,023: `(16,16)` throws `.exceedsMemoryCap(requiredBytes: 1_024, capBytes: 1_023)`.
    - `checkOrder`: cap 0 and size `(70_000, 1)` throws `.dimensionsOutOfRange` (range is checked before the cap).
    - `defaultCap`: `defaultMemoryCap(physicalMemory: 16 << 30) == 4 << 30`; `defaultMemoryCap(physicalMemory: UInt64.max) == Int.max`; `ImageLimits.standard.memoryCapBytes > 0`.
  - `PaintDotMacTests/Model/TiledSurfaceTests.swift`
    - `tileGridDimensions`: sizes `(1,1) → 1×1`, `(256,256) → 1×1`, `(257,256) → 2×1`, `(512,513) → 2×3`, `(65_535, 1) → 256×1`; `tileCount` matches.
    - `newSurfaceIsEmptyAndSparse`: a 1,000×700 surface has `allocatedTileCount == 0`, `generation == 0`, and `pixel(at:)` is `.clear` at `(0,0)`, `(999,699)`, `(500,350)`; `readPixels(in: bounds)` is all zero.
    - `setAndGetPixel`: on 600×300, set `(255,10,20,128)` at `(0,0)`, `(255,0)`, `(256,0)`, `(599,299)`; each reads back exactly; `allocatedTileCoordinates == [(0,0), (1,0), (2,1)]`; untouched neighbours read `.clear`.
    - `outOfBoundsAccessIsSafe`: `pixel(at: (-1, 0))`, `(600, 0)`, `(0, 300)` return `.clear`; `setPixel` at those points leaves `allocatedTileCount == 0` and `generation == 0`.
    - `writeAndReadRegionAcrossTiles`: on 600×600, write a 300×300 region at `(100,100)` with a pattern `pixel(x,y) = (x % 251, y % 241, (x + y) % 256, 255)` (relative coordinates); `readPixels` of the same rect equals the source bytes; `allocatedTileCoordinates == [(0,0), (1,0), (0,1), (1,1)]`; a pixel just outside the rect `(99,100)` is `.clear`.
    - `regionWritesAreClipped`: on 300×200, write a 100×100 region at `(250, 150)` of opaque red: pixels `(250..<300, 150..<200)` are red, `pixel(at: (249,150))` is `.clear`, nothing out of bounds is written (edge padding check below), no trap. Writing at `(-50, -50)` clips the top-left the same way. A write fully outside (`(400, 400)`) leaves `generation` unchanged.
    - `regionReadPadsOutOfBoundsWithZero`: read a 4×4 rect at `(-2,-2)` on a surface whose `(0,0)` is opaque blue: exactly the bytes for local `(2,2),(3,2),(2,3),(3,3)` are blue's where set, the rest zero.
    - `readIntoBufferWithStride`: `readPixels(in:into:bytesPerRow:)` with `bytesPerRow = width × 4 + 12` writes each row at its stride and leaves the 12 padding bytes untouched (pre-filled with 0xEE).
    - `transparentWritesDoNotAllocate`: `setPixel(.clear, …)`, `writePixels` of all-zero bytes over 3 tiles, and `fill(.clear)` on a new surface leave `allocatedTileCount == 0` and `generation == 0`. Writing `(10,20,30,0)` (non-zero bytes) allocates one tile and reads back `(10,20,30,0)`.
    - `fillWholeSurface`: on 600×300, `fill(.white)`: every in-bounds pixel is white; the 6 tiles are allocated; interior tile `(0,0)` and `(1,0)` share storage (`sharesStorage`) — on this size only tiles `(0,0)`,`(1,0)` are fully covered — and edge tiles have zero padding. Then `fill(.clear)`: `allocatedTileCount == 0`.
    - `fillSharesInteriorTileStorage`: on 1,024×1,024, `fill(.white)`: all 16 tiles allocated and `tile(at: (0,0)).sharesStorage(with: tile(at: (3,3)))`; after `setPixel(.black, at: (0,0))`, tile `(0,0)` no longer shares with `(3,3)`, `(3,3)` still reads white at `(1023,1023)`, and `(1,0)` still shares with `(3,3)`.
    - `fillRectPartialTiles`: `fill(.black, in: (250, 250, 20, 20))` on 600×600 touches tiles `(0,0),(1,0),(0,1),(1,1)` and colors exactly the 400 pixels in the rect.
    - `releaseTransparentTilesFreesZeroTiles`: write a red pixel in 3 tiles, overwrite 2 of them with `.clear`; `allocatedTileCount == 3` before and `1` after `releaseTransparentTiles()`; `changedTiles(since:)` the previous generation returns the 2 released tiles; pixels unchanged.
    - `copyOnWriteIsPerTile`: fill a 512×512 surface with a pattern; `var copy = original`; `copy.setPixel(.black, at: (300, 10))`; `original.pixel(at: (300,10))` is the old value; `copy.tile(at: (0,0))` shares storage with `original.tile(at: (0,0))`; `copy.tile(at: (1,0))` doesn't share with the original's.
    - `generationTracksTouchedTiles`: on 1,024×1,024, `let g0 = generation`; `setPixel` in tile `(2,1)`: `generation == g0 + 1`, `changedTiles(since: g0) == [(2,1)]`; then `writePixels` covering tiles `(0,0)` and `(1,0)`: `generation == g0 + 2`, `changedTiles(since: g0 + 1) == [(0,0),(1,0)]`, `changedTiles(since: g0) == [(0,0),(1,0),(2,1)]`; `setTile(nil, at: (3,3))` bumps again and reports `(3,3)`.
    - `noOpWritesDoNotBumpGeneration`: fully clipped `writePixels`, `fill` with an empty rect, and transparent writes into unallocated tiles leave `generation` unchanged.
    - `equalityIgnoresAllocationAndGenerations`: a surface with an allocated all-zero tile `==` a new empty surface of the same size; two surfaces with the same pixels but different generation histories are equal; one differing pixel makes them unequal; different sizes are unequal.
    - `bulkImportSkipsZeroTiles`: `init(size: 600×300, rgba8:bytesPerRow:)` from a buffer with `bytesPerRow = 600 × 4 + 16` where only pixel `(400, 280)` is non-zero: `allocatedTileCoordinates == [(1,1)]` and the pixel reads back.
    - `makeCGImageRoundTrip`: a 300×200 surface with a pattern including semi-transparent pixels `(200,100,50,10)`: `makeCGImage()` has width 300, height 200, 8 bpc, alpha info `.last`, sRGB color space, and its provider bytes equal `readPixels(in: bounds)`.
    - `setTileRoundTrip`: `setTile(Tile(filledWith: .white), at: (0,0))` on 256×256 then `tile(at:)` returns an equal tile; `setTile(nil, …)` makes it unallocated.
  - `PaintDotMacTests/Model/LayeredImageTests.swift`
    - `singleLayerInit`: `LayeredImage(surface: s)` has one layer named `"Background"`, visible, opacity 255, `.normal`, `activeLayerIndex == 0`, `dpi == 96`, `size == s.size`, `isConsistent`.
    - `blankWhite`: `blank(size: 800×600, fill: .white)`: every pixel of the layer is white (check corners, tile seams `(255,255)`/`(256,256)`, and `(799,599)`); `dpi == 96`.
    - `isConsistentDetectsInvalidStates`: mutate a valid image to each invalid state (empty `layers`, a layer of another size, duplicate ids, `activeLayerIndex == layers.count`, `-1`, `dpi` 0, −1, `.nan`, `.infinity`) and check `isConsistent == false` for each.
    - `activeLayerAccessor`: with 2 layers and `activeLayerIndex = 1`, setting `activeLayer.name = "Top"` changes `layers[1]` only.
    - `layerEqualityIncludesPixels`: two layers with the same id and properties but one different pixel are unequal.
    - `blendModeNormal`: `BlendMode.allCases == [.normal]`, `.normal.rawValue == "normal"`, `.normal.displayName == "Normal"`.
  - `PaintDotMacTests/IO/ImageOrientationTests.swift`
    - `mappingTable`: for a 3×2 source labelled `A B C / D E F`, `sourcePoint` (and `apply`) produce exactly: 1 `ABC/DEF`; 2 `CBA/FED`; 3 `FED/CBA`; 4 `DEF/ABC`; 5 `AD/BE/CF`; 6 `DA/EB/FC`; 7 `FC/EB/DA`; 8 `CF/BE/AD` (5–8 are 2 wide, 3 tall). Use six distinct colors for A–F.
    - `applyMatchesSourcePointOnRandomImages`: for each orientation, a seeded random 37×23 image: `apply` output equals the reference built pixel by pixel from `sourcePoint`.
    - `exifValueParsing`: `ImageOrientation(exifValue: nil) == .up`, `0 → .up`, `9 → .up`, `6 → .right`; `swapsDimensions` is true exactly for 5–8; `orientedSize(3×2)` is `2×3` for 5–8.
  - `PaintDotMacTests/IO/ImageDecoderTests.swift` (fixtures from `TestImages`; tolerances stated per test)
    - `straightAlphaPNGDecodesExactly`: 2×2 straight RGBA PNG `(200,100,50,10) (255,0,0,255) / (10,20,30,0) (1,2,3,128)` decodes to `(200,100,50,10) (255,0,0,255) / (10,20,30,0) (1,2,3,128)` exactly (the color under the alpha-0 pixel is preserved, FMT-B); size 2×2, one layer "Background", DPI 96.
    - `alphaZeroColorAllocatesItsTile`: a 600×300 straight PNG that is `(0,0,0,0)` everywhere except pixel `(300, 10)` = `(10,20,30,0)`: `allocatedTileCoordinates == [(1,0)]` and `pixel(at: (300,10)) == (10,20,30,0)`.
    - `transparentTilesStayUnallocated`: a 600×300 PNG, `(0,0,0,0)` except an opaque 10×10 block at `(300,10)`: `allocatedTileCoordinates == [(1,0)]` and the block reads back exactly.
    - `opaqueJPEGHasFullAlpha`: a 64×64 JPEG of four solid 32×32 quadrants (red, green, blue, white): every pixel has alpha 255 and quadrant centres are within ±8 of their color.
    - `premultipliedTIFFUsesDocumentedRounding`: a 256×256 premultiplied-last sRGB TIFF where pixel `(x, y)` = `(min(x, y), min(x,y)/2, 0, y)` (premultiplied components ≤ alpha) decodes exactly to `ColorRGBA8.unpremultiply` of each component (the alpha-0 row `y == 0` → `(0,0,0,0)` for every `x`).
    - `sixteenBitIsReducedToEightBit`: 2×1 16-bit RGBA PNG `(0xFFFF, 0x8080, 0x0000, 0xFFFF) (0x1234, 0x5678, 0x9ABC, 0xFFFF)` → `(255,128,0,255) (18,86,154,255)` ±1 (oracle `round(v / 257)`).
    - `floatIsReducedToEightBit`: 1×1 32-bit float RGBA TIFF `(1.0, 0.5, 0.0, 1.0)` → `(255, 128, 0, 255)` ±1.
    - `grayscaleIsExpandedToRGBA`: 2×1 gray PNG (generic gray gamma 2.2) `0, 128` → `(0,0,0,255) (128,128,128,255)` ±1.
    - `linearGrayIsConvertedToSRGBTransfer`: 1×1 linear-gray PNG value 128 → each channel within ±2 of the sRGB encoding of 128/255 (oracle: `l = 128/255`, `s = l <= 0.0031308 ? 12.92 l : 1.055 l^(1/2.4) − 0.055`, `round(s × 255) = 188`).
    - `displayP3IsConvertedToSRGB`: Display P3 PNG pixels: P3 `(128,128,128)` → sRGB `(128,128,128)` ±1 (same white point and transfer); P3 `(255,0,0)` → red ≥ 250, green ≤ 10, blue ≤ 10. Also a P3 in-gamut color `(200,120,90)`: the result differs from `(200,120,90)` by at least 3 in some channel (proves conversion happened) and matches a CoreGraphics oracle (draw the source CGImage into an 8-bit sRGB `CGContext` 1×1 and read it) within ±2.
    - `cmykIsConvertedToRGB`: CMYK TIFF and CMYK JPEG 2×1 `(0,0,0,0) (0,0,0,255)` (generic CMYK): first pixel each channel ≥ 250; second pixel each channel ≤ 60 and channels within 4 of each other; alpha 255.
    - `untaggedImageIsTreatedAsSRGB`: a PNG written from a `CGColorSpaceCreateDeviceRGB()` image `(10,20,30,40)` decodes to exactly `(10,20,30,40)`.
    - `animatedGIFUsesFirstFrame`: a 2-frame 1×1 GIF (red, then blue) → `(255,0,0,255)` ±1.
    - `dpiIsReadFromPNG`: PNG with DPI 300×300 → `dpi` within 0.01 of 300 (pHYs stores pixels per metre, so allow the rounding: 11,811 px/m = 299.9994 DPI).
    - `dpiIsReadFromJPEG`: JPEG with DPI 72.5×72.5 → 72.5.
    - `missingDPIDefaultsTo96`: a PNG with no DPI properties → 96.
    - `resolvedDPIRules` (pure, on dictionaries): `[W:300, H:150]` up → 300; same with `.right` → 150; `[W:0, H:200]` → 200; `[W:.nan, H:-1]` → 96; `[:]` → 96; `[W: .infinity, H: 72]` → 72.
    - `orientationIsAppliedToPixelsAndSize`: a 3×2 PNG `ABC/DEF` with `kCGImagePropertyOrientation: 6` decodes to 2×3 `DA/EB/FC` exactly; a 64×32 JPEG with orientation 8 and left-half red / right-half blue decodes to 32×64 with the top half blue and bottom half red (±8 at block centres).
    - `maximumWidthOpens`: a 65,535×1 PNG, transparent except pixel `(65_534, 0)` = opaque green, decodes (cap `Int.max`): size 65,535×1, `allocatedTileCoordinates == [(255, 0)]`, the pixel reads green.
    - `decodedSurfaceMatchesSurfaceFromCGImage`: for the 2×2 straight PNG's CGImage, `surface(from:)` equals `decode(...).surface`.
    - `pngChunkWalk`: `pngChunksAreComplete` is true for a valid PNG and for a valid PNG plus 100 trailing bytes; false for empty data, the signature only, the PNG minus its last byte, the PNG minus its 12-byte IEND, the first half of the PNG, and a PNG whose first chunk length is `0xFFFFFFFF`.
  - `PaintDotMacTests/IO/ImageDecoderFailureTests.swift` — each asserts the exact thrown error (`#expect(throws: ImageCodecError.corrupt) { … }`):

    | Test | Input | Expected |
    |---|---|---|
    | `emptyData` | `Data()` | `.unrecognizedFormat` |
    | `randomBytes` | the ASCII bytes `JUNK` followed by 996 seeded random bytes | `.unrecognizedFormat` |
    | `textFile` | `"hello".data(using: .utf8)` | `.unrecognizedFormat` |
    | `headerOnlyPNG` | `pngHeaderOnly(width: 10, height: 10)` | `.corrupt` |
    | `truncatedPNG` | a 64×64 pattern PNG cut to 50% | `.corrupt` |
    | `pngWithoutIEND` | the same PNG minus its last 12 bytes | `.corrupt` |
    | `damagedIDAT` | the same PNG with bytes 60..<200 set to 0xAA | `.corrupt` |
    | `truncatedBaselineJPEG` | a 300×200 pattern JPEG cut to 95%, 50%, and 20% | `.corrupt` each |
    | `truncatedProgressiveJPEG` | the same with `kCGImagePropertyJFIFIsProgressive: true`, cut to 50% | `.corrupt` |
    | `oversizedHeaderIsRefusedBeforeDecoding` | `pngHeaderOnly(width: 70_000, height: 1)` | `.limitExceeded(.dimensionsOutOfRange(width: 70_000, height: 1))` (not `.corrupt`: limits are checked first) |
    | `hugeHeaderAgainstCap` | `pngHeaderOnly(width: 65_535, height: 65_535)`, cap 1 GiB | `.limitExceeded(.exceedsMemoryCap(requiredBytes: 17_179_344_900, capBytes: 1_073_741_824))` |
    | `memoryCapIsEnforced` | a valid 16×16 PNG with cap 1,023 / cap 1,024 | throws `.exceedsMemoryCap(requiredBytes: 1_024, capBytes: 1_023)` / decodes |
    | `pngWithTrailingBytes` | a valid PNG + 100 bytes of 0x55 | decodes to the original pixels |
  - `PaintDotMacTests/IO/ImageCodecErrorTests.swift`
    - `messages`: every row of the message table, with exact strings, for `(70_000, 1)` → `"Images can be up to 65,535 × 65,535 pixels. This one is 70,000 × 1 pixels."`, `(0, 5)` → `"The image has no pixels."` and `nil`, `.byteCountOverflow(width: Int.max, height: 2)` contains `"can’t be held in memory"`, `.exceedsMemoryCap` starts with `"Opening it needs "` and contains `", but the limit is "`.
  - `PaintDotMacTests/App/LaunchOptionsTests.swift` (add to 0001's file if it has another name)
    - `memoryCapArgument`: `["-UITestMemoryCapBytes", "1000"] → 1000`; missing → `nil`; `"abc"`, `"0"`, `"-5"` → `nil`.
  - `PaintDotMacTests/Support/SeededRandomTests.swift`
    - `splitMix64ReferenceValues`: seed 0 gives `0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F`; seed 42 gives `0xBDD732262FEB6E95, 0x28EFE333B266F103` (published SplitMix64 reference values, checked by hand when writing this spec).
    - `resolvedSeedParsing`: with no environment variable, `resolvedSeed(default: 7) == 7` (the parser is factored as `static func parseSeed(_ text: String?) -> UInt64?`: `"42" → 42`, `"0x2A" → 42`, `"zz" → nil`, `nil → nil`).
- **Round-trip and property tests** (`PaintDotMacTests/Model/TiledSurfacePropertyTests.swift`, `SeededRandom` with fixed default seeds, the seed in every comment)
  - `randomOperationsMatchFlatReference`: 300 iterations on a 700×530 surface (not a multiple of 256) against a reference model that is a plain `[UInt8]` of 700×530×4 bytes: random `setPixel` (points may be out of bounds), `writePixels` (random rects from `rect(around:maxSide: 600)`, including out-of-bounds and empty ones, random bytes with ~30% fully zero pixels), `fill` (random rect or nil, random color, sometimes `.clear`), and `releaseTransparentTiles`. After each step, `readPixels(in: bounds)` equals the reference, and a random `readPixels` rect (possibly out of bounds) equals the reference with zero padding.
  - `edgeTilePaddingStaysZero`: after the same random sequence, for every allocated edge tile, every byte outside `bounds` is 0.
  - `sparsenessInvariant`: after the sequence plus `releaseTransparentTiles()`, every allocated tile has at least one non-zero byte and every tile without non-zero reference pixels is unallocated.
  - `copiesAreIndependent`: take a copy every 25 steps; keep mutating the original; each copy still equals the reference snapshot taken when it was made.
  - `changedTilesCoversEveryModifiedPixel`: for random operations, every tile whose pixels changed is in `changedTiles(since: generationBefore)`.
  - `pngRoundTrip`: 20 seeded random images (sizes 1…600 × 1…400, random straight RGBA, ~20% of pixels alpha 0 with a random non-zero color): build a surface, `makeCGImage()`, encode PNG with `TestImages.encode`, decode with `ImageDecoder.decode` → equal surface (exact).
- **Golden-image tests:** none; this spec has no blending or effects. The ICC tests use the CoreGraphics oracle described in `displayP3IsConvertedToSRGB`.
- **Integration tests** (`PaintDotMacTests/Document/PaintDocumentLoadingTests.swift`, headless, `@MainActor`)
  - `readsPNGIntoLayeredImage`: `PaintDocument()` then `read(from: pngData, ofType: "public.png")` for a 300×200 PNG with DPI 150 and a pattern: `image.size == 300×200`, `layers.count == 1`, name `"Background"`, `dpi ≈ 150` (±0.01), pixels equal the pattern (`TestImages.expectPixels`, exact).
  - `readsJPEGIntoLayeredImage`: 64×64 quadrant JPEG with `"public.jpeg"`: size, one layer, alpha 255, quadrant colors ±8, `dpi == 72` when written with 72.
  - `jpegBytesWithPNGTypeOpen`: the JPEG bytes with type `"public.png"` read successfully.
  - `corruptDataThrowsCodecError`: the truncated PNG throws `ImageCodecError.corrupt`; the image is unchanged from before the call.
  - `documentUsesStandardLimitsByDefault`: `PaintDocument.imageLimits` equals `ImageLimits.standard` when the launch argument is absent (the test process has no such argument) (the argument path itself is covered by `LaunchOptionsTests` and the UI test).
- **UI tests** (`PaintDotMacUITests/ImageDecodingUITests.swift`, launched through `UITestApp` with fixtures written at test time)
  - `opensTransparentPNGAtItsSize`: a 300×200 PNG, transparent left half and opaque red right half: the document window appears with title `"<fixture name>.png"`, the `canvas` element exists and its `value` is `"300 × 200"`.
  - `rotatedJPEGOpensUpright`: a 300×200 JPEG with orientation 6: the `canvas` value is `"200 × 300"`.
  - `corruptFileShowsAlert`: `-UITestOpen` with the truncated PNG: an alert (query `app.dialogs`, `app.sheets`, and `app.alerts`) appears whose static texts include one containing `"damaged or incomplete"`; pressing its default button dismisses it; afterwards `app.state == .runningForeground` and no `canvas` element exists.
  - `imageAboveMemoryCapShowsAlert`: launch with `-UITestMemoryCapBytes 1000` and a 100×100 PNG (40,000 bytes): an alert containing `"too large"` appears; dismissing it leaves the app running with no `canvas`.
- **Performance** (`PaintDotMacTests/Performance/ImageDecoderPerformanceTests.swift`, XCTest)
  - `testDecode24MegapixelJPEG`: in `setUp`, render a 6,000×4,000 image (a CoreGraphics gradient plus a few filled shapes, so it's not trivially compressible) and encode it as a quality-0.9 JPEG. `measure { _ = try ImageDecoder.decode(data, limits: ImageLimits(memoryCapBytes: .max)) }`. Separately time one decode with `ContinuousClock` and `XCTAssertLessThan(seconds, 3.0)` (3× the NF-2 1 s open budget; Debug build). Report the measured number in the spec's Verification status.
  - `testRegionWriteThroughput`: write a full 4,000×3,000 opaque buffer with `writePixels` then read it back with `readPixels`; time it and assert < 1.5 s (gross-regression gate); report the number. This guards the copy-on-write discipline (a per-pixel tile copy would take minutes).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes (empty, PNG, JPEG).
- **Manual verification**
  1. Open a portrait photo taken with an iPhone and exported as JPEG (EXIF orientation 6) → it appears upright, the same as in Preview.
  2. Open a CMYK JPEG (for example from a print PDF export) → its colors look like Preview's rendering of the same file, side by side.
  3. Take a screenshot on a Display P3 Mac (a P3-tagged PNG) with saturated colors → the colors look like Preview's, with no obvious shift in mid-tones.
  4. Open a large real-world photo (24 MP or more) → it opens in about a second with no beachball, and Activity Monitor shows memory close to width × height × 4 plus app overhead after opening (no duplicated buffers left behind).
  5. Open a truncated real JPEG (`head -c 200000 photo.jpg > cut.jpg`) via File > Open → the "damaged or incomplete" alert appears and the app keeps running.

## Out of scope

- The Metal canvas, zoom, and tile upload (0003 consumes `changedTiles(since:)`); the status bar and units (0004).
- New Image, saving, and PNG encoding with an embedded sRGB profile (0005; FMT-B's "saving always embeds sRGB" lands there).
- History, `HistoryItem`, and `TileDiff` (0008). Nothing in this spec changes pixels of an open document after loading.
- Compositing several layers, premultiplication, and `BlendOps` (0009, 0012, 0024). `BlendMode` has only `.normal`.
- Selection masks (0013), clipboard decoding (0021, which reuses `ImageDecoder.surface(from:)` and `TiledSurface.init(size:rgba8:bytesPerRow:)`), import as layer (0030).
- Document types and UTIs for HEIC, TIFF, BMP, GIF, and WebP, and their export (0029). The decoder already reads them, but the app only offers PNG and JPEG (0001) until 0029.
- OpenRaster (0028). 16-bit, float, or P3 working spaces (Q-2: RGBA8 only in v1).
