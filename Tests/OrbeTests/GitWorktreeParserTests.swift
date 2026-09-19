import XCTest

@testable import Orbe

/// WorktreeParser（porcelain -z）と BranchParser（for-each-ref）のフィクスチャテスト。
final class GitWorktreeParserTests: OrbeTestCase {

  func testWorktreePorcelain() {
    let input =
      "worktree /Users/x/github/orbe\0"
      + "HEAD 1111111111111111111111111111111111111111\0"
      + "branch refs/heads/main\0\0"
      + "worktree /Users/x/github/orbe-worktrees/feat-x\0"
      + "HEAD 2222222222222222222222222222222222222222\0"
      + "branch refs/heads/feat/x\0\0"
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
      "worktree /Users/x/wt/detached\0"
      + "HEAD 3333333333333333333333333333333333333333\0"
      + "detached\0\0"
    let worktrees = WorktreeParser.parse(input)
    XCTAssertEqual(worktrees.count, 1)
    XCTAssertNil(worktrees[0].branch)
  }

  /// worktree の掃除が読む 2 行（`prunable` は実体が消えている・`locked` は理由が付かないこともある）。
  func testWorktreePrunableAndLocked() {
    let input =
      "worktree /Users/x/github/orbe\0"
      + "HEAD 1111111111111111111111111111111111111111\0"
      + "branch refs/heads/main\0\0"
      + "worktree /Users/x/wt/gone\0"
      + "HEAD 2222222222222222222222222222222222222222\0"
      + "branch refs/heads/feat/gone\0"
      + "prunable gitdir file points to non-existent location\0\0"
      + "worktree /Users/x/wt/held\0"
      + "HEAD 3333333333333333333333333333333333333333\0"
      + "branch refs/heads/feat/held\0"
      + "locked\0\0"
      + "worktree /Users/x/wt/held-reason\0"
      + "HEAD 4444444444444444444444444444444444444444\0"
      + "detached\0"
      + "locked USB ドライブ上\0\0"
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
      "main\01d前\0origin/main\0refs/remotes/origin/main\0origin\0refs/heads/main\0\n"
      + "feat/x\05d前\0\0\0\0\0\n"
      + "feat/gone\02d前\0origin/feat/gone\0refs/remotes/origin/feat/gone\0origin"
      + "\0refs/heads/feat/gone\0[gone]\n"
      + "feat/ahead\03d前\0origin/feat/ahead\0refs/remotes/origin/feat/ahead\0origin"
      + "\0refs/heads/feat/ahead\0[ahead 1]\n"
      + "feat/both\04d前\0fork/feat/both\0refs/remotes/fork/feat/both\0fork"
      + "\0refs/heads/feat/both\0[ahead 1, behind 2]\n"
      + "feat/behind\04d前\0origin/feat/behind\0refs/remotes/origin/feat/behind\0origin"
      + "\0refs/heads/feat/behind\0[behind 3]\n"
    let branches = BranchParser.parseLocal(input)
    XCTAssertEqual(branches.count, 6)
    XCTAssertEqual(branches[0].name, "main")
    XCTAssertEqual(
      branches[0].upstream,
      GitUpstream(
        short: "origin/main", ref: "refs/remotes/origin/main", remote: "origin",
        remoteRef: "refs/heads/main", track: nil), "空 track は同期済み（nil）")
    XCTAssertNil(branches[1].upstream)
    XCTAssertEqual(branches[2].upstream?.track, .gone, "upstream が消えたブランチ＝掃除の推定材料")
    XCTAssertEqual(branches[3].upstream?.track, .counts(ahead: 1, behind: 0))
    XCTAssertEqual(branches[4].upstream?.track, .counts(ahead: 1, behind: 2))
    XCTAssertEqual(branches[4].upstream?.remote, "fork", "remote 名は upstream の事実から取る")
    XCTAssertEqual(branches[5].upstream?.track, .counts(ahead: 0, behind: 3))
  }

  /// 列が欠けた行でも落ちない（インデックス読みのガード）。
  func testLocalBranchWithoutTrackColumn() {
    let branches = BranchParser.parseLocal("main\01d前\0origin/main\n")
    XCTAssertEqual(branches.count, 1)
    XCTAssertEqual(branches[0].upstream?.short, "origin/main")
    XCTAssertNil(branches[0].upstream?.track)
  }

  func testRemoteBranchExcludesHeadNoise() {
    let input =
      "origin/HEAD\03h前\0taro\n"
      + "origin/feat/session-restore\03h前\0taro\n"
    let branches = BranchParser.parseRemote(input)
    XCTAssertEqual(branches.map(\.name), ["origin/feat/session-restore"], "*/HEAD ノイズを除外")
    XCTAssertEqual(branches[0].relativeDate, "taro · 3h前", "author · 相対日時")
  }
}
