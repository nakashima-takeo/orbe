import XCTest

@testable import Orbe

/// 切替パレット末尾の作成導線行 → 専用作成フォーム、という workspace 作成の唯一の入口の配線。
///
/// 壊れると何が起きるか: パレットに打った名前が作成フォームへ届かない（あるいはフォームが開かない）。
/// 入口を 1 本に畳んだ目的そのものが消え、作成のたびに名前を打ち直すことになる。
extension WindowControllerWorkspaceTests {

  /// rootPath と別の cwd を持つタブ 1 枚の workspace を復元した WindowController。
  /// パス既定が「アクティブタブの cwd」か「workspace の rootPath」かを区別できる形にしてある。
  private func restoreTabbedWorkspace() -> WindowController {
    WorkspacePersistence.save(
      WorkspacesFile(
        version: WorkspacePersistence.version, activeWorkspace: 0,
        workspaces: [
          WorkspaceState(
            name: "main", rootPath: "/private/tmp/ws-root", activeTab: 0,
            tabs: [TabState(cwd: "/private/tmp", agent: nil, explicitTitle: nil)])
        ]))
    return WindowController()
  }

  /// 一覧に無い文字列を打って作成導線行を Enter すると、その文字列を名前に持つ作成フォームが
  /// リンク解除で開く。パス欄はアクティブタブの cwd。
  func testTypedNameOpensCreateFormUnlinkedAtActiveTabCwd() throws {
    let wc = restoreTabbedWorkspace()
    wc.showWorkspacePalette()
    let palette = try XCTUnwrap(wc.model.workspacePalette)
    palette.render.query = "zzz-check"  // 既存名に一致しない
    palette.render.onQueryChange()
    palette.render.onActivate()  // 残る唯一の行＝末尾の作成導線行

    XCTAssertEqual(wc.presentedOverlay, .workspaceCreate, "作成フォームへ遷移する")
    let form = try XCTUnwrap(wc.model.workspaceCreate)
    XCTAssertEqual(form.curName, "zzz-check", "打った文字列を名前として引き継ぐ")
    XCTAssertFalse(form.linked, "引き継いだ名前はリンク解除で始まる（再リンクまで残る）")
    XCTAssertEqual(form.path, "/private/tmp", "パス既定はアクティブタブの cwd（rootPath ではない）")
  }

  /// 何も打たずに末尾の作成導線行から入ると名前は引き継がれず、パス追従で開く。
  func testCreateRowWithoutQueryOpensCreateFormLinkedToPath() throws {
    let wc = restoreTabbedWorkspace()
    wc.showWorkspacePalette()
    let palette = try XCTUnwrap(wc.model.workspacePalette)
    palette.render.onUp()  // 先頭で上 → 末尾の作成導線行へラップ
    palette.render.onActivate()

    XCTAssertEqual(wc.presentedOverlay, .workspaceCreate, "作成フォームへ遷移する")
    let form = try XCTUnwrap(wc.model.workspaceCreate)
    XCTAssertTrue(form.linked, "引き継ぎ無しはパス追従で開く")
    XCTAssertEqual(form.curName, "tmp", "追従名はパス末尾セグメント")
  }
}
