import AppKit
import SwiftUI

/// エディタペイン本体（ターミナル右隣の Git ワークベンチ・EditorPane v4）。
/// SwiftUI ルート（EditorPaneRoot）を host し、左端スプリッタのドラッグと
/// ⌘/ toggle / Esc フォーカス返しをキー当量で受ける chrome レベルの facade。
final class EditorPane: NSView {
  weak var actions: EditorPaneActions? {
    didSet { model.actions = actions }
  }
  /// ⌘/（ペイン内にフォーカスがあるときの toggle）を上位へ届ける。
  var onToggle: (() -> Void)?
  /// 左端ドラッグで幅が変わった通知（新しい幅）。
  var onWidthChange: ((CGFloat) -> Void)?

  let model = EditorPaneModel()
  private let host: NSHostingView<EditorPaneRoot>
  private let resizeHandle = PaneResizeHandle()

  /// 別 NSHostingView なので背景透過/ブラー・フォント割り当て・現在言語は root へ Environment 注入して
  /// 届ける（WindowController 所有ホルダー）。
  init(
    translucency: ChromeTranslucency, fontResolver: ChromeFontResolver,
    localization: LocalizationStore
  ) {
    model.localization = localization  // モデル側で組む文言（viewerNote 等）を現在言語で引く
    host = NSHostingView(
      rootView: EditorPaneRoot(
        model: model, translucency: translucency, fontResolver: fontResolver,
        localization: localization))
    super.init(frame: .zero)
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
    addSubview(resizeHandle)
    resizeHandle.onDrag = { [weak self] delta in
      guard let self else { return }
      self.onWidthChange?(self.frame.width - delta)
    }
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override func layout() {
    super.layout()
    host.frame = bounds
    // 本体を閉じてレール(32px)のみのときは幅ドラッグを無効化する（隠れた本体幅を触らせない）。
    resizeHandle.frame =
      model.ui.paneOpen ? NSRect(x: 0, y: 0, width: 5, height: bounds.height) : .zero
  }

  /// ペイン内にフォーカスがある間も ⌘/ の toggle を効かせる
  /// （コミット入力の field editor より先に、view ツリー巡回でここが受ける）。
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if Keybindings.chromeAction(for: event) == .toggleEditorPane {
      onToggle?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    actions?.focusTerminal()
  }
}

/// 左端のリサイズハンドル。ドラッグ中の x 差分を通知する（視覚はスプリッタが SwiftUI 側で描く）。
final class PaneResizeHandle: NSView {
  var onDrag: ((CGFloat) -> Void)?

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDragged(with event: NSEvent) {
    onDrag?(event.deltaX)
  }
}
