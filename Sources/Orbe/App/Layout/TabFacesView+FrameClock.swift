import AppKit

extension TabFacesView {
  /// display link 駆動でフレームごとに `tick` を呼ぶ。動きの積分・ホバーの進み・引いている間の resize の間引きが共有する。
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
