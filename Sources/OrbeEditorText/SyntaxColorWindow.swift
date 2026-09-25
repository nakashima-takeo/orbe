import AppKit
import OrbeEditorCore
import STTextView

/// 構文の色の窓。色は見えている行にだけ塗り、上流が layout した範囲（見えている範囲と上下の先読みの帯）の外の色は外す
/// ——全文に色を置くと、色を 1 か所変えるたびに文書全体の属性の表が動き、打鍵もスクロールも文書の大きさに比例して重くなる。
/// 先読みの帯は、スクロールで見えたとき（clip の bounds の通知。描く前に届く）に塗る。
/// 不変条件: 色は窓の中にしか無く、見えている字の色は常に文書の今の役割と一致する。役割は面の delegate（文書）に問い合わせる。
@MainActor
final class SyntaxColorWindow {
  private let textView: STTextView
  private let colors: [SyntaxRole: NSColor]
  /// 区間の役割（面が delegate へ問い合わせる）。
  var roles: (NSRange) -> [HighlightSpan] = { _ in [] }
  /// 色が付いているかもしれない区間（窓の外に出れば外す）。
  private var touched = IndexSet()
  /// 色が文書の今の役割と一致する区間（`touched` の中）。編集で空になる。
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
    let manager = textView.textContentManager
    let window = NSRange(range, in: manager)
    let inside = IndexSet(integersIn: Range(window) ?? 0..<0)
    let outside = touched.subtracting(inside)
    if !outside.isEmpty {
      let locator = TextLocator(
        manager: manager, anchor: range.location, anchorOffset: window.location)
      for part in outside.rangeView { uncolor(NSRange(part), locator) }
      touched.formIntersection(inside)
      fresh.formIntersection(inside)
    }
    guard let (lines, locator) = visibleLines(in: range) else { return }
    visible = lines
    paint(IndexSet(integersIn: Range(lines) ?? 0..<0).subtracting(fresh), locator)
  }

  /// スクロールした（layout の前）——窓の中で新しく見えた行を塗る（窓の外は続く layout で塗る）。layout は求めない：
  /// 帯の行片の view は、最後の layout で描き直しの対象になったまま、見えるまで描かれない（見えない view は描かない）。
  func scrollDidChange() {
    guard let window = textView.textLayoutManager.textViewportLayoutController.viewportRange,
      let (lines, locator) = visibleLines(in: window), lines != visible
    else { return }
    visible = lines
    let stale = IndexSet(integersIn: Range(lines) ?? 0..<0).subtracting(fresh)
    guard !stale.isEmpty else { return }
    paint(stale, locator)
  }

  /// 編集の後、見えている行を丸ごと問い合わせ直して塗る（文書は編集の通知で構文木を更新し終えている）——隣の字の変化で
  /// 役割が変わる字（呼び出しでなくなった識別子・引用符の後ろ）を画面に残さない。見えている行は編集に沿って写し、大きな
  /// 置き換えでも前の 2 倍までに留める（全文を塗らない。正確な見えている行は続く layout が決め、そこで塗り足す）。帯の色は
  /// 古くなりうるので、見えたときに塗り直す。`anchor` は編集の位置（`edit.range.location`）。
  func textDidChange(_ edit: TextEdit, near anchor: NSTextLocation) {
    let manager = textView.textContentManager
    let length = NSRange(manager.documentRange, in: manager).length
    touched.remove(integersIn: edit.range.location..<NSMaxRange(edit.range))
    touched.shift(
      startingAt: NSMaxRange(edit.range), by: edit.replacementLength - edit.range.length)
    touched.insert(integersIn: edit.newRange.location..<NSMaxRange(edit.newRange))
    fresh = IndexSet()
    let moved = visible.tracking(edit).clamped(to: length)
    visible = NSRange(
      location: moved.location, length: min(moved.length, max(visible.length * 2, 1)))
    paint(
      IndexSet(integersIn: Range(visible) ?? 0..<0),
      TextLocator(manager: manager, anchor: anchor, anchorOffset: edit.range.location))
    textView.needsLayout = true
  }

  /// 窓の行片のうち見えている行の区間と、その先頭を錨にした写し方。見えている行片が無ければ nil。窓の行片だけを見る——
  /// 窓の外の位置は推定で、行片の位置と食い違う。
  private func visibleLines(in window: NSTextRange) -> (NSRange, TextLocator)? {
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
    let manager = textView.textContentManager
    guard let first, let last, let range = NSTextRange(location: first, end: last) else {
      return nil
    }
    let lines = NSRange(range, in: manager)
    return (lines, TextLocator(manager: manager, anchor: first, anchorOffset: lines.location))
  }

  /// 区間を今の役割で塗り直す（前の色は外す）。
  private func paint(_ set: IndexSet, _ locator: TextLocator) {
    for part in set.rangeView {
      let range = NSRange(part)
      if touched.intersects(integersIn: part) { uncolor(range, locator) }
      color(range, locator)
    }
    touched.formUnion(set)
    fresh.formUnion(set)
  }

  private func color(_ range: NSRange, _ locator: TextLocator) {
    guard range.length > 0 else { return }
    let layoutManager = textView.textLayoutManager
    for span in roles(range) {
      guard let color = colors[span.role], let textRange = locator.range(span.range) else {
        continue
      }
      layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
    }
  }

  private func uncolor(_ range: NSRange, _ locator: TextLocator) {
    guard range.length > 0, let textRange = locator.range(range) else { return }
    textView.textLayoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
  }
}

/// 本文のオフセットを TextKit の位置へ、近くの錨からの相対で写す。文書の先頭から数えると（`NSTextRange(_:in:)`）
/// 1 区間ごとに文書の大きさに比例した手間が掛かり、窓の色の区間が多いほど塗りが重くなる。
@MainActor
struct TextLocator {
  let manager: NSTextContentManager
  /// 錨の位置と、そのオフセット。
  let anchor: NSTextLocation
  let anchorOffset: Int

  func range(_ range: NSRange) -> NSTextRange? {
    guard let start = manager.location(anchor, offsetBy: range.location - anchorOffset),
      let end = manager.location(start, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: start, end: end)
  }
}

extension NSRange {
  /// 編集の前の区間を編集の後の本文へ写す。編集より前の端はそのまま、後ろの端は平行移動し、置き換わった部分に掛かる
  /// 端は、始まりなら置き換えの先頭へ、終わりなら置き換えの末尾へ寄せる。
  func tracking(_ edit: TextEdit) -> NSRange {
    let removedEnd = NSMaxRange(edit.range)
    let delta = edit.replacementLength - edit.range.length
    let start =
      location <= edit.range.location
      ? location : location >= removedEnd ? location + delta : edit.range.location
    let end = NSMaxRange(self)
    let movedEnd =
      end <= edit.range.location
      ? end : end >= removedEnd ? end + delta : NSMaxRange(edit.newRange)
    return NSRange(location: start, length: Swift.max(0, movedEnd - start))
  }
}
