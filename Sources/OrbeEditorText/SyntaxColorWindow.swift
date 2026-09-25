import AppKit
import OrbeEditorCore
import STTextView

/// 構文の色の窓。色は上流が layout した範囲（見えている範囲と上下の先読みの帯）にだけ置き、外れた範囲の色は外す——全文に
/// 色を置くと、色を 1 か所変えるたびに文書全体の属性の表が動き、打鍵もスクロールも文書の大きさに比例して重くなる。
/// 不変条件: 色は窓の中にしか無く、窓の中の色は常に文書の今の役割と一致する。役割は面の delegate（文書）に問い合わせる。
@MainActor
final class SyntaxColorWindow {
  private let textView: STTextView
  private let colors: [SyntaxRole: NSColor]
  /// 区間の役割（面が delegate へ問い合わせる）。
  var roles: (NSRange) -> [HighlightSpan] = { _ in [] }
  /// 色が付いていて、それが文書の今の役割と一致する区間（最後に塗った窓）。この外に色は無い。
  private var colored = NSRange(location: 0, length: 0)

  init(textView: STTextView, colors: [SyntaxRole: NSColor]) {
    self.textView = textView
    self.colors = colors
  }

  /// layout の後、色を窓に合わせる——窓から外れた部分の色を外し、まだ塗っていない部分を塗る（遠くへ飛べば窓ごと
  /// 入れ替わる）。
  func layoutDidChange(_ range: NSTextRange) {
    let manager = textView.textContentManager
    let window = NSRange(range, in: manager)
    guard window != colored else { return }
    let locator = TextLocator(
      manager: manager, anchor: range.location, anchorOffset: window.location)
    for part in colored.subtracting(window) { uncolor(part, locator) }
    for part in window.subtracting(colored) { color(part, locator) }
    colored = window
    textView.needsLayout = true
  }

  /// 編集の後、窓を丸ごと問い合わせ直して塗る（文書は編集の通知で構文木を更新し終えている）——隣の字の変化で役割が
  /// 変わる字（呼び出しでなくなった識別子・引用符の後ろ）を画面に残さない。窓は編集に沿って写し、大きな置き換えでも前の
  /// 窓の 2 倍までに留める（全文を塗らない。正確な窓は次の layout が決める）。色の外し残しを作らないよう、前の窓の色は
  /// 写した先と元の位置の両方で外す。`anchor` は編集の位置（`edit.range.location`）。
  func textDidChange(_ edit: TextEdit, near anchor: NSTextLocation) {
    let manager = textView.textContentManager
    let length = NSRange(manager.documentRange, in: manager).length
    let moved = colored.tracking(edit).clamped(to: length)
    let window = NSRange(
      location: moved.location, length: min(moved.length, max(colored.length * 2, 1)))
    let locator = TextLocator(manager: manager, anchor: anchor, anchorOffset: edit.range.location)
    uncolor(NSUnionRange(moved, colored.clamped(to: length)), locator)
    color(window, locator)
    colored = window
    textView.needsLayout = true
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
  /// `other` に入らない部分（0〜2 個。昇順）。
  func subtracting(_ other: NSRange) -> [NSRange] {
    let tail = Swift.max(location, NSMaxRange(other))
    return [
      NSRange(location: location, length: Swift.min(NSMaxRange(self), other.location) - location),
      NSRange(location: tail, length: NSMaxRange(self) - tail),
    ].filter { $0.length > 0 }
  }

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
