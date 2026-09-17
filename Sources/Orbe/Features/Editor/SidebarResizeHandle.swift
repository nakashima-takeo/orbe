import AppKit

/// サイドバーと本体の境に置く 4pt の当たり。掴んだ瞬間の幅を起点に、ポインタの移動ぶんだけ幅を求める
/// （背のドラッグと同じ作法。境のどこを掴んでも引いた距離だけ動く）。
final class SidebarResizeHandle: NSView {
  /// ポインタが求めるサイドバーの幅。
  var onDrag: ((CGFloat) -> Void)?
  /// 離した（幅を書き戻す）。
  var onRelease: (() -> Void)?
  private var grab: (x0: CGFloat, width0: CGFloat)?

  override var isFlipped: Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  private func x(in event: NSEvent) -> CGFloat {
    guard let superview else { return 0 }
    return superview.convert(event.locationInWindow, from: nil).x
  }

  override func mouseDown(with event: NSEvent) {
    guard let pane = superview as? EditorPaneView else { return }
    grab = (x(in: event), pane.sidebar.width)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let grab else { return }
    onDrag?(grab.width0 + x(in: event) - grab.x0)
  }

  override func mouseUp(with event: NSEvent) {
    guard grab != nil else { return }
    grab = nil
    onRelease?()
  }
}
