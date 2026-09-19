import AppKit
import SwiftUI

/// 信号機（close ボタン）が chrome の上にあるか・あるならその縦位置を実窓から読み、`StatusRowModel`
/// へ反映する極小 representable。信号機は実窓にしか無い system furniture なので、ここだけ実窓を読む。
/// 付けるのは製品の殻（`AppShell`）だけ——見本系（preview・gallery）は読まず既定値で決定的に描く。
struct TrafficLightsProbe: NSViewRepresentable {
  let model: StatusRowModel
  func makeNSView(context: Context) -> NSView { ProbeView(model: model) }
  func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ProbeView)?.sync() }
}

private final class ProbeView: NSView {
  let model: StatusRowModel

  init(model: StatusRowModel) {
    self.model = model
    super.init(frame: .zero)
    // フルスクリーン遷移の最中は layout と AppKit のボタン移動の前後関係が不定なので、幾何が確定する
    // did 通知でも読み直す。窓移動ごとの解除・再登録を持たずに済むよう object: nil で 1 度だけ登録し、
    // handler が自窓に絞る。
    for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(fullScreenDidChange(_:)), name: name, object: nil)
    }
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    sync()
  }
  override func layout() {
    super.layout()
    sync()
  }

  @objc private func fullScreenDidChange(_ notification: Notification) {
    guard let transitioned = notification.object as? NSWindow, transitioned === window else {
      return
    }
    sync()
  }

  func sync() {
    let placement = Self.placement(in: window)
    // レイアウト経路から observable を直接触ると更新サイクルと衝突しうるため次の run loop へ逃がす。
    DispatchQueue.main.async { [model] in
      if model.trafficLights != placement { model.trafficLights = placement }
    }
  }

  /// 信号機が自窓の chrome の上にあるか、あるなら close ボタン中央の contentView 上端からの距離
  /// （chrome は contentView 上端に密着するのでそのまま上段の縦整列に使える）。
  /// ネイティブ・フルスクリーン中、AppKit は close ボタンを上端の帯（別窓）へ移す。移っても superview は
  /// 残るため、自窓に居るか（`close.window === window`）で在否を見分ける。
  private static func placement(in window: NSWindow?) -> TrafficLights {
    guard let window, let content = window.contentView,
      let close = window.standardWindowButton(.closeButton), close.window === window
    else { return .absent }
    let r = close.convert(close.bounds, to: content)
    return .over(centerY: content.isFlipped ? r.midY : content.bounds.height - r.midY)
  }
}
