import AppKit
import XCTest

@testable import Orbe

/// window レベルの pane 非依存 chrome コマンド配信（`handleWindowKeyCommand`）の overlay／改名編集ガードと、
/// タブのインライン改名（Cmd+R）の確定/取消セマンティクスを固定する。0タブでも届く window コマンドが、
/// パレット/フォーム表示中・改名編集中には暴発しない（＝入力を横取りしない）契約。
///
/// 重要: 実 NSWindow に WindowController を接続するため **libghostty ランタイムを起動する**（GhosttyKit 必須）。
final class WindowControllerWindowCommandTests: XCTestCase {

  // 永続を実 Application Support から隔離する（テストごとに未作成の一時ファイルを指す）。
  private var tempStore: URL!
  override func setUp() {
    super.setUp()
    tempStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-test-\(UUID().uuidString).json")
    WorkspacePersistence.fileURLOverride = tempStore
    SettingsPersistence.fileURLOverride = tempStore.appendingPathExtension("settings")
    AppStatePersistence.fileURLOverride = tempStore.appendingPathExtension("appstate")
  }
  override func tearDown() {
    WorkspacePersistence.fileURLOverride = nil
    SettingsPersistence.fileURLOverride = nil
    AppStatePersistence.fileURLOverride = nil
    try? FileManager.default.removeItem(at: tempStore)
    super.tearDown()
  }

  /// 単一 leaf タブを持つ workspace をディスクへ書いてから復元済み WindowController を返す。
  private func restoreSingleTab() throws -> WindowController {
    let file = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "main", rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)])
      ])
    try JSONEncoder().encode(file).write(to: tempStore)
    // preferredLanguage を確定させ、初回言語選択 overlay（languageSelect）で overlay==.none の前提が
    // 崩れないようにする（returning user 化）。
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))
    return WindowController()
  }

  /// overlay 非表示なら window コマンドを消費（true）し、実際に dispatch する（＝newTab でタブが増える）。
  func testWindowKeyCommandDispatchesWhenNoOverlay() throws {
    let wc = try restoreSingleTab()
    XCTAssertEqual(wc.presentedOverlay, .none, "前提: overlay 非表示")
    let before = wc.current.tabs.count
    XCTAssertTrue(wc.handleWindowKeyCommand(.newTab), "overlay 非表示なら横取りして true を返す")
    XCTAssertEqual(wc.current.tabs.count, before + 1, "newTab が dispatch されタブが1枚増える")
  }

  /// overlay（パレット/フォーム）表示中は window コマンドを横取りせず false を返し、dispatch もしない。
  /// パレット入力中の ⌘T 等の暴発を防ぐ（キーは subtree/keyDown へ流れる）。
  func testWindowKeyCommandInertWhileOverlayShowing() throws {
    let wc = try restoreSingleTab()
    wc.showWorkspaceCreate()  // overlay を .workspaceCreate に立てる
    XCTAssertNotEqual(wc.presentedOverlay, .none, "前提: overlay 表示中")
    let before = wc.current.tabs.count
    XCTAssertFalse(wc.handleWindowKeyCommand(.newTab), "overlay 表示中は横取りせず false を返す")
    XCTAssertEqual(wc.current.tabs.count, before, "newTab は dispatch されない（暴発防止）")
  }

  /// インライン改名（Cmd+R）は overlay を出さないが、編集中は window コマンドを横取りせず false を返す。
  /// 旧実装で `overlay == .tabRename` が守っていた暴発防止が、新設の `editingIndex == nil` ガードへ
  /// 移った分岐を固定する（overlay 版と対の非対称を埋める）。
  func testWindowKeyCommandInertWhileRenaming() throws {
    let wc = try restoreSingleTab()
    wc.beginTabRename()  // editingIndex を立てる（overlay は .none のまま）
    XCTAssertEqual(wc.presentedOverlay, .none, "前提: 改名は overlay を出さない")
    XCTAssertNotNil(wc.statusModel.editingIndex, "前提: 改名編集中")
    let before = wc.current.tabs.count
    XCTAssertFalse(wc.handleWindowKeyCommand(.newTab), "改名編集中は横取りせず false を返す")
    XCTAssertEqual(wc.current.tabs.count, before, "newTab は dispatch されない（暴発防止）")
  }

  /// `beginTabRename` が編集状態を立てる: editingIndex＝active・editingText＝現在の表示名・focusToken 前進。
  func testBeginTabRenameSeedsEditingState() throws {
    let wc = try restoreSingleTab()
    let token = wc.statusModel.editFocusToken
    let display = wc.current.tabs[0].displayTitle(workspaceRoot: wc.current.rootPath)
    wc.beginTabRename()
    XCTAssertEqual(wc.statusModel.editingIndex, wc.current.active, "編集 index は active タブ")
    XCTAssertEqual(wc.statusModel.editingText, display, "編集テキストは現在の表示名でプリフィル")
    XCTAssertEqual(wc.statusModel.editFocusToken, token &+ 1, "focus トークンが前進")
  }

  /// 確定は前後空白を trim して `explicitTitle` に載せ、編集を畳む（editingIndex を nil に）。
  func testCommitRenameTrimsAndClearsEditing() throws {
    let wc = try restoreSingleTab()
    wc.beginTabRename()
    wc.statusModel.onCommitRename("  Build  ")
    XCTAssertEqual(wc.current.tabs[0].explicitTitle, "Build", "前後空白は trim して確定")
    XCTAssertNil(wc.statusModel.editingIndex, "確定で編集を畳む")
  }

  /// 空（空白のみ）確定は明示名を解除し派生名②③へ戻す（`explicitTitle = nil`）。
  func testCommitEmptyRenameClearsExplicitTitle() throws {
    let wc = try restoreSingleTab()
    wc.current.tabs[0].explicitTitle = "Old"
    wc.beginTabRename()
    wc.statusModel.onCommitRename("   ")
    XCTAssertNil(wc.current.tabs[0].explicitTitle, "空確定は明示名を解除（派生名へ戻す）")
    XCTAssertNil(wc.statusModel.editingIndex, "確定で編集を畳む")
  }

  /// 取消は編集を畳むだけで明示名は変えない。
  func testCancelRenameClearsEditingOnly() throws {
    let wc = try restoreSingleTab()
    wc.current.tabs[0].explicitTitle = "Keep"
    wc.beginTabRename()
    wc.statusModel.onCancelRename()
    XCTAssertNil(wc.statusModel.editingIndex, "取消で編集を畳む")
    XCTAssertEqual(wc.current.tabs[0].explicitTitle, "Keep", "取消は明示名を変えない")
  }
}
