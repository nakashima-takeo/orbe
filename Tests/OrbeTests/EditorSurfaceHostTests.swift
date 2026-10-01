import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// エディター面の pane は焦点の文書の面を載せる側——面が問う「開く・パスの文字列・右クリックのメニュー・URL」に答え、
/// chrome キーを走らせる前に変換を確定する。Finder のファイルは pane が開き、アプリメニューにサービスがある。壊れると
/// ⇧ドロップや Finder のコピーで絶対パスしか入らない、右クリックの文言が英語のまま、変換中の ⌘S で IME が未確定を持ち続ける。
@MainActor
final class EditorSurfaceHostTests: OrbeTestCase {
  func testThePaneAnswersTheSurface() throws {
    let dir = try XCTUnwrap(TestIsolation.caseDir)
    let tab = TerminalTab(cwd: dir.path, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 700)
    defer { window.contentView = nil }
    let pane = tab.view.editor
    pane.configure(
      translucency: ChromeTranslucency(), localization: LocalizationStore(language: .ja),
      fontResolver: ChromeFontResolver(), sidebar: EditorSidebarState())
    let document = try tab.editor.open(try caseFile("a.txt", "x\n"))
    XCTAssertTrue(document.surface.host === pane, "焦点の文書の面を載せる側は pane")
    let inside = dir.appendingPathComponent("src/b c.swift")
    XCTAssertEqual(
      pane.insertionText(forFiles: [inside, URL(fileURLWithPath: "/etc/hosts")]),
      "src/b c.swift /etc/hosts", "根からの相対パス、根の外なら絶対パス、空白区切り")
    let sibling = URL(fileURLWithPath: dir.path + "x/a.swift")
    XCTAssertEqual(
      pane.insertionText(forFiles: [sibling]), sibling.standardizedFileURL.path,
      "根と名前の頭が同じだけの隣のフォルダは根の外")
    XCTAssertEqual(pane.contextMenu().items.map(\.title), ["カット", "コピー", "ペースト"])
    XCTAssertEqual(
      pane.contextMenu().items.map(\.action),
      [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:))])
    XCTAssertTrue(pane.contextMenu().items.allSatisfy { $0.target == nil }, "焦点の面へ届く")

    let other = try caseFile("b.txt", "y\n")
    pane.openFiles([dir, other])
    XCTAssertEqual(tab.editor.activeDocument?.url, other, "フォルダは開かず、ファイルを開く")
    XCTAssertEqual(tab.editor.documents.count, 2)
  }

  /// 変換中に pane が解く chrome キーを押すと、走らせる前に変換を確定する。⌘R（タブの名前。タブに依らない window
  /// コマンドではないので、窓の根でなく pane が解く）は確定する道が pane の 1 か所だけ（⌘S は保存の後の undo の区切りでも
  /// 確定するので、それだけでは区別にならない）。⌘S は見えている本文を保存する——未確定の
  /// 文字は既に本文にある。
  func testChromeKeysCommitTheCompositionFirst() throws {
    let tab = TerminalTab(
      cwd: try XCTUnwrap(TestIsolation.caseDir).path,
      editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = hostEditor(tab, width: 700)
    defer { window.contentView = nil }
    let url = try caseFile("a.swift", "let a = 1\n")
    let document = try tab.editor.open(url)
    XCTAssertTrue(document.surface.responder is InputMethodKeyEquivalents, "面の view は窓の根の口に答える")
    window.makeFirstResponder(document.surface.responder)
    let client = try XCTUnwrap(document.surface.responder as? NSTextInputClient)
    client.setMarkedText(
      "あ", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(client.hasMarkedText())
    XCTAssertTrue(tab.view.editor.performKeyEquivalent(with: .key("r")))
    XCTAssertFalse(client.hasMarkedText(), "chrome キーを走らせる前に確定する")
    client.setMarkedText(
      "あ", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 1))
    XCTAssertTrue(client.hasMarkedText())
    XCTAssertTrue(tab.view.editor.performKeyEquivalent(with: .key("s")))
    XCTAssertFalse(client.hasMarkedText(), "保存の前に確定する")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "あlet a = 1\n", "見えている本文を保存する")
  }

  /// アプリメニューに「サービス」があり、その中身を macOS に渡す。
  func testTheAppMenuHasServices() throws {
    let main = MainMenu.build(appName: "Orbe", language: .ja)
    let services = try XCTUnwrap(MainMenu.servicesMenu(of: main))
    XCTAssertEqual(services.title, "サービス")
    XCTAssertTrue(main.items[0].submenu?.items.contains { $0.submenu === services } == true)
  }
}
