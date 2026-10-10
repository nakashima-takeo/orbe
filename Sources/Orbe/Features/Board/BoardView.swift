import AppKit
import SwiftUI

/// ボードの器。workspace が持つ、タブ（端末）ではない面。WindowController が 1 枚だけ持ち、前面の workspace がボードを持つ間
/// タブの器と並べて content に載せ、選んでいる間だけ見せる。
///
/// 焦点の宛先は中身（SwiftUI）にあり、器自身は焦点を受けない。chrome キーはエディター面と同じ作法で受ける——first
/// responder が配下のときだけ解決し（隠れている間も窓に残るので、焦点が無ければ素通しする）、window コマンドは上位へ渡し、
/// 端末・エディター・両面のキーはボードに意味が無いので飲む。中身が握らなかった打鍵も飲む。
final class BoardView: NSView {
  private let host: NSHostingView<BoardRoot>
  /// window コマンドの届け先（WindowController が配線する）。
  var onWindowCommand: (WindowCommand) -> Void = { _ in }

  init(
    model: BoardModel, translucency: ChromeTranslucency, localization: LocalizationStore,
    fontResolver: ChromeFontResolver
  ) {
    host = NSHostingView(
      rootView: BoardRoot(
        model: model, translucency: translucency, localization: localization,
        fontResolver: fontResolver))
    super.init(frame: .zero)
    // SwiftUI の地の alpha を窓まで通す（透過時に不透明ラスタで塞がない）。
    host.wantsLayer = true
    host.layer?.isOpaque = false
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
    // 当て直しのたびにホストへ first responder を渡す（中の宛先は SwiftUI の焦点が決める）。
    model.onFocus = { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self.host)
    }
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// first responder が自分か配下にあるか。
  var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard focusIsInside, let action = Keybindings.chromeAction(for: event)
    else { return super.performKeyEquivalent(with: event) }
    switch action.owner {
    case .window:
      if let command = action.windowCommand { onWindowCommand(command) }
    case .terminal, .editor, .eachFace:
      break
    }
    return true
  }

  override func keyDown(with event: NSEvent) {}
}
