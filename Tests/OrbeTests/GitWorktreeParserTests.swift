import XCTest

@testable import Orbe

/// WorktreeParser（porcelain）と BranchParser（for-each-ref）のフィクスチャテスト。
final class GitWorktreeParserTests: XCTestCase {

  func testWorktreePorcelain() {
    let input =
      "worktree /Users/x/github/orbe\n"
      + "HEAD 1111111111111111111111111111111111111111\n"
      + "branch refs/heads/main\n\n"
      + "worktree /Users/x/github/orbe-worktrees/feat-x\n"
      + "HEAD 2222222222222222222222222222222222222222\n"
      + "branch refs/heads/feat/x\n\n"
    let worktrees = WorktreeParser.parse(input)
    XCTAssertEqual(worktrees.count, 2)
    XCTAssertEqual(worktrees[0].path, "/Users/x/github/orbe")
    XCTAssertEqual(worktrees[0].branch, "main", "refs/heads/ を落とした短縮名")
    XCTAssertTrue(worktrees[0].isMain, "先頭が main worktree")
    XCTAssertEqual(worktrees[1].branch, "feat/x")
    XCTAssertFalse(worktrees[1].isMain)
  }

  func testWorktreeDetachedHasNilBranch() {
    let input =
      "worktree /Users/x/wt/detached\n"
      + "HEAD 3333333333333333333333333333333333333333\n"
      + "detached\n\n"
    let worktrees = WorktreeParser.parse(input)
    XCTAssertEqual(worktrees.count, 1)
    XCTAssertNil(worktrees[0].branch)
  }

  func testLocalBranchFormat() {
    let input =
      "main|1d前|/Users/x/github/orbe|origin/main\n"
      + "feat/x|5d前||\n"
    let branches = BranchParser.parseLocal(input)
    XCTAssertEqual(branches.count, 2)
    XCTAssertEqual(branches[0].name, "main")
    XCTAssertEqual(branches[0].worktreePath, "/Users/x/github/orbe", "worktreepath 非空を拾う")
    XCTAssertEqual(branches[0].upstream, "origin/main")
    XCTAssertNil(branches[1].worktreePath, "空 worktreepath は nil")
    XCTAssertNil(branches[1].upstream)
  }

  func testRemoteBranchExcludesHeadNoise() {
    let input =
      "origin|3h前|taro\n"  // origin/HEAD の短縮（単独名）
      + "origin/HEAD|3h前|taro\n"  // *//HEAD
      + "origin/feat/session-restore|3h前|taro\n"
    let branches = BranchParser.parseRemote(input)
    XCTAssertEqual(branches.map(\.name), ["origin/feat/session-restore"], "HEAD ノイズ 2 行を除外")
    XCTAssertEqual(branches[0].relativeDate, "taro · 3h前", "author · 相対日時")
  }
}
