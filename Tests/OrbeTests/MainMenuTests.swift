import AppKit
import XCTest

@testable import Orbe

/// メインメニューの構造検証。標準 Edit メニューが無いと ⌘V/⌘C/⌘X/⌘A がオーバーレイ入力欄へ届かない
/// （key equivalent が responder chain へ `paste:` 等を配る仕組みに依存する）ため、その配線契約を固定する。
/// target=nil（responder chain 配送）と autoenablesItems（first responder に応じた有効化）が肝。
final class MainMenuTests: XCTestCase {

  private func editMenu() -> NSMenu {
    let main = MainMenu.build(appName: "orbe", language: .en)
    // items[0] はアプリメニュー（macOS 規約）。Edit は items[1]。
    guard main.items.count >= 2, let edit = main.items[1].submenu else {
      return NSMenu()
    }
    return edit
  }

  func testEditMenuHasStandardEditingCommandsRoutedToResponderChain() {
    let edit = editMenu()
    XCTAssertTrue(edit.autoenablesItems, "first responder に応じ自動で有効/無効を切り替える")

    let expected: [(key: String, selector: Selector)] = [
      ("x", Selector(("cut:"))),
      ("c", Selector(("copy:"))),
      ("v", Selector(("paste:"))),
      ("a", Selector(("selectAll:"))),
    ]
    for (key, selector) in expected {
      guard let item = edit.items.first(where: { $0.keyEquivalent == key }) else {
        XCTFail("⌘\(key) の項目が無い")
        continue
      }
      XCTAssertEqual(item.action, selector, "⌘\(key) は \(selector) を responder chain へ配る")
      XCTAssertNil(item.target, "target=nil＝first responder（field editor 等）へ配送")
      XCTAssertTrue(
        item.keyEquivalentModifierMask.contains(.command), "⌘ 修飾で発火")
    }
  }

  func testPasteItemIsCommandVOnly() {
    let edit = editMenu()
    guard let paste = edit.items.first(where: { $0.action == Selector(("paste:")) }) else {
      return XCTFail("ペースト項目が無い")
    }
    XCTAssertEqual(paste.keyEquivalent, "v")
    XCTAssertEqual(paste.keyEquivalentModifierMask, [.command], "⌘V（Shift/Opt 無し）")
  }

  /// build(language:) が言語を各 title へ通す（回帰＝language 引数のドロップ / 文言ハードコード）。
  func testMenuTitlesFollowLanguage() {
    func quitTitle(_ language: Language) -> String? {
      let main = MainMenu.build(appName: "Orbe", language: language)
      return main.items[0].submenu?.items
        .first { $0.action == #selector(NSApplication.terminate(_:)) }?.title
    }
    func editMenuTitle(_ language: Language) -> String? {
      MainMenu.build(appName: "Orbe", language: language).items[1].submenu?.title
    }
    XCTAssertEqual(quitTitle(.ja), "Orbeを終了")
    XCTAssertEqual(quitTitle(.en), "Quit Orbe")
    XCTAssertEqual(editMenuTitle(.ja), "編集")
    XCTAssertEqual(editMenuTitle(.en), "Edit")
  }

  /// ⌘H は chrome（ヘルプオーバーレイ）が先取りするため、Hide 項目は無割当で残す
  /// （keyEquivalent を残すとメニュー表記が嘘になる）。⌘⌥H の「ほかを隠す」は従来どおり。
  func testHideItemHasNoKeyEquivalent() {
    let main = MainMenu.build(appName: "Orbe", language: .en)
    guard let appMenu = main.items[0].submenu else {
      return XCTFail("items[0] がアプリメニューでない")
    }
    guard let hide = appMenu.items.first(where: { $0.action == #selector(NSApplication.hide(_:)) })
    else {
      return XCTFail("Hide 項目が無い")
    }
    XCTAssertEqual(hide.keyEquivalent, "", "Hide は無割当（⌘H はヘルプが使う）")
    guard
      let hideOthers = appMenu.items.first(where: {
        $0.action == #selector(NSApplication.hideOtherApplications(_:))
      })
    else {
      return XCTFail("Hide Others 項目が無い")
    }
    XCTAssertEqual(hideOthers.keyEquivalent, "h")
    XCTAssertEqual(hideOthers.keyEquivalentModifierMask, [.command, .option], "⌘⌥H は現状維持")
  }

  func testAppMenuIsFirstAndHasQuit() {
    let main = MainMenu.build(appName: "orbe", language: .en)
    XCTAssertGreaterThanOrEqual(main.items.count, 2, "アプリメニュー＋Edit メニュー")
    guard let appMenu = main.items[0].submenu else {
      return XCTFail("items[0] がアプリメニューでない")
    }
    guard
      let quit = appMenu.items.first(where: { $0.action == #selector(NSApplication.terminate(_:)) })
    else {
      return XCTFail("終了項目が無い")
    }
    XCTAssertEqual(quit.keyEquivalent, "q", "⌘Q で終了")
  }
}
