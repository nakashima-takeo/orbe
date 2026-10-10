import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 未保存を捨てる前の確認の解決規則（1 か所）と、それを使う入口——ファイルタブの ×・人の操作で連の最後のタブを閉じる・
/// workspace を閉じる——が、未保存のときだけ sheet を出し、連の途中のタブ・シェル終了・制御 API では問わないこと。
///
/// 壊れると何が起きるか。⌘W が未保存の編集を無言で捨てる。保存が外部変更で失敗したのにタブが消える。
/// エディターが残る連の途中のタブを閉じるたびに確認が出る。シェル終了のたびに確認が出てプロセスの後始末が止まる。
@MainActor
final class UnsavedGateTests: OrbeTestCase {
  var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  private func session() -> EditorSession {
    EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
  }

  func edit(_ document: EditorDocument, _ text: String = "x") {
    document.surface.responder.perform(Selector(("insertText:")), with: text)
  }

  // MARK: - 解決の規則

  func testProceedSavesDiscardsOrCancels() throws {
    let session = session()
    let a = try session.open(repo.url("a.txt"), as: .pinned)
    edit(a)
    XCTAssertEqual(session.documentsToDiscard().map(\.url), [a.url])

    XCTAssertFalse(UnsavedGate.proceed(.alertThirdButtonReturn, discarding: [a]), "キャンセル")
    XCTAssertTrue(a.isDirty)
    XCTAssertTrue(UnsavedGate.proceed(.alertSecondButtonReturn, discarding: [a]), "保存しない")
    XCTAssertTrue(a.isDirty, "捨てるかは呼び手が決める（文書は触らない）")
    XCTAssertTrue(UnsavedGate.proceed(.alertFirstButtonReturn, discarding: [a]), "保存")
    XCTAssertFalse(a.isDirty)
    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "xone\n")
  }

  /// 保存が外部変更で失敗すれば進まない（印は立ったまま。⌘S の上書き確認へ）。
  func testProceedRefusesWhenASaveFailsOnDiskChange() throws {
    let session = session()
    let a = try session.open(repo.url("a.txt"), as: .pinned)
    edit(a)
    try repo.write("a.txt", "outside\n")
    XCTAssertFalse(UnsavedGate.proceed(.alertFirstButtonReturn, discarding: [a]))
    XCTAssertTrue(a.isDirty)
    XCTAssertTrue(a.isDiskChanged, "失敗した文書には印が立つ")
    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "outside\n", "触らない")
  }

  func testAlertsCarryTheCountAndTheButtons() {
    let one = UnsavedGate.alert(count: 1, language: .en)
    XCTAssertTrue(one.informativeText.hasPrefix("1 document has"))
    XCTAssertEqual(one.buttons.map(\.title), ["Save", "Don't Save", "Cancel"])
    XCTAssertEqual(one.buttons[2].keyEquivalent, "\u{1b}", "Esc はキャンセル")
    let many = UnsavedGate.alert(count: 3, language: .ja)
    XCTAssertTrue(many.informativeText.hasPrefix("3 件"))
    let overwrite = UnsavedGate.overwriteAlert(language: .en)
    XCTAssertEqual(overwrite.buttons.map(\.title), ["Overwrite", "Cancel"])
    XCTAssertEqual(overwrite.buttons[0].keyEquivalent, "", "上書きは Return で確定しない（戻せない側）")
    XCTAssertEqual(overwrite.buttons[1].keyEquivalent, "\u{1b}", "Esc はキャンセル")
    XCTAssertTrue(UnsavedGate.shouldOverwrite(.alertFirstButtonReturn))
    XCTAssertFalse(UnsavedGate.shouldOverwrite(.alertSecondButtonReturn))
  }

  // MARK: - 入口: タブを閉じる

  func restore(_ tabs: [TabState]) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: repo.root, activeTab: 0, tabs: tabs)])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// 人の操作（⌘W・中クリック）は、連の最後のタブを閉じるときだけ未保存を sheet で確認し、保存しないで閉じる。
  /// 連の途中のタブは問わない（連のエディターは残る）。
  func testGestureCloseAsksOnlyForTheLastTabOfTheGroup() throws {
    let wc = try restore([
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
    ])
    let tabs = wc.current.tabs
    XCTAssertTrue(tabs[0].group === tabs[2].group, "前提: 同じ連")
    edit(try tabs[0].group.editor.open(repo.url("a.txt"), as: .pinned))

    wc.closeTab(tabs[0], origin: .gesture)
    XCTAssertNil(wc.window.attachedSheet, "連の途中は問わない")
    XCTAssertEqual(wc.current.tabs.count, 2)
    wc.closeTab(tabs[1], origin: .process)
    XCTAssertEqual(wc.current.tabs.count, 1)

    wc.closeTab(tabs[2], origin: .gesture)
    XCTAssertEqual(wc.current.tabs.count, 1, "最後のタブは未保存なら即座には閉じない")
    let sheet = try XCTUnwrap(wc.window.attachedSheet, "確認の sheet が出る")
    wc.window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
    XCTAssertEqual(wc.current.tabs.count, 1, "キャンセルで残る")

    wc.closeTab(tabs[2], origin: .gesture)
    wc.window.endSheet(try XCTUnwrap(wc.window.attachedSheet), returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(wc.current.tabs.count, 0, "保存しないで閉じる")
  }

  /// シェル終了で連の最後のタブが閉じても確認しない（未保存は黙って捨てる）。
  func testProcessCloseOfTheLastTabDoesNotAsk() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    let tab = try XCTUnwrap(wc.activeTab)
    edit(try tab.group.editor.open(repo.url("a.txt"), as: .pinned))

    wc.closeTab(tab, origin: .process)
    XCTAssertNil(wc.window.attachedSheet, "シェル終了は確認しない")
    XCTAssertEqual(wc.current.tabs.count, 0)
  }

  /// 保存を選んで外部変更で失敗すれば閉じない。
  func testGestureCloseStaysWhenTheSaveFails() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    let tab = try XCTUnwrap(wc.activeTab)
    let document = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    edit(document)
    try repo.write("a.txt", "outside\n")

    wc.closeTab(tab, origin: .gesture)
    wc.window.endSheet(try XCTUnwrap(wc.window.attachedSheet), returnCode: .alertFirstButtonReturn)
    XCTAssertEqual(wc.current.tabs.count, 1, "保存に失敗したので閉じない")
    XCTAssertTrue(document.isDiskChanged)
  }

  /// workspace の削除は配下の全連の未保存を合計して 1 回確認する。制御 API は確認しない。
  func testClosingAWorkspaceAsksOnceForAllItsTabs() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    wc.createWorkspace(name: "other", rootPath: repo.root)
    let index = wc.activeWorkspace
    let tab = try XCTUnwrap(wc.activeTab)
    edit(try tab.group.editor.open(repo.url("a.txt"), as: .pinned))

    wc.closeWorkspace(index, origin: .gesture)
    XCTAssertEqual(wc.regularWorkspaces.count, 2)
    wc.window.endSheet(try XCTUnwrap(wc.window.attachedSheet), returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(wc.regularWorkspaces.count, 1, "保存しないで閉じる")

    wc.createWorkspace(name: "third", rootPath: repo.root)
    edit(try XCTUnwrap(wc.activeTab).group.editor.open(repo.url("a.txt"), as: .pinned))
    wc.closeWorkspace(wc.activeWorkspace, origin: .controlAPI)
    XCTAssertNil(wc.window.attachedSheet)
    XCTAssertEqual(wc.regularWorkspaces.count, 1, "制御 API は黙って捨てる")
  }

  /// 終了の関門が集める未保存は全 workspace の全連。
  func testUnsavedDocumentsSpanAllWorkspaces() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    edit(try XCTUnwrap(wc.activeTab).group.editor.open(repo.url("a.txt"), as: .pinned))
    wc.createWorkspace(name: "other", rootPath: repo.root)
    try repo.write("b.txt", "b\n")
    edit(try XCTUnwrap(wc.activeTab).group.editor.open(repo.url("b.txt"), as: .pinned))
    XCTAssertEqual(Set(wc.unsavedDocuments().map(\.url.lastPathComponent)), ["a.txt", "b.txt"])
  }

  // MARK: - 入口: ファイルタブの ×

  func testFileTabCloseAsksOnlyWhenDirty() throws {
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.group.view
    tab.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    defer { window.orderOut(nil) }
    let pane = tab.group.view.editor
    try repo.write("b.txt", "b\n")
    let a = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    let b = try tab.group.editor.open(repo.url("b.txt"), as: .pinned)

    pane.shell.requestClose(b.url)
    XCTAssertEqual(tab.group.editor.documents.count, 1, "未保存でなければそのまま閉じる")
    XCTAssertNil(window.attachedSheet)

    edit(a)
    pane.shell.requestClose(a.url)
    XCTAssertEqual(tab.group.editor.documents.count, 1, "未保存なら確認")
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
    XCTAssertTrue(tab.group.editor.documents.isEmpty, "保存して閉じる")
    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "xone\n")
  }

  // MARK: - 入口: ⌘S の上書き

  /// 印の立った文書の ⌘S は上書き確認を sheet で出し、キャンセルならディスクを触らず、上書きなら本文で置き換えて
  /// 印が落ちる。上書きされるのは確認を出した文書——sheet の間に別の文書を開いて焦点が移っても変わらない。
  func testCommandSOverwritesOnlyTheDocumentThatWasConfirmed() throws {
    let tab = TerminalTab.alone(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.group.view
    tab.group.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    defer { window.orderOut(nil) }
    let pane = tab.group.view.editor
    let a = try tab.group.editor.open(repo.url("a.txt"), as: .pinned)
    window.makeFirstResponder(a.surface.responder)
    edit(a)
    try repo.write("a.txt", "outside\n")

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    let sheet = try XCTUnwrap(window.attachedSheet, "外部変更で失敗すれば上書き確認")
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(
      try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "outside\n", "キャンセルは触らない")
    XCTAssertTrue(a.isDirty)

    XCTAssertTrue(pane.performKeyEquivalent(with: .key("s")))
    try repo.write("b.txt", "b\n")
    let b = try tab.group.editor.open(repo.url("b.txt"), as: .pinned)  // sheet の間にエージェントが別の文書を開く
    XCTAssertTrue(tab.group.editor.activeDocument === b)
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
    XCTAssertEqual(
      try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "xone\n", "同意した文書を上書き")
    XCTAssertFalse(a.isDirty)
    XCTAssertFalse(a.isDiskChanged, "印が落ちる")
    XCTAssertEqual(try String(contentsOf: repo.url("b.txt"), encoding: .utf8), "b\n", "焦点の文書は触らない")
  }

  // MARK: - 復元

  func testRestoreOpensReadablePathsAndPicksTheActive() throws {
    let session = session()
    try repo.write("b.txt", "b\n")
    var changes = 0
    session.onChange = { changes += 1 }
    session.restore(
      paths: [repo.url("a.txt").path, repo.root + "/missing.txt", repo.url("b.txt").path],
      active: repo.url("a.txt").path, preview: repo.url("b.txt").path)
    XCTAssertEqual(
      session.documents.map(\.url.lastPathComponent), ["a.txt", "b.txt"], "読めないパスは落ちる")
    XCTAssertEqual(session.activeDocument?.url, repo.url("a.txt"))
    XCTAssertEqual(session.preview?.url, repo.url("b.txt"), "仮のタブは仮のまま戻る")
    XCTAssertEqual(changes, 1, "通知は 1 本")

    let other = self.session()
    other.restore(
      paths: [repo.url("b.txt").path], active: repo.root + "/gone.txt",
      preview: repo.root + "/missing.txt")
    XCTAssertEqual(other.activeDocument?.url, repo.url("b.txt"), "アクティブが落ちていれば先頭")
    XCTAssertNil(other.preview, "仮のタブが落ちていれば仮無し")
  }

  /// materialize より先に `open_file` が開いた文書は、復元に焦点を奪われず、仮のタブにも下がらない。
  func testRestoreKeepsADocumentOpenedBeforeIt() throws {
    let session = session()
    try repo.write("b.txt", "b\n")
    try repo.write("c.txt", "c\n")
    let c = try session.open(repo.url("c.txt"), as: .pinned)
    session.restore(
      paths: [repo.url("a.txt").path, repo.url("b.txt").path, repo.url("c.txt").path],
      active: repo.url("b.txt").path, preview: repo.url("c.txt").path)
    XCTAssertEqual(session.documents.map(\.url.lastPathComponent), ["c.txt", "a.txt", "b.txt"])
    XCTAssertTrue(session.activeDocument === c, "先に居た焦点を保つ")
    XCTAssertNil(session.preview, "先に普通に開いていた文書は仮に下げない")
  }
}
