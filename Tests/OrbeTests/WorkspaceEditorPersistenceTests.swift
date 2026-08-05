import AppKit
import XCTest

@testable import Orbe

/// タブ単位の EditorPane 画面状態（TabState.editor）の永続往復と、`editor` を持たない旧 JSON の後方互換。
/// MRU・override と同様、粗粒度フィールドの save→load 往復を個別に固定する。
///
/// `editor` は後から足したフィールドなので、欠落を許容しなければ tab → workspace → ファイル全体と
/// decode 失敗が連鎖し、`load()` が nil を返して**全 workspace が消える**（次の save でディスクからも
/// 消える）。往復だけでなく欠落側も固定するのはそのため。欠落側は実害を host（`WindowController`）でも
/// 見るので、この 1 本だけ実 NSWindow ＋ libghostty を起こす。
final class WorkspaceEditorPersistenceTests: OrbeTestCase {

  /// `tree` を持ち `editor` を持たない v3 JSON（`editor` 導入前に書かれたファイル）。
  private let legacyJSONWithoutEditor = """
    {"version":3,"activeWorkspace":0,"workspaces":[\
    {"name":"a","rootPath":"/","activeTab":0,\
    "tabs":[{"tree":{"leaf":{}},"explicitTitle":"kept"}]},\
    {"name":"b","rootPath":"/","activeTab":0,"tabs":[{"tree":{"leaf":{}}}]}]}
    """

  /// editor の開閉・ツール（非既定値）がディスク往復で保たれる。
  func testEditorTabStateRoundTripThroughFile() {
    let original = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: [
        WorkspaceState(
          name: "w", rootPath: "/", activeTab: 0,
          tabs: [
            TabState(
              tree: .leaf(cwd: "/p", agent: nil), explicitTitle: nil,
              editor: EditorPaneTabState(open: true, tool: "git")),
            TabState(tree: .leaf(cwd: "/q", agent: nil), explicitTitle: nil),
          ])
      ])
    WorkspacePersistence.save(original)
    XCTAssertEqual(
      WorkspacePersistence.load(), original,
      "editor（open:true/tool:git）と既定 editor の混在がディスク往復で保たれる")
  }

  /// `editor` キーを欠いた v3 JSON も load 成功し、当該タブは既定 editor になる。
  /// 欠落で decode が落ちると全 workspace を失うため、後方互換の生命線。
  func testLegacyJSONWithoutEditorLoads() throws {
    try Data(legacyJSONWithoutEditor.utf8).write(to: workspacesFile())
    let loaded = try XCTUnwrap(WorkspacePersistence.load(), "editor 欠落でも load 成功")
    XCTAssertEqual(loaded.workspaces.count, 2, "全 workspace が健在（喪失しない）")
    XCTAssertEqual(
      loaded.workspaces[0].tabs[0].editor, TabState.defaultEditor, "欠落時 editor は既定（閉・tree）")
    XCTAssertEqual(loaded.workspaces[0].tabs[0].explicitTitle, "kept", "同居する明示タイトルも失わない")
    XCTAssertEqual(loaded.workspaces[1].tabs[0].editor, TabState.defaultEditor)
  }

  /// 同じ JSON で起動しても workspace 集合が保たれる（喪失の実害が host 側で消えていることを見る）。
  /// load() が nil を返すと既定の単一 workspace で開き直す＝ユーザーの workspace が全部消える。
  func testLaunchWithoutEditorKeyKeepsAllWorkspaces() throws {
    AppStatePersistence.save(AppStateFile(preferredLanguage: "ja"))  // 初回言語選択を出さない
    try Data(legacyJSONWithoutEditor.utf8).write(to: workspacesFile())

    let wc = WindowController()

    XCTAssertEqual(wc.workspaces.count, 2, "editor 欠落の保存ファイルからでも全 workspace が起きる")
    XCTAssertEqual(wc.workspaces.map(\.name), ["a", "b"], "既定 workspace への作り直しに落ちていない")
  }
}
