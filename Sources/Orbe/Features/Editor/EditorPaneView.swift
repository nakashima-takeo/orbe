import AppKit
import SwiftUI

/// エディター面の SwiftUI ルート。地は chrome と同じ veil（`ChromeTranslucency`）で塗り、
/// 器の中の別 root なので環境は明示注入する。
struct EditorFaceRoot: View {
  let translucency: ChromeTranslucency
  let localization: LocalizationStore

  var body: some View {
    EditorEmptyView()
      .background(translucency.baseFill)
      .environment(\.chromeTranslucency, translucency)
      .environment(\.localization, localization)
  }
}

/// エディター面の AppKit 側の根。焦点を受ける responder で、chrome キーのうち window コマンドは
/// タブ経由で上位へ届け、面固有の端末キー（検索・スクロール・フォント）と通常キーは飲む——
/// エディター焦点中に端末へ届けない。中身（SwiftUI）をホストする。
final class EditorPaneView: NSView {
  weak var tab: TerminalTab?
  private let host: NSHostingView<EditorFaceRoot>

  override init(frame: NSRect) {
    host = NSHostingView(
      rootView: EditorFaceRoot(
        translucency: ChromeTranslucency(),
        localization: LocalizationStore(language: .systemDefault)))
    super.init(frame: frame)
    // SwiftUI 背景の alpha を窓まで通す（透過時に不透明ラスタで塞がない）。
    host.wantsLayer = true
    host.layer?.isOpaque = false
    host.autoresizingMask = [.width, .height]
    host.frame = bounds
    addSubview(host)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// 窓の環境（透過・言語）を root へ配る。
  func configure(translucency: ChromeTranslucency, localization: LocalizationStore) {
    host.rootView = EditorFaceRoot(translucency: translucency, localization: localization)
  }

  override var acceptsFirstResponder: Bool { true }

  /// 中身は静止した空状態なので、面のどこを押しても面自身が受ける（焦点を取る）。
  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point).map { _ in self }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }

  override func becomeFirstResponder() -> Bool {
    tab?.paneDidFocus(.editor)
    return super.becomeFirstResponder()
  }

  override func keyDown(with event: NSEvent) {
    if let command = Keybindings.chromeAction(for: event)?.windowCommand {
      tab?.requestWindowCommand(command)
    }
  }
}
