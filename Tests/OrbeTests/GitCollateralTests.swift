import XCTest

@testable import Orbe

/// 巻き添えが無いことの検証。git は並ばずに走り、順番が付くのは同じ worktree の index への根のサービスの書き込みだけ。
/// hook（ユーザーのコード＝所要時間に上限が無い）で止まった git が、その外の git を止めない。
///
/// ここが壊れると、1 本の返らない hook で worktree の掃除もワークスペース作成も別リポジトリのステージも返らなくなる
/// ——UI が丸ごと固まったように見え、ユーザーには原因が一切見えない。
final class GitCollateralTests: OrbeTestCase {
  private var fixture: GitHangFixture!
  private var repo: GitRepo!
  /// ハングさせた `addWorktree` を投げたか／返ったか（どちらも main queue でのみ触る）。
  private var hangStarted = false
  private var hangReturned = false

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
    try fixture.installHook("post-checkout", body: fixture.waitingBody)
    repo = try open(fixture)
    // 失敗経路でも必ず解放する（解放し損ねると止まった git が後続のテストまで残る）。
    addTeardownBlock { [self] in
      fixture.release()
      if hangStarted {
        XCTAssertTrue(
          pumpMainUntil({ self.hangReturned }, timeout: 60),
          "解放した hook の worktree add が返る")
      }
    }
  }

  // MARK: - ヘルパ

  private func open(_ fixture: GitHangFixture) throws -> GitRepo {
    var opened: GitRepo?
    let done = expectation(description: "GitRepo.open")
    GitRepo.open(cwd: fixture.root) {
      opened = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return try XCTUnwrap(opened)
  }

  /// post-checkout hook で止まる `worktree add` を投げ、**実際に hook へ入るまで**待つ。
  /// 「本当にハングしている」状態から測らないと、後続が通ったのは単にまだ始まっていないからかもしれない。
  ///
  /// 完了は expectation でなく flag で受ける——待つのは tearDown（hook を解放した後）であり、
  /// テスト本体で待たない expectation は XCTest 自身が失敗として数えてしまうため。
  private func startHangingWorktreeAdd() {
    hangStarted = true
    repo.addWorktree(
      path: fixture.worktreePath, base: "main",
      newBranch: GitNewBranch(name: "hang", tracksBase: false)
    ) { [self] _ in hangReturned = true }
    XCTAssertTrue(fixture.waitUntilHung(), "前提: post-checkout hook がハングしていること")
  }

  /// main queue を回しながら条件の成立を待つ（completion は main で届く）。
  private func pumpMainUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }

  /// 消す対象のローカルブランチを 1 本作り、その先端 oid を返す（`deleteBranch` の
  /// compare-and-swap 引数）。ハングを起こす前に済ませる arrange。
  private func makeScratchBranch(in fixture: GitHangFixture) throws -> String {
    XCTAssertTrue(fixture.git(["branch", "scratch"]).isSuccess, "前提: 消す対象のブランチを作れる")
    let oid = fixture.git(["rev-parse", "scratch"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(oid.isEmpty, "前提: ブランチの先端 oid を読める")
    return oid
  }

  // MARK: - 検証

  /// ハング中の worktree 作成は、同じリポジトリの書き込み（ブランチ削除）を止めない。
  /// 止めると、worktree の掃除が押しても何も起きない状態になる。
  func testHangingWorktreeAddDoesNotBlockOtherWrites() throws {
    let oid = try makeScratchBranch(in: fixture)
    startHangingWorktreeAdd()

    let done = expectation(description: "deleteBranch")
    repo.deleteBranch(name: "scratch", expectedOid: oid) { failure in
      // worktree 作成が触る ref（`refs/heads/hang`）と削除対象は交わらないので、巻き添えが無ければ必ず成功する。
      XCTAssertNil(failure, "ハング中でもブランチ削除は成功する")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
}
