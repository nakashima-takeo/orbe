import AppKit
import OrbeEditorCore

/// 文字列を持つだけのテキスト面。`replace` が編集を delegate へ流す。色は全文を見えているものとして、そのつど delegate
/// に問い合わせる。
@MainActor
final class FakeTextSurface: TextSurface {
  let view = NSView()
  var responder: NSView { view }
  private(set) var storage: NSMutableString
  weak var delegate: TextSurfaceDelegate?
  private(set) var undoBoundaries = 0
  /// 最後に押された行の印。
  private(set) var lineMarks = LineMarkSpans.empty
  var onOpenLink: ((URL) -> Void)?
  /// 見えている範囲（本文の言葉）。テストが置く。
  var viewport = TextViewport.empty
  /// `scroll(toTop:)` の履歴。
  private(set) var toppedAt: [(offset: Int, hiddenFraction: CGFloat)] = []
  var selectedRange = NSRange(location: 0, length: 0) {
    didSet { delegate?.surfaceDidChangeSelection(self) }
  }
  var caretLocation: Int { NSMaxRange(selectedRange) }
  private(set) var indentUnit = IndentUnit.fallback

  init(text: String) {
    storage = NSMutableString(string: text)
  }

  var text: String { storage as String }
  var length: Int { storage.length }
  func substring(in range: NSRange) -> String { storage.substring(with: range) }

  /// 全文の役割の区間（delegate に問い合わせる）。
  var highlights: [HighlightSpan] {
    delegate?.surface(self, rolesIn: NSRange(location: 0, length: length)) ?? []
  }

  func markUndoBoundary() { undoBoundaries += 1 }

  func setLineMarks(_ spans: LineMarkSpans) { lineMarks = spans }

  func setGround(_ color: NSColor) {}

  func scrollToCenter(_ offset: Int) {}

  func scrollToVisible(_ range: NSRange) {}

  func scroll(toTop offset: Int, hiddenFraction: CGFloat) {
    toppedAt.append((offset, hiddenFraction))
  }

  func setHighlights(_ ranges: [NSRange], for kind: TextHighlightKind) {}

  func setIndentUnit(_ unit: Int) { indentUnit = unit }

  /// 契約の後条件どおり、置き換え後の選択は解け、キャレットは同じオフセット（本文が短ければ末尾）。
  func replaceAll(with text: String) {
    let caret = selectedRange.location
    replace(NSRange(location: 0, length: length), with: text)
    selectedRange = NSRange(location: min(caret, length), length: 0)
  }

  /// 編集を起こす（人の打鍵に相当）。
  func replace(_ range: NSRange, with replacement: String) {
    storage.replaceCharacters(in: range, with: replacement)
    delegate?.surface(
      self,
      didChange: TextEdit(range: range, replacementLength: (replacement as NSString).length))
  }

  func focus(_ focused: Bool) {
    delegate?.surface(self, focusDidChange: focused)
  }

  /// 役割を持つ区間の本文を集める（役割 → 文字列の集合）。
  func texts(of role: SyntaxRole) -> Set<String> {
    Set(highlights.filter { $0.role == role }.map { substring(in: $0.range) })
  }
}

/// テスト実行体は同梱物を持たないので、SwiftPM が資源バンドルを並べる `.build/<config>`
/// （テストバンドルの親）を queries の根として明示する。
enum Queries {
  static let root = Bundle(for: FakeTextSurface.self).bundleURL.deletingLastPathComponent()
  static let samples = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/samples")
}
