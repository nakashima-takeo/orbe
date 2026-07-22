import AppKit

/// アプリのメインメニュー。Orbe は端末ホストで chrome ショートカットを `SurfaceView.keyDown` が
/// 先取りするため長らくメニュー無しだったが、そのままだと標準編集コマンド（⌘V/⌘C/⌘X/⌘A）が
/// オーバーレイの入力欄（field editor）へ届かない——これらは Edit メニューの key equivalent が
/// responder chain へ `paste:` 等を配る仕組みに依存するため。標準 Edit メニューを据えて根で塞ぐ。
///
/// 端末（`SurfaceView`）が first responder のとき、SurfaceView は `paste:`/`copy:`/`selectAll:` 等を
/// 実装せず responder chain にも該当ハンドラが無いため、これらの項目は自動で無効化され key equivalent は
/// 消費されない＝そのまま `keyDown` → libghostty の端末ペーストへ通る（端末側の ⌘V を壊さない）。
enum MainMenu {
  static func build(appName: String, language: Language) -> NSMenu {
    let main = NSMenu()
    // items[0]＝アプリメニュー（macOS 規約で先頭固定）。
    main.addItem(appMenuItem(appName: appName, language: language))
    main.addItem(editMenuItem(language: language))
    return main
  }

  private static func appMenuItem(appName: String, language: Language) -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: appName)
    menu.addItem(
      withTitle: L10n.format(.menuHide, language, appName),
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h")
    let hideOthers = menu.addItem(
      withTitle: L10n.string(.menuHideOthers, language),
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(
      withTitle: L10n.string(.menuShowAll, language),
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: L10n.format(.menuQuit, language, appName),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    item.submenu = menu
    return item
  }

  /// 標準編集メニュー（取り消す/やり直す・カット/コピー/ペースト・すべてを選択）。target=nil で
  /// responder chain へ配り、autoenablesItems（既定 true）が first responder に応じて有効/無効を決める。
  private static func editMenuItem(language: Language) -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: L10n.string(.menuEdit, language))
    menu.addItem(
      withTitle: L10n.string(.menuUndo, language), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = menu.addItem(
      withTitle: L10n.string(.menuRedo, language), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(.separator())
    menu.addItem(
      withTitle: L10n.string(.menuCut, language), action: #selector(NSText.cut(_:)),
      keyEquivalent: "x")
    menu.addItem(
      withTitle: L10n.string(.menuCopy, language), action: #selector(NSText.copy(_:)),
      keyEquivalent: "c")
    menu.addItem(
      withTitle: L10n.string(.menuPaste, language), action: #selector(NSText.paste(_:)),
      keyEquivalent: "v")
    menu.addItem(NSMenuItem.separator())
    menu.addItem(
      withTitle: L10n.string(.menuSelectAll, language),
      action: #selector(NSResponder.selectAll(_:)),
      keyEquivalent: "a")
    item.submenu = menu
    return item
  }
}
