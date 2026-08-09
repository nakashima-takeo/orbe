import XCTest

@testable import Orbe

/// WorktreeParser（porcelain）と BranchParser（for-each-ref）のフィクスチャテスト。
final class GitWorktreeParserTests: OrbeTestCase {

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

  /// worktree の掃除が読む 2 行（`prunable` は実体が消えている・`locked` は理由が付かないこともある）。
  func testWorktreePrunableAndLocked() {
    let input =
      "worktree /Users/x/github/orbe\n"
      + "HEAD 1111111111111111111111111111111111111111\n"
      + "branch refs/heads/main\n\n"
      + "worktree /Users/x/wt/gone\n"
      + "HEAD 2222222222222222222222222222222222222222\n"
      + "branch refs/heads/feat/gone\n"
      + "prunable gitdir file points to non-existent location\n\n"
      + "worktree /Users/x/wt/held\n"
      + "HEAD 3333333333333333333333333333333333333333\n"
      + "branch refs/heads/feat/held\n"
      + "locked\n\n"
      + "worktree /Users/x/wt/held-reason\n"
      + "HEAD 4444444444444444444444444444444444444444\n"
      + "detached\n"
      + "locked USB ドライブ上\n\n"
    let worktrees = WorktreeParser.parse(input)
    XCTAssertEqual(worktrees.count, 4)
    XCTAssertFalse(worktrees[0].isPrunable)
    XCTAssertNil(worktrees[0].lockReason)
    XCTAssertTrue(worktrees[1].isPrunable)
    XCTAssertEqual(worktrees[2].lockReason, "", "理由なしの locked も locked として持つ")
    XCTAssertEqual(worktrees[3].lockReason, "USB ドライブ上")
  }

  func testLocalBranchFormat() {
    let input =
      "main|1d前|/Users/x/github/orbe|origin/main|\n"
      + "feat/x|5d前|||\n"
      + "feat/gone|2d前||origin/feat/gone|[gone]\n"
      + "feat/ahead|3d前||origin/feat/ahead|[ahead 1]\n"
    let branches = BranchParser.parseLocal(input)
    XCTAssertEqual(branches.count, 4)
    XCTAssertEqual(branches[0].name, "main")
    XCTAssertEqual(branches[0].worktreePath, "/Users/x/github/orbe", "worktreepath 非空を拾う")
    XCTAssertEqual(branches[0].upstream, "origin/main")
    XCTAssertNil(branches[0].track, "空 track は nil")
    XCTAssertNil(branches[1].worktreePath, "空 worktreepath は nil")
    XCTAssertNil(branches[1].upstream)
    XCTAssertEqual(branches[2].track, "[gone]", "upstream が消えたブランチ＝掃除の推定材料")
    XCTAssertEqual(branches[3].track, "[ahead 1]")
  }

  /// 列が欠けた行でも落ちない（インデックス読みのガード）。
  func testLocalBranchWithoutTrackColumn() {
    let branches = BranchParser.parseLocal("main|1d前||origin/main\n")
    XCTAssertEqual(branches.count, 1)
    XCTAssertNil(branches[0].track)
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
