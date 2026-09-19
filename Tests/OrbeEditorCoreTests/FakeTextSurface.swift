import AppKit
import OrbeEditorCore

/// 文字列を持つだけのテキスト面。`replace` が編集を delegate へ流し、塗られた区間を記録する。
@MainActor
final class FakeTextSurface: TextSurface {
  let view = NSView()
  var responder: NSView { view }
  private(set) var storage: NSMutableString
  weak var delegate: TextSurfaceDelegate?
  /// 見えている区間。既定は「何も見えていない」（可視の塗り直しを見るテストが明示する）。
  var visibleRange = NSRange(location: 0, length: 0)
  private(set) var undoBoundaries = 0
  /// 塗られた区間（役割付き）。`applyHighlights` の ranges で外し、spans で置く。
  private(set) var highlights: [HighlightSpan] = []
  /// `applyHighlights` に渡された ranges と spans の履歴（呼び出しごと）。
  private(set) var appliedRanges: [IndexSet] = []
  private(set) var appliedSpans: [[HighlightSpan]] = []
  /// 最後に押された行の印。
  private(set) var lineMarks = LineMarkSpans.empty
  var onOpenLink: ((URL) -> Void)?

  init(text: String) {
    storage = NSMutableString(string: text)
  }

  var text: String { storage as String }
  var length: Int { storage.length }
  func substring(in range: NSRange) -> String { storage.substring(with: range) }

  func applyHighlights(_ spans: [HighlightSpan], in ranges: IndexSet) {
    appliedRanges.append(ranges)
    appliedSpans.append(spans)
    // 本物の rendering attribute と同じく、ranges と重なる部分だけ外し、外側の色は残す。
    highlights = highlights.flatMap { span -> [HighlightSpan] in
      var kept = IndexSet(integersIn: Range(span.range)!)
      kept.subtract(ranges)
      return kept.rangeView.map { HighlightSpan(range: NSRange($0), role: span.role) }
    }
    highlights.append(contentsOf: spans)
  }

  func markUndoBoundary() { undoBoundaries += 1 }

  func setLineMarks(_ spans: LineMarkSpans) { lineMarks = spans }

  func replaceAll(with text: String) {
    replace(NSRange(location: 0, length: length), with: text)
  }

  /// 編集を起こす（人の打鍵に相当）。塗った区間は本物の描画属性と同じく文字に付いて動く——
  /// 編集より後ろは平行移動し、編集に掛かった区間は編集の外側だけが残る（置換文字は無色）。
  func replace(_ range: NSRange, with replacement: String) {
    let length = (replacement as NSString).length
    storage.replaceCharacters(in: range, with: replacement)
    let delta = length - range.length
    highlights = highlights.flatMap { span -> [HighlightSpan] in
      let start = span.range.location
      let end = NSMaxRange(span.range)
      if end <= range.location { return [span] }
      if start >= NSMaxRange(range) {
        return [
          HighlightSpan(
            range: NSRange(location: start + delta, length: end - start), role: span.role)
        ]
      }
      var parts: [HighlightSpan] = []
      if start < range.location {
        parts.append(
          HighlightSpan(
            range: NSRange(location: start, length: range.location - start), role: span.role))
      }
      if end > NSMaxRange(range) {
        let tail = NSMaxRange(range)
        parts.append(
          HighlightSpan(range: NSRange(location: tail + delta, length: end - tail), role: span.role)
        )
      }
      return parts
    }
    delegate?.surface(self, didChange: TextEdit(range: range, replacementLength: length))
  }

  /// 見える区間を動かして viewport の通知を流す。
  func scroll(to range: NSRange) {
    visibleRange = range
    delegate?.surfaceDidLayoutViewport(self)
  }

  /// オフセットの字の役割（後に塗られた区間が勝つ）。区間に入っていなければ nil＝素の文字。
  func role(at offset: Int) -> SyntaxRole? {
    highlights.last { NSLocationInRange(offset, $0.range) }?.role
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
