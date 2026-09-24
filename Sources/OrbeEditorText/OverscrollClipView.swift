import AppKit

/// 最終行を最上段までスクロールできる clip view（VS Code の scrollBeyondLastLine）。スクロールできる縦の上限を
/// 「文書の高さ − clip の高さ」と「最終行の上端」の大きい方に広げる。文書の高さ（テキスト view の frame。上流が layout の
/// 事実として読む）には触れない。最終行より下の空き地は clip view の地で、そこの押下はテキスト view へ渡す——上流は
/// 本文の外の点を末尾の位置として解くので、キャレットは文書の末尾へ行き、そのままドラッグで選択が伸びる。
final class OverscrollClipView: NSClipView {
  /// 最終行の上端（documentView の座標）。面が行の矩形から答える。
  var lastLineTop: () -> CGFloat? = { nil }

  /// 縦のスクロールの上限。
  var maximumY: CGFloat {
    let documentHeight = documentView?.frame.height ?? 0
    return max(0, documentHeight - bounds.height, lastLineTop() ?? 0)
  }

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    if proposedBounds.minY > rect.minY {
      rect.origin.y = max(rect.minY, min(proposedBounds.minY, maximumY))
    }
    return rect
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let result = super.hitTest(point)
    guard result === self, let documentView else { return result }
    let local = convert(point, from: superview)
    return local.y >= documentView.frame.maxY ? documentView : result
  }
}
