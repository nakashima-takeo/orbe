import AppKit
import OrbeEditorCore
import XCTest

@testable import Orbe

/// 未保存を捨てる前の確認の解決規則（1 か所）と、それを使う入口——ファイルタブの ×・人の操作でタブを閉じる・
/// workspace を閉じる——が、未保存のときだけ sheet を出し、シェル終了・制御 API では黙って捨てること。
///
/// 壊れると何が起きるか。⌘W が未保存の編集を無言で捨てる。保存が外部変更で失敗したのにタブが消える。
/// シェル終了のたびに確認が出てプロセスの後始末が止まる。
@MainActor
final class UnsavedGateTests: OrbeTestCase {
  private var repo: TempGitRepo!

  override func setUpWithError() throws {
    repo = try TempGitRepo()
  }

  override func tearDownWithError() throws {
    repo.cleanup()
  }

  private func session() -> EditorSession {
    EditorSession(surfaces: EditorSurfaces(queriesRoot: nil))
  }

  private func edit(_ document: EditorDocument, _ text: String = "x") {
    document.surface.responder.perform(Selector(("insertText:")), with: text)
  }

  // MARK: - 解決の規則

  func testProceedSavesDiscardsOrCancels() throws {
    let session = session()
    let a = try session.open(repo.url("a.txt"))
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
    let a = try session.open(repo.url("a.txt"))
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

  private func restore(_ tabs: [TabState]) throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [WorkspaceState(name: "main", rootPath: repo.root, activeTab: 0, tabs: tabs)])
    try JSONEncoder().encode(file).write(to: workspacesFile())
    return WindowController()
  }

  /// 人の操作（⌘W・中クリック）は未保存なら sheet で確認し、保存しないで閉じる。
  func testGestureCloseAsksBeforeDiscardingAndProcessCloseDoesNot() throws {
    let wc = try restore([
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
      TabState(cwd: repo.root, agent: nil, explicitTitle: nil),
    ])
    let first = try XCTUnwrap(wc.activeTab)
    let second = wc.current.tabs[1]
    edit(try first.editor.open(repo.url("a.txt")))
    edit(try second.editor.open(repo.url("a.txt")))

    wc.closeTab(first, origin: .gesture)
    XCTAssertEqual(wc.current.tabs.count, 2, "未保存なら即座には閉じない")
    let sheet = try XCTUnwrap(wc.window.attachedSheet, "確認の sheet が出る")
    wc.window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
    XCTAssertEqual(wc.current.tabs.count, 2, "キャンセルで残る")

    wc.closeTab(first, origin: .gesture)
    wc.window.endSheet(try XCTUnwrap(wc.window.attachedSheet), returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(wc.current.tabs.count, 1, "保存しないで閉じる")
    XCTAssertTrue(wc.current.tabs[0] === second)

    wc.closeTab(second, origin: .process)
    XCTAssertNil(wc.window.attachedSheet, "シェル終了は確認しない")
    XCTAssertEqual(wc.current.tabs.count, 0)
  }

  /// 保存を選んで外部変更で失敗すれば閉じない。
  func testGestureCloseStaysWhenTheSaveFails() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    let tab = try XCTUnwrap(wc.activeTab)
    let document = try tab.editor.open(repo.url("a.txt"))
    edit(document)
    try repo.write("a.txt", "outside\n")

    wc.closeTab(tab, origin: .gesture)
    wc.window.endSheet(try XCTUnwrap(wc.window.attachedSheet), returnCode: .alertFirstButtonReturn)
    XCTAssertEqual(wc.current.tabs.count, 1, "保存に失敗したので閉じない")
    XCTAssertTrue(document.isDiskChanged)
  }

  /// workspace の削除は配下の全タブの未保存を合計して 1 回確認する。制御 API は確認しない。
  func testClosingAWorkspaceAsksOnceForAllItsTabs() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    wc.createWorkspace(name: "other", rootPath: repo.root)
    let index = wc.activeWorkspace
    let tab = try XCTUnwrap(wc.activeTab)
    edit(try tab.editor.open(repo.url("a.txt")))

    wc.closeWorkspace(index, origin: .gesture)
    XCTAssertEqual(wc.workspaces.count, 2)
    wc.window.endSheet(try XCTUnwrap(wc.window.attachedSheet), returnCode: .alertSecondButtonReturn)
    XCTAssertEqual(wc.workspaces.count, 1, "保存しないで閉じる")

    wc.createWorkspace(name: "third", rootPath: repo.root)
    edit(try XCTUnwrap(wc.activeTab).editor.open(repo.url("a.txt")))
    wc.closeWorkspace(wc.activeWorkspace, origin: .controlAPI)
    XCTAssertNil(wc.window.attachedSheet)
    XCTAssertEqual(wc.workspaces.count, 1, "制御 API は黙って捨てる")
  }

  /// 終了の関門が集める未保存は全 workspace の全タブ。
  func testUnsavedDocumentsSpanAllWorkspaces() throws {
    let wc = try restore([TabState(cwd: repo.root, agent: nil, explicitTitle: nil)])
    edit(try XCTUnwrap(wc.activeTab).editor.open(repo.url("a.txt")))
    wc.createWorkspace(name: "other", rootPath: repo.root)
    try repo.write("b.txt", "b\n")
    edit(try XCTUnwrap(wc.activeTab).editor.open(repo.url("b.txt")))
    XCTAssertEqual(Set(wc.unsavedDocuments().map(\.url.lastPathComponent)), ["a.txt", "b.txt"])
  }

  // MARK: - 入口: ファイルタブの ×

  func testFileTabCloseAsksOnlyWhenDirty() throws {
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    defer { window.orderOut(nil) }
    let pane = tab.view.editor
    try repo.write("b.txt", "b\n")
    let a = try tab.editor.open(repo.url("a.txt"))
    let b = try tab.editor.open(repo.url("b.txt"))

    pane.shell.requestClose(b.url)
    XCTAssertEqual(tab.editor.documents.count, 1, "未保存でなければそのまま閉じる")
    XCTAssertNil(window.attachedSheet)

    edit(a)
    pane.shell.requestClose(a.url)
    XCTAssertEqual(tab.editor.documents.count, 1, "未保存なら確認")
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
    XCTAssertTrue(tab.editor.documents.isEmpty, "保存して閉じる")
    XCTAssertEqual(try String(contentsOf: repo.url("a.txt"), encoding: .utf8), "xone\n")
  }

  // MARK: - 入口: ⌘S の上書き

  /// 印の立った文書の ⌘S は上書き確認を sheet で出し、キャンセルならディスクを触らず、上書きなら本文で置き換えて
  /// 印が落ちる。上書きされるのは確認を出した文書——sheet の間に別の文書を開いて焦点が移っても変わらない。
  func testCommandSOverwritesOnlyTheDocumentThatWasConfirmed() throws {
    let tab = TerminalTab(cwd: repo.root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = tab.view
    tab.setFaces(FaceLayout(editorRatio: 1, focus: .editor), animated: false)
    defer { window.orderOut(nil) }
    let pane = tab.view.editor
    let a = try tab.editor.open(repo.url("a.txt"))
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
    let b = try tab.editor.open(repo.url("b.txt"))  // sheet の間にエージェントが別の文書を開く
    XCTAssertTrue(tab.editor.activeDocument === b)
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
      active: repo.url("a.txt").path)
    XCTAssertEqual(
      session.documents.map(\.url.lastPathComponent), ["a.txt", "b.txt"], "読めないパスは落ちる")
    XCTAssertEqual(session.activeDocument?.url, repo.url("a.txt"))
    XCTAssertEqual(changes, 1, "通知は 1 本")

    let other = self.session()
    other.restore(paths: [repo.url("b.txt").path], active: repo.root + "/gone.txt")
    XCTAssertEqual(other.activeDocument?.url, repo.url("b.txt"), "アクティブが落ちていれば先頭")
  }
}
