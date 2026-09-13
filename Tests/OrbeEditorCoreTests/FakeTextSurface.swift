import AppKit
import OrbeEditorCore

/// 文字列を持つだけのテキスト面。`replace` が編集を delegate へ流し、塗られた区間を記録する。
@MainActor
final class FakeTextSurface: TextSurface {
  let view = NSView()
  var responder: NSView { view }
  private(set) var storage: NSMutableString
  var style: TextSurfaceStyle
  weak var delegate: TextSurfaceDelegate?
  var visibleRange = NSRange(location: 0, length: 0)
  private(set) var undoBoundaries = 0
  /// 塗られた区間（役割付き）。`applyHighlights` の ranges で外し、spans で置く。
  private(set) var highlights: [HighlightSpan] = []

  init(text: String, style: TextSurfaceStyle = .fake) {
    storage = NSMutableString(string: text)
    self.style = style
  }

  var text: String { storage as String }
  var length: Int { storage.length }
  func substring(in range: NSRange) -> String { storage.substring(with: range) }

  func applyHighlights(_ spans: [HighlightSpan], in ranges: IndexSet) {
    highlights.removeAll { ranges.intersects(integersIn: Range($0.range)!) }
    highlights.append(contentsOf: spans)
  }

  func markUndoBoundary() { undoBoundaries += 1 }

  /// 編集を起こす（人の打鍵に相当）。
  func replace(_ range: NSRange, with replacement: String) {
    storage.replaceCharacters(in: range, with: replacement)
    delegate?.surface(
      self, didChange: TextEdit(range: range, replacementLength: (replacement as NSString).length))
  }

  func focus(_ focused: Bool) {
    delegate?.surface(self, focusDidChange: focused)
  }

  /// 役割を持つ区間の本文を集める（役割 → 文字列の集合）。
  func texts(of role: SyntaxRole) -> Set<String> {
    Set(highlights.filter { $0.role == role }.map { substring(in: $0.range) })
  }
}

extension TextSurfaceStyle {
  static let fake = TextSurfaceStyle(
    font: .monospacedSystemFont(ofSize: 12, weight: .regular), lineHeight: 18, topInset: 4,
    textColor: .textColor, caretColor: .textColor, caretSize: CGSize(width: 1.5, height: 14),
    gutterFont: .monospacedSystemFont(ofSize: 11, weight: .regular), gutterTextColor: .textColor,
    gutterWidth: 50, gutterTrailingInset: 8, roleColors: [:])
}

/// テスト実行体は同梱物を持たないので、SwiftPM が資源バンドルを並べる `.build/<config>`
/// （テストバンドルの親）を queries の根として明示する。
enum Queries {
  static let root = Bundle(for: FakeTextSurface.self).bundleURL.deletingLastPathComponent()
  static let samples = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/samples")
}
