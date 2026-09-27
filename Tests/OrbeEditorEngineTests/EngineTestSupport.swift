import AppKit
import Metal
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 新しい面のテストの足場。本物の文書（`EditorDocument`）に新しい面を結び、窓に載せずに大きさと倍率を与える。
@MainActor
class EngineTestCase: XCTestCase {
  /// テスト 1 件の作業ディレクトリ。
  private(set) var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipIf(RenderThread.device == nil, "Metal の装置が無い環境では新しい面を作らない")
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
    try super.tearDownWithError()
  }

  /// 見本の見え方（Orbe の既定に近い値。色は外観に依らない固定値）。
  static func style() -> TextSurfaceStyle {
    let text = NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)
    return TextSurfaceStyle(
      font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 18, topInset: 4,
      textColor: text, backgroundColor: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1),
      caretColor: .white, caretSize: CGSize(width: 1.5, height: 14),
      selectionColor: NSColor(srgbRed: 0.15, green: 0.31, blue: 0.47, alpha: 1),
      inactiveSelectionColor: NSColor(srgbRed: 0.23, green: 0.24, blue: 0.26, alpha: 1),
      gutterFont: .monospacedSystemFont(ofSize: 11, weight: .regular),
      gutterTextColor: NSColor(srgbRed: 0.43, green: 0.46, blue: 0.51, alpha: 1), gutterWidth: 44,
      gutterTrailingInset: 16,
      roleColors: [
        .keyword: NSColor(srgbRed: 0.34, green: 0.61, blue: 0.84, alpha: 1),
        .keywordControl: NSColor(srgbRed: 0.77, green: 0.53, blue: 0.75, alpha: 1),
        .type: NSColor(srgbRed: 0.31, green: 0.79, blue: 0.69, alpha: 1),
        .function: NSColor(srgbRed: 0.86, green: 0.86, blue: 0.67, alpha: 1),
        .string: NSColor(srgbRed: 0.81, green: 0.57, blue: 0.47, alpha: 1),
        .comment: NSColor(srgbRed: 0.42, green: 0.6, blue: 0.33, alpha: 1),
        .variable: NSColor(srgbRed: 0.61, green: 0.86, blue: 1, alpha: 1),
        .punctuation: text,
      ],
      marks: .init(
        gutterWidth: 9, barWidth: 3, barInset: 2, barRadius: 1, triangleSize: 6,
        added: NSColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 0.85),
        modified: NSColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 0.85),
        removed: NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 0.85)),
      decorations: .init(
        indentGuideColor: .gray, indentGuideWidth: 1, whitespaceColor: .gray,
        whitespaceDiameter: 2, linkUnderlineThickness: 1, linkUnderlineOffset: 3),
      highlights: .init(
        findMatch: .yellow, currentFindMatch: .orange, currentFindLine: .gray,
        selectionOccurrence: .gray, selectionOccurrenceInactive: .gray, wordOccurrence: .gray),
      overview: overviewStyle())
  }

  /// 見本の俯瞰の見え方（寸法は Orbe の既定。色は外観に依らない固定値）。
  static func overviewStyle() -> TextSurfaceStyle.Overview {
    let gray = { (white: CGFloat, alpha: CGFloat) in
      NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
    return TextSurfaceStyle.Overview(
      minimap: .init(
        maxWidth: 120, slider: gray(0.47, 0.2), sliderHover: gray(0.39, 0.35),
        sliderActive: gray(0.75, 0.2),
        selection: NSColor(srgbRed: 0.15, green: 0.31, blue: 0.47, alpha: 1),
        findMatch: NSColor(srgbRed: 0.92, green: 0.36, blue: 0, alpha: 0.33),
        wordOccurrence: NSColor(srgbRed: 0.68, green: 0.84, blue: 1, alpha: 0.15),
        added: NSColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 1),
        modified: NSColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 1),
        removed: NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 1)),
      scrollbar: .init(
        width: 14, horizontalHeight: 12, slider: gray(0.47, 0.4), sliderHover: gray(0.39, 0.7),
        sliderActive: gray(0.75, 0.4), border: gray(1, 0.07),
        findMatch: NSColor(srgbRed: 0.82, green: 0.53, blue: 0.09, alpha: 0.49),
        wordOccurrence: gray(0.63, 0.8),
        added: NSColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 0.6),
        modified: NSColor(srgbRed: 0.3, green: 0.5, blue: 0.9, alpha: 0.6),
        removed: NSColor(srgbRed: 0.9, green: 0.3, blue: 0.3, alpha: 0.6),
        caret: gray(1, 0.7)),
      topShadow: gray(0, 1), minimapShadow: gray(0, 0.08), fadeIn: 0.1, fadeOut: 0.8,
      hideDelay: 0.5)
  }

  nonisolated static let options = MetalTextSurfaceOptions(
    elasticScroll: true, fontSmoothing: true, omittedLabel: { "+\($0)" })

  /// 開いた文書と、それに結んだ新しい面。
  struct Opened {
    let document: EditorDocument
    let surface: MetalTextSurface
  }

  /// `text` を `name` のファイルとして開き、新しい面を結んで `size` の大きさを与える（窓には載せない）。
  func open(
    _ text: String, name: String = "a.swift", size: CGSize = CGSize(width: 800, height: 600),
    scale: CGFloat = 2, options: MetalTextSurfaceOptions = options,
    style: TextSurfaceStyle? = nil, waitForColors: Bool = true
  ) throws -> Opened {
    let url = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    let surface = MetalTextSurface(style: style ?? Self.style(), options: options)
    let document = EditorDocument(
      url: url, contents: try EditorDocument.read(url), surface: surface,
      registry: Self.registry)
    surface.view.appearance = NSAppearance(named: .darkAqua)
    surface.viewStateDidChange(size: size, scale: scale, visible: false)
    if waitForColors { XCTAssertTrue(document.waitUntilCaughtUp(timeout: 30)) }
    return Opened(document: document, surface: surface)
  }

  /// queries はテスト実行体の隣（`.build/<config>`）の資源バンドルから解く。
  static let registry = LanguageRegistry(
    queriesRoot: Bundle(for: EngineTestCase.self).bundleURL.deletingLastPathComponent())

  /// 出力先（`.preview/engine`）。
  func previewURL(_ name: String) -> URL {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".preview/engine", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
  }

  func writePNG(_ image: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}

extension MetalTextSurface {
  /// 描画スレッドが見る材料——出す前の状態をその場で出してから読む（テストが描画スレッドへ問う前に出す）。
  var drawn: FrameMaterial {
    flush()
    return material.read()
  }
}

/// 撮った絵（不透明な地に描いた 2x の 1 コマ）を pt で引く。
struct PixelShot {
  let bytes: [UInt8]
  let width: Int
  let height: Int

  /// (x, y) pt の画素の RGB（sRGB の 0…255）。
  func rgb(_ x: CGFloat, _ y: CGFloat) -> [Int] {
    let i = (Int(y * 2) * width + Int(x * 2)) * 4
    return [Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i])]
  }

  /// 地（黒）から離れた色か。
  func hasInk(_ x: CGFloat, _ y: CGFloat) -> Bool { rgb(x, y).contains { $0 >= 12 } }
}

@MainActor
extension EngineTestCase {
  /// 出す前の状態を出し、不透明な地（既定は黒）に今の位置の 1 コマを描いて撮る。
  func pixelShot(
    _ opened: Opened, background: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
  ) throws -> PixelShot {
    let id = opened.surface.id
    opened.surface.flush()
    let image = try XCTUnwrap(
      RenderThread.shared.performAndWait {
        Transfer(value: $0.snapshot(id, background: background))
      }
      .value)
    return PixelShot(bytes: GlyphPixelTests.pixels(image), width: image.width, height: image.height)
  }
}
