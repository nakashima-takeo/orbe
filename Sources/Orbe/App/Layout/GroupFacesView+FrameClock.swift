import AppKit

/// 器の時計: 引いている間・ばねの動き・ホバーの進みを表示のフレームごとに進める。
extension GroupFacesView {
  private var hoverTarget: CGFloat { handle.isPointerOver || isGrabbing ? 1 : 0 }

  /// 時計が要るか: 引いている間・動きが止まっていない間・ホバーが的に届いていない間。
  var isAnimating: Bool {
    if case .dragging = interaction { return true }
    return !motion.isAtRest(width: bounds.width) || hover != hoverTarget
  }

  func updateClock() {
    if reduceMotion, hover != hoverTarget {
      hover = hoverTarget
      handle.hover = hover
    }
    if isAnimating {
      if clock == nil {
        lastTick = nil
        clock = FrameClock(view: self) { [unowned self] in frame() }
      }
    } else {
      clock?.cancel()
      clock = nil
    }
  }

  private func frame() {
    let now = CACurrentMediaTime()
    tick(dt: CGFloat(now - (lastTick ?? now)))
    lastTick = now
  }

  /// `dt` 秒の 1 フレーム: 動きとホバーを進め、今の状態で置く。動きが止まったら確定する。
  func tick(dt: CGFloat) {
    motion.step(dt: dt, width: bounds.width, goal: committed.shape.hx)
    let rate = dt / CGFloat(Theme.Motion.quick)
    hover =
      hoverTarget > hover ? min(hoverTarget, hover + rate) : max(hoverTarget, hover - rate)
    switch interaction {
    case .dragging:
      let g = dragResolved()
      applySizes(g, siblings: false)
      showDrag(g)
    case .moving where motion.isAtRest(width: bounds.width):
      settle(committed)
    case .settled, .pressed, .moving:
      placeMotion()
    }
    updateClock()
  }

  /// display link 駆動でフレームごとに `tick` を呼ぶ。動きの積分・ホバーの進み・引いている間の resize の間引きが共有する
  /// （引いている間の中身の寸法は、このフレームでだけ配る）。
  final class FrameClock {
    private var link: CADisplayLink?
    private let tick: () -> Void

    init(view: NSView, tick: @escaping () -> Void) {
      self.tick = tick
      link = view.displayLink(target: self, selector: #selector(step))
      link?.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) { tick() }

    func cancel() {
      link?.invalidate()
      link = nil
    }
  }
}
