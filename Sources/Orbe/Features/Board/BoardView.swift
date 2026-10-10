import AppKit
import SwiftUI

/// ボードの器。workspace が持つ、タブ（端末）ではない面。WindowController が 1 枚だけ持ち、前面の workspace がボードを持つ間
/// タブの器と並べて content に載せ、選んでいる間だけ見せる。
///
/// キーはエディター面と同じ作法で受ける——first responder が自分か配下のときだけ chrome キーを解決し（隠れている間も窓に
/// 残るので、焦点が無ければ素通しする）、window コマンドは上位へ渡し、端末・エディター・両面のキーはボードに意味が無いので
/// 飲む。通常の打鍵も飲む。
final class BoardView: NSView {
  private let host: NSHostingView<BoardRoot>
  /// window コマンドの届け先（WindowController が配線する）。
  var onWindowCommand: (WindowCommand) -> Void = { _ in }

  init(translucency: ChromeTranslucency, localization: LocalizationStore) {
    host = NSHostingView(
      rootView: BoardRoot(translucency: translucency, localization: localization))
    super.init(frame: .zero)
    // SwiftUI の地の alpha を窓まで通す（透過時に不透明ラスタで塞がない）。
    host.wantsLayer = true
    host.layer?.isOpaque = false
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// first responder が自分か配下にあるか。
  var focusIsInside: Bool {
    guard let responder = window?.firstResponder as? NSView else { return false }
    return responder === self || responder.isDescendant(of: self)
  }

  override var acceptsFirstResponder: Bool { true }

  /// 中身は静止しているので、どこを押しても器自身が受ける（焦点を取る）。
  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) == nil ? nil : self
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
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
