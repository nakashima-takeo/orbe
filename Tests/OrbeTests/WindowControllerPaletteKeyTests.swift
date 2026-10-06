import AppKit
import XCTest

@testable import Orbe

/// 主窓に開いたパレットの入力欄へ、実 `NSEvent` を `NSApp.sendEvent` で届けたときのキーの行き先を、実
/// `WindowController` の窓で固定する。
///
/// 壊れると何が起きるか: 日本語の変換中に ↓ で候補を選ぼうとするとパレットの行が動き、esc で変換を取り消そうと
/// するとパレットが閉じて打った内容が消え、⌫ で未確定の文字を消そうとすると選んでいる行の上書きが外れる。設定
/// パレットの「この workspace」で ⌫ を押しても上書きが外れない。絞り込みの文字を消そうとした ⌫ で上書きが外れる。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerPaletteKeyTests: OrbeTestCase {
  private enum Key {
    static let backspace: UInt16 = 51
    static let escape: UInt16 = 53
    static let down: UInt16 = 125
  }

  private var opened: WindowController?

  override func tearDown() {
    opened?.window.orderOut(nil)
    opened = nil
    super.tearDown()
  }

  /// 設定パレットを開いた主窓。焦点は絞り込みの入力欄。
  private func openSettings() throws -> (WindowController, SettingsPaletteModel) {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(cwd: "/tmp", agent: nil, explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    let wc = WindowController()
    opened = wc
    // 非アクティブなアプリの窓は key にならないが、`NSApp.sendEvent` は ordered-in の窓の first responder へ届ける。
    NSApplication.shared.setActivationPolicy(.accessory)
    wc.window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(wc.handleWindowKeyCommand(.showSettings))
    pump(0.6)
    XCTAssertTrue(wc.window.firstResponder is NSTextView, "前提: 焦点は絞り込みの入力欄")
    return (wc, try XCTUnwrap(wc.model.settingsPalette))
  }

  private func pump(_ seconds: TimeInterval = 0.2) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
  }

  private func press(
    _ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
    to wc: WindowController
  ) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wc.window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
    else { return XCTFail("キーイベントを作れない") }
    NSApp.sendEvent(event)
    pump()
  }

  private func down(_ wc: WindowController) {
    press(Key.down, "\u{F701}", [.numericPad, .function], to: wc)
  }

  private func backspace(_ wc: WindowController) {
    press(Key.backspace, "\u{7F}", to: wc)
  }

  /// 未確定の文字を置く（日本語入力の変換中）。
  private func compose(in field: NSTextView) {
    field.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(field.hasMarkedText(), "前提: 変換中")
  }

  /// 「この workspace」スコープで、フォントサイズ行（全行 index 1）を上書きした状態。
  private func overrideFontSize(_ palette: SettingsPaletteModel) {
    palette.render.selected = 0
    palette.render.onActivate()
    palette.render.selected = 1
    _ = palette.render.onRight()
    pump()
    XCTAssertFalse(palette.render.rows[1].inherited, "前提: 上書きしている")
  }

  /// 変換中の文字は絞り込みの文字に入らないので、入力欄は空に見える。それでもキーは変換に使わせ、パレットの器
  /// （↓・esc）にも入力欄（⌫）にも渡さない。
  func testKeysWhileComposingGoToTheInputMethodInsteadOfThePalette() throws {
    let (wc, palette) = try openSettings()
    overrideFontSize(palette)
    down(wc)
    XCTAssertEqual(palette.render.selected, 2, "前提: 変換していなければ ↓ で行が動く")
    palette.render.selected = 1
    let field = try XCTUnwrap(wc.window.firstResponder as? NSTextView)

    compose(in: field)
    backspace(wc)
    XCTAssertFalse(palette.render.rows[1].inherited, "変換中の ⌫ で上書きは外れない")

    compose(in: field)
    down(wc)
    XCTAssertEqual(palette.render.selected, 1, "変換中の ↓ で行は動かない")

    compose(in: field)
    press(Key.escape, "\u{1B}", to: wc)
    XCTAssertEqual(wc.presentedOverlay, .settingsPalette, "変換中の esc でパレットは閉じない")
  }

  /// ⌫ は打った絞り込みの文字を先に消し、入力欄が空のときに押した ⌫ で、選んでいる行の上書きを外してグローバルの
  /// 値に戻す。
  func testBackspaceDeletesTheFilterTextFirstAndRevertsTheOverrideFromTheEmptyFilter() throws {
    let (wc, palette) = try openSettings()
    overrideFontSize(palette)
    press(0, "フ", to: wc)
    XCTAssertEqual(palette.render.query, "フ", "前提: 絞り込みの文字を打った")
    XCTAssertTrue(
      palette.render.rows[palette.render.selected].label.contains("フォントサイズ"),
      "前提: 上書きした行を選んでいる")

    backspace(wc)
    XCTAssertEqual(palette.render.query, "", "まず文字を消す")
    XCTAssertFalse(palette.render.rows[1].inherited, "文字を消した ⌫ では外さない")

    palette.render.selected = 1
    backspace(wc)
    XCTAssertTrue(palette.render.rows[1].inherited, "空の入力欄の ⌫ で外し、グローバルを継承する")
  }
}
