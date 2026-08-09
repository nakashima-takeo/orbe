import XCTest

@testable import Orbe

/// 詰まりの構造の検証。`git worktree add` は post-checkout hook（ユーザーのコード＝所要時間に上限が無い）
/// を踏むので、これを共有 queue の barrier に載せると **1 本の遅い操作が以後の全 git 操作を止める**。
/// しかも barrier はプロセス単位でリポジトリ単位ですらないため、巻き添えは別リポジトリにまで及ぶ。
///
/// ここが壊れると、worktree 作成 1 本のハングで差分表示も stage もワークスペース作成も返らなくなる
/// ——UI が丸ごと固まったように見え、ユーザーには原因が一切見えない。
final class GitRunnerLaneTests: OrbeTestCase {
  private var fixture: GitHangFixture!
  private var repo: GitRepo!
  /// ハングさせた `addWorktree` を投げたか／返ったか（どちらも main queue でのみ触る）。
  private var hangStarted = false
  private var hangReturned = false

  override func setUpWithError() throws {
    fixture = try GitHangFixture()
    try fixture.installHook("post-checkout", script: fixture.waitingScript)
    repo = try open(fixture)
    // 失敗経路でも必ず解放する（解放し損ねると GitRunner.shared が詰まったまま後続の全テストが死ぬ）。
    addTeardownBlock { [self] in
      fixture.release()
      if hangStarted {
        XCTAssertTrue(
          pumpMainUntil({ self.hangReturned }, timeout: 60),
          "解放した hook の worktree add が返らないと、以後のテストが GitRunner.shared ごと詰まる")
      }
      fixture.cleanup()
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
      path: fixture.worktreePath, base: "main", newBranch: "hang", track: false
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

  private func writeFile(_ name: String, in fixture: GitHangFixture) throws {
    try "y\n".write(
      toFile: (fixture.root as NSString).appendingPathComponent(name), atomically: true,
      encoding: .utf8)
  }

  // MARK: - 検証

  /// ハング中の worktree 作成は、同じリポジトリの書き込み（stage）を止めない。
  /// 止めると、EditorPane の stage が押しても何も起きない状態になる。
  func testHangingWorktreeAddDoesNotBlockOtherWrites() throws {
    try writeFile("b.txt", in: fixture)
    startHangingWorktreeAdd()

    let done = expectation(description: "stageFiles")
    repo.stageFiles(["b.txt"]) { error in
      // 巻き添えを免れるだけでなく、stage 自体が通ること。独立レーンの根拠（呼び出し元の index に
      // 触らない）が崩れると `git add` は index.lock で即 fatal し、待たずに返るのでここだけが気づく。
      XCTAssertNil(error, "ハング中でも stage は成功する")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }

  /// ハング中の worktree 作成は、同じリポジトリの読み取り（status・diff）を止めない。
  /// GCD の barrier は**後から submit された読み取りも待たせる**ので、ここが最も広く巻き添えを食う。
  func testHangingWorktreeAddDoesNotBlockReads() throws {
    startHangingWorktreeAdd()

    let done = expectation(description: "snapshot")
    repo.snapshot { snapshot in
      XCTAssertNotNil(snapshot, "ハング中でも読み取りは成功する")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }

  /// ハング中の worktree 作成は、**別のリポジトリ**の操作すら止めない。
  /// barrier がプロセス単位（リポジトリ単位ですらない）ことの害を直接固定する。
  func testHangingWorktreeAddDoesNotBlockAnotherRepository() throws {
    let other = try GitHangFixture()
    addTeardownBlock { other.cleanup() }
    let otherRepo = try open(other)
    try writeFile("b.txt", in: other)
    startHangingWorktreeAdd()

    let done = expectation(description: "other repository stageFiles")
    otherRepo.stageFiles(["b.txt"]) { error in
      XCTAssertNil(error, "別リポジトリの stage は成功する")
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
  }
}
