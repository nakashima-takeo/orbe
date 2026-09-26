import AppKit
import OrbeEditorCore
import STTextView

/// 構文の色の窓。色は見えている行にだけ塗り、上流が layout した範囲（見えている範囲と上下の先読みの帯）の外の色は外す
/// ——全文に色を置くと、色を 1 か所変えるたびに文書全体の属性の表が動き、打鍵もスクロールも文書の大きさに比例して重くなる。
/// 先読みの帯は、スクロールで見えたとき（clip の bounds の通知。描く前に届く）に塗る。
/// 不変条件: 色は窓の中にしか無く、見えている字の色は常に文書の今の役割と一致する（打鍵の直後は文書がずらした役割、裏の
/// 結果が届けばその役割）。役割は面の delegate（文書）に問い合わせる。
@MainActor
final class SyntaxColorWindow {
  private let textView: STTextView
  private let colors: [SyntaxRole: NSColor]
  /// 区間の役割（面が delegate へ問い合わせる）。
  var roles: (NSRange) -> [HighlightSpan] = { _ in [] }
  /// 色が付いているかもしれない区間（窓の外に出れば外す）。
  private var touched = IndexSet()
  /// 色が文書の今の役割と一致する区間（`touched` の中）。編集で空になり、裏から役割が届けばその区間が外れる。
  private var fresh = IndexSet()
  /// 最後に見た、見えている行の区間。
  private var visible = NSRange(location: 0, length: 0)

  init(textView: STTextView, colors: [SyntaxRole: NSColor]) {
    self.textView = textView
    self.colors = colors
  }

  /// layout の後——窓の外の色を外し、見えている行のうちまだ塗っていない部分を塗る（遠くへ飛べば窓ごと入れ替わる）。
  /// layout をやり直さない：上流は layout のたびに窓の行片の view をすべて描き直しの対象にし、この通知はその layout の
  /// 中（描く前）に届くので、塗った色は同じコマで描かれる。
  func layoutDidChange(_ range: NSTextRange) {
    let window = NSRange(range, in: textView.textContentManager)
    let inside = IndexSet(integersIn: Range(window) ?? 0..<0)
    let outside = touched.subtracting(inside)
    if !outside.isEmpty {
      for part in outside.rangeView { uncolor(NSRange(part)) }
      touched.formIntersection(inside)
      fresh.formIntersection(inside)
    }
    guard let lines = visibleLines(in: range) else { return }
    visible = lines
    paint(IndexSet(integersIn: Range(lines) ?? 0..<0).subtracting(fresh))
  }

  /// スクロールした（layout の前）——窓の中で新しく見えた行を塗る（窓の外は続く layout で塗る）。layout は求めない：
  /// 帯の行片の view は、最後の layout で描き直しの対象になったまま、見えるまで描かれない（見えない view は描かない）。
  func scrollDidChange() {
    guard let window = textView.textLayoutManager.textViewportLayoutController.viewportRange,
      let lines = visibleLines(in: window), lines != visible
    else { return }
    visible = lines
    let stale = IndexSet(integersIn: Range(lines) ?? 0..<0).subtracting(fresh)
    guard !stale.isEmpty else { return }
    paint(stale)
  }

  /// 編集の後——色の付いた区間を編集に沿って写し、どの色も古いものとして扱う。塗るのは続く layout（上流は編集の後、描く
  /// 前に必ず layout して通知する）で、見えている行を丸ごと問い合わせ直す（文書が編集に合わせてずらした役割で）。隣の字の
  /// 変化で役割が変わる字（呼び出しでなくなった識別子・引用符の後ろ）は、裏から役割が届いたとき（`rolesDidChange`）に
  /// 塗り直す。帯の色は見えたときに塗り直す。
  func textDidChange(_ edit: TextEdit) {
    touched.remove(integersIn: edit.range.location..<NSMaxRange(edit.range))
    touched.shift(
      startingAt: NSMaxRange(edit.range), by: edit.replacementLength - edit.range.length)
    touched.insert(integersIn: edit.newRange.location..<NSMaxRange(edit.newRange))
    fresh = IndexSet()
    textView.needsLayout = true
  }

  /// 役割が変わった（裏から届いた）——区間の色を古いものとして扱い、見えている行に掛かれば続く layout で塗り直す。
  /// 帯の色は見えたときに塗り直す。
  func rolesDidChange(_ ranges: IndexSet) {
    fresh.subtract(ranges)
    guard ranges.intersects(integersIn: Range(visible) ?? 0..<0) else { return }
    textView.needsLayout = true
  }

  /// 窓の行片のうち見えている行の区間。見えている行片が無ければ nil。窓の行片だけを見る——窓の外の位置は推定で、行片の
  /// 位置と食い違う。
  private func visibleLines(in window: NSTextRange) -> NSRange? {
    let rect = textView.visibleRect
    var first: NSTextLocation?
    var last: NSTextLocation?
    let layoutManager = textView.textLayoutManager
    layoutManager.enumerateTextLayoutFragments(from: window.location, options: []) { fragment in
      let frame = fragment.layoutFragmentFrame
      guard frame.minY < rect.maxY,
        fragment.rangeInElement.location.compare(window.endLocation) == .orderedAscending
      else {
        return false
      }
      if frame.maxY > rect.minY {
        if first == nil { first = fragment.rangeInElement.location }
        last = fragment.rangeInElement.endLocation
      }
      return true
    }
    guard let first, let last, let range = NSTextRange(location: first, end: last) else {
      return nil
    }
    return NSRange(range, in: textView.textContentManager)
  }

  /// 区間を今の役割で塗り直す（前の色は外す）。
  private func paint(_ set: IndexSet) {
    for part in set.rangeView {
      let range = NSRange(part)
      if touched.intersects(integersIn: part) { uncolor(range) }
      color(range)
    }
    touched.formUnion(set)
    fresh.formUnion(set)
  }

  private func color(_ range: NSRange) {
    guard range.length > 0 else { return }
    let manager = textView.textContentManager
    let layoutManager = textView.textLayoutManager
    for span in roles(range) {
      guard let color = colors[span.role], let textRange = NSTextRange(span.range, in: manager)
      else { continue }
      layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
    }
  }

  private func uncolor(_ range: NSRange) {
    guard range.length > 0, let textRange = NSTextRange(range, in: textView.textContentManager)
    else { return }
    textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
  }
}
