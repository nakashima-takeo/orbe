import AppKit

/// サイドバーと本体の境に置く 4pt の当たり。掴んだ瞬間に境が描かれている位置（表示幅。切り詰め中は記憶の
/// 幅と違う）を起点に、ポインタの移動ぶんだけ幅を求める（背のドラッグと同じ作法。境のどこを掴んでも
/// 引いた距離だけ動く）。
///
/// カーソルは tracking area の `cursorUpdate` で出す。`.inVisibleRect` の tracking area は view の可視矩形に
/// 自動で追随するので、生成時に 1 つ登録すれば pane の `layout()` が frame を置き直しても再登録が要らない
/// （cursor rect は窓が再計算する契機に依るため、frame の移動後に古い矩形が残りうる）。
final class SidebarResizeHandle: NSView {
  /// ポインタが求めるサイドバーの幅。
  var onDrag: ((CGFloat) -> Void)?
  /// 離した（幅を書き戻す）。
  var onRelease: (() -> Void)?
  private var grab: (x0: CGFloat, width0: CGFloat)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func cursorUpdate(with event: NSEvent) {
    NSCursor.resizeLeftRight.set()
  }

  private func x(in event: NSEvent) -> CGFloat {
    guard let superview else { return 0 }
    return superview.convert(event.locationInWindow, from: nil).x
  }

  override func mouseDown(with event: NSEvent) {
    guard let pane = superview as? EditorPaneView else { return }
    grab = (x(in: event), pane.shownSidebarWidth)
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
