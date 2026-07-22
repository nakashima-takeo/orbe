import XCTest

@testable import Orbe

/// `WorkspaceCreateModel`（作成フォームの状態機械）の検証。libghostty 非依存（@Observable モデルのみ）。
/// 追従／リンク解除／再リンク・導出名・作成可否・補完確定の意味メソッドを駆動して振る舞いを固定する。
@MainActor
final class WorkspaceCreateModelTests: XCTestCase {

  // MARK: - 名前の追従 / リンク解除 / 再リンク

  func testDerivedNameFollowsPathWhileLinked() {
    let m = WorkspaceCreateModel(path: "~/github/orbe")
    XCTAssertTrue(m.linked, "初期は追従中")
    XCTAssertEqual(m.derivedName, "orbe", "末尾セグメントから導出")
    XCTAssertEqual(m.curName, "orbe", "追従中の実効名＝導出名")
  }

  func testDerivedNameFallsBackToWorkspace() {
    let m = WorkspaceCreateModel(path: "")
    XCTAssertEqual(m.derivedName, "workspace", "末尾セグメントが空なら workspace")
  }

  func testSetNameUnlinks() {
    let m = WorkspaceCreateModel(path: "~/github/orbe")
    m.setName("custom")
    XCTAssertFalse(m.linked, "手入力でリンク解除")
    XCTAssertEqual(m.curName, "custom", "実効名は手入力値")
  }

  func testRelinkReturnsToFollowing() {
    let m = WorkspaceCreateModel(path: "~/github/orbe")
    m.setName("custom")
    m.relink()
    XCTAssertTrue(m.linked, "再リンクで追従へ戻る")
    XCTAssertEqual(m.curName, "orbe", "実効名は導出名へ戻る")
  }

  func testSetPathRelinksAndReDerivesName() {
    let m = WorkspaceCreateModel(path: "~/github/orbe")
    m.setName("custom")  // 一旦リンク解除
    m.setPath("~/work/infra")
    XCTAssertTrue(m.linked, "パス編集で名前は追従へ戻る")
    XCTAssertEqual(m.curName, "infra", "新パスの末尾セグメントへ再導出")
  }

  // MARK: - 作成可否 / 作成

  func testCanCreateRequiresExistingDirectory() {
    let existing = WorkspaceCreateModel(path: NSTemporaryDirectory())
    XCTAssertTrue(existing.pathExists)
    XCTAssertTrue(existing.canCreate, "実在ディレクトリ＋非空名で作成可")

    let missing = WorkspaceCreateModel(path: "/no/such/dir-\(UUID().uuidString)")
    XCTAssertFalse(missing.pathExists)
    XCTAssertFalse(missing.canCreate, "不在パスは作成不可")
  }

  func testCanCreateFalseWhenNameEmpty() {
    let m = WorkspaceCreateModel(path: NSTemporaryDirectory())
    m.setName("   ")  // 空白のみ＝空名
    XCTAssertFalse(m.canCreate, "実在パスでも空名なら作成不可")
  }

  func testSubmitFiresOnCreateWhenValid() {
    let m = WorkspaceCreateModel(path: NSTemporaryDirectory())
    m.setName("infra")
    var created: (String, String)?
    m.onCreate = { created = ($0, $1) }
    m.submit()
    XCTAssertEqual(created?.0, NSTemporaryDirectory(), "rootPath は入力パスそのまま（~ は store が展開）")
    XCTAssertEqual(created?.1, "infra", "name は実効名")
  }

  func testSubmitNoOpWhenInvalid() {
    let m = WorkspaceCreateModel(path: "/no/such/dir-\(UUID().uuidString)")
    var fired = false
    m.onCreate = { _, _ in fired = true }
    m.submit()
    XCTAssertFalse(fired, "不在パスの submit は発火しない")
  }

  // MARK: - 補完の確定 / ハイライト

  func testAcceptSuggestionSwapsPathAndRelinks() {
    let m = WorkspaceCreateModel(path: "~/github/rh")
    m.suggestions = [
      FolderSuggestion(name: "orbe", fullPath: "/opt/src/orbe", isRepo: true),
      FolderSuggestion(name: "orbe-x", fullPath: "/opt/src/orbe-x", isRepo: false),
    ]
    m.setName("custom")  // リンク解除しておく
    m.highlighted = 1
    let tokenBefore = m.focusToken
    XCTAssertTrue(m.acceptSuggestion(), "候補ありは true")
    XCTAssertEqual(m.path, "/opt/src/orbe-x", "ハイライト候補のフルパスへ差し替え")
    XCTAssertTrue(m.linked, "確定で名前は追従へ戻る")
    XCTAssertEqual(m.curName, "orbe-x")
    XCTAssertTrue(m.suggestions.isEmpty, "確定でドロップダウンを閉じる")
    XCTAssertEqual(m.highlighted, 0)
    XCTAssertEqual(m.focusToken, tokenBefore &+ 1, "確定でパス欄へ focus を戻す（focusToken 前進）")
  }

  func testAcceptSuggestionFalseWhenNoSuggestions() {
    let m = WorkspaceCreateModel(path: "~/x")
    XCTAssertFalse(m.acceptSuggestion(), "候補が無ければ false（呼び出し側は名前欄へ）")
  }

  func testDismissSuggestionsClosesDropdownAndKeepsPath() {
    let m = WorkspaceCreateModel(path: "~/github/rh")
    m.suggestions = [
      FolderSuggestion(name: "orbe", fullPath: "/opt/src/orbe", isRepo: true)
    ]
    m.highlighted = 0
    XCTAssertTrue(m.dismissSuggestions(), "候補ありは true（閉じるだけ）")
    XCTAssertTrue(m.suggestions.isEmpty, "候補ドロップダウンを閉じる")
    XCTAssertEqual(m.path, "~/github/rh", "パスは保持（確定しない）")
  }

  func testDismissSuggestionsFalseWhenNoSuggestions() {
    let m = WorkspaceCreateModel(path: "~/x")
    XCTAssertFalse(m.dismissSuggestions(), "候補が無ければ false（呼び出し側は前の画面へ戻す）")
  }

  func testMoveHighlightWraps() {
    let m = WorkspaceCreateModel(path: "~/x")
    m.suggestions = [
      FolderSuggestion(name: "a", fullPath: "/a", isRepo: false),
      FolderSuggestion(name: "b", fullPath: "/b", isRepo: false),
      FolderSuggestion(name: "c", fullPath: "/c", isRepo: false),
    ]
    m.moveHighlight(-1)
    XCTAssertEqual(m.highlighted, 2, "先頭で上＝末尾へラップ")
    m.moveHighlight(1)
    XCTAssertEqual(m.highlighted, 0, "末尾で下＝先頭へラップ")
  }

  func testMoveHighlightNoOpWhenEmpty() {
    let m = WorkspaceCreateModel(path: "~/x")
    m.moveHighlight(1)
    XCTAssertEqual(m.highlighted, 0, "候補なしでは動かない")
  }

  func testJumpHighlightToEdges() {
    let m = WorkspaceCreateModel(path: "~/x")
    m.suggestions = [
      FolderSuggestion(name: "a", fullPath: "/a", isRepo: false),
      FolderSuggestion(name: "b", fullPath: "/b", isRepo: false),
      FolderSuggestion(name: "c", fullPath: "/c", isRepo: false),
    ]
    m.highlighted = 1
    m.jumpHighlight(-1)
    XCTAssertEqual(m.highlighted, 0, "⌘↑＝先頭候補へ")
    m.jumpHighlight(1)
    XCTAssertEqual(m.highlighted, 2, "⌘↓＝末尾候補へ")
  }

  func testJumpHighlightNoOpWhenEmpty() {
    let m = WorkspaceCreateModel(path: "~/x")
    m.jumpHighlight(1)
    XCTAssertEqual(m.highlighted, 0, "候補なしでは動かない")
  }

  // MARK: - git clone: 名前導出 / ソース切替

  func testCloneDerivedNameStripsDotGit() {
    let m = WorkspaceCreateModel(path: "~")
    m.setSource(.clone)
    m.setCloneURL("https://github.com/you/repo.git")
    XCTAssertEqual(m.curName, "repo", "末尾 repo.git → repo")
    m.setCloneURL("git@github.com:you/other.git")
    XCTAssertEqual(m.curName, "other", "scp-like も /-分割で末尾 → other")
    m.setCloneURL("https://example.com/path/to/thing")
    XCTAssertEqual(m.curName, "thing", ".git 無しは末尾セグメントそのまま")
    m.setCloneURL("https://github.com/you/repo/")
    XCTAssertEqual(m.curName, "repo", "末尾スラッシュ URL でも空セグメントを畳んで repo")
    m.setCloneURL("https://github.com/you/repo.git/")
    XCTAssertEqual(m.curName, "repo", "末尾スラッシュ＋.git でも repo")
    m.setCloneURL("")
    XCTAssertEqual(m.curName, "workspace", "空 URL は workspace へフォールバック")
  }

  func testSetCloneURLRelinksName() {
    let m = WorkspaceCreateModel(path: "~")
    m.setSource(.clone)
    m.setCloneURL("https://github.com/you/repo.git")
    m.setName("custom")
    XCTAssertFalse(m.linked, "手入力でリンク解除")
    m.setCloneURL("https://github.com/you/other.git")
    XCTAssertTrue(m.linked, "URL 変更で名前は追従へ戻る")
    XCTAssertEqual(m.curName, "other")
  }

  func testSetSourceKeepsInputsAndRelinksName() {
    let m = WorkspaceCreateModel(path: "~/github/orbe")
    m.setSource(.clone)
    m.setCloneURL("https://github.com/you/repo.git")
    m.setName("custom")  // clone 名を手入力（リンク解除）
    XCTAssertFalse(m.linked)
    m.setSource(.folder)
    XCTAssertTrue(m.linked, "ソース切替で名前は追従へ戻る")
    XCTAssertEqual(m.path, "~/github/orbe", "folder 入力は保持")
    XCTAssertEqual(m.cloneURL, "https://github.com/you/repo.git", "clone 入力も保持")
    XCTAssertEqual(m.curName, "orbe", "folder の追従名へ")
    m.setSource(.clone)
    XCTAssertEqual(m.curName, "repo", "clone の追従名へ")
  }

  func testSetSourceBumpsFocusTokenToRefocusPrimaryField() {
    let m = WorkspaceCreateModel(path: "~")
    let before = m.focusToken
    m.setSource(.clone)
    XCTAssertEqual(m.focusToken, before &+ 1, "ソース切替で focusToken を進め主入力欄へ focus を移す")
    let afterClone = m.focusToken
    m.setSource(.folder)
    XCTAssertEqual(m.focusToken, afterClone &+ 1, "逆方向の切替でも進める（常に入力欄 focus の不変）")
  }

  // MARK: - git clone: 作成可否

  func testCloneCanCreateRequiresUrlAndParent() {
    let parent = NSTemporaryDirectory()
    let m = WorkspaceCreateModel(path: parent)
    m.setSource(.clone)
    XCTAssertFalse(m.canCreate, "URL 空は作成不可")
    m.setCloneURL("https://github.com/you/repo.git")
    XCTAssertTrue(m.canCreate, "URL 非空＋親実在＋名前非空で作成可")
    m.setCloneDir("/no/such/dir-\(UUID().uuidString)")
    XCTAssertFalse(m.canCreate, "clone 先の親が不在なら作成不可")
  }

  // MARK: - git clone: 実行配線（runner 注入・実 git 非依存）

  func testCloneSuccessWiresOnCreateWithFinalDest() {
    let parent = NSTemporaryDirectory()
    let m = WorkspaceCreateModel(path: parent)
    m.setSource(.clone)
    m.setCloneURL("https://github.com/you/repo.git")
    let finalDest = (parent as NSString).appendingPathComponent("repo")
    var cloneCall: (url: String, dest: String)?
    m.onClone = { url, dest, done in
      cloneCall = (url, dest)
      done(nil)  // 同期成功
    }
    var created: (String, String)?
    m.onCreate = { created = ($0, $1) }
    m.submit()
    XCTAssertEqual(cloneCall?.url, "https://github.com/you/repo.git", "URL は trim して素通し")
    XCTAssertEqual(cloneCall?.dest, finalDest, "dest は展開済み clone先/名前")
    XCTAssertEqual(created?.0, finalDest, "onCreate の rootPath は clone先/名前")
    XCTAssertEqual(created?.1, "repo", "name は導出名")
    XCTAssertFalse(m.isCloning, "成功で idle へ戻る")
    XCTAssertNil(m.cloneError)
  }

  func testCloneFailureSetsErrorAndSkipsOnCreate() {
    let parent = NSTemporaryDirectory()
    let m = WorkspaceCreateModel(path: parent)
    m.setSource(.clone)
    m.setCloneURL("https://github.com/no/such.git")
    var created = false
    m.onCreate = { _, _ in created = true }
    m.onClone = { _, _, done in done("fatal: repository not found") }
    m.submit()
    XCTAssertFalse(created, "失敗で onCreate は発火しない")
    XCTAssertEqual(m.cloneError, "fatal: repository not found", "stderr を inline 表示へ")
    XCTAssertFalse(m.isCloning, "失敗で running を抜ける")
  }

  func testCloneIgnoresReentrantSubmit() {
    let parent = NSTemporaryDirectory()
    let m = WorkspaceCreateModel(path: parent)
    m.setSource(.clone)
    m.setCloneURL("https://github.com/you/repo.git")
    var cloneCalls = 0
    m.onClone = { _, _, _ in cloneCalls += 1 }  // 完了を呼ばない＝running のまま
    m.submit()
    XCTAssertTrue(m.isCloning, "実行中は待機状態")
    m.submit()  // 実行中の再 submit
    XCTAssertEqual(cloneCalls, 1, "実行中の再 submit は無視（二重実行防止）")
  }

  /// 設計の肝: onCreate へは `~` 保持パス（store が展開）・git へは展開済み絶対パスを渡す分離を固定。
  /// 親を `~`（home）にすると finalDest=`~/repo` と expandedDest=`<home>/repo` が別値になり分離を検証できる。
  func testCloneSuccessPreservesTildeForOnCreateAndExpandsForGit() {
    let m = WorkspaceCreateModel(path: "~")  // 親=home（実在）で canCreate
    m.setSource(.clone)
    m.setCloneURL("https://github.com/you/repo.git")
    var cloneDest: String?
    m.onClone = { _, dest, done in
      cloneDest = dest
      done(nil)
    }
    var created: (String, String)?
    m.onCreate = { created = ($0, $1) }
    m.submit()
    XCTAssertEqual(created?.0, "~/repo", "onCreate の rootPath は `~` 保持（store が展開）")
    XCTAssertEqual(
      cloneDest, ("~/repo" as NSString).expandingTildeInPath, "git へは展開済み絶対パス")
    XCTAssertNotEqual(created?.0, cloneDest, "`~` 保持と展開済みは別値（分離を固定）")
  }
}
