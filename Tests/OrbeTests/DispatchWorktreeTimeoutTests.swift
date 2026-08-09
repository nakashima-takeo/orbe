import XCTest

@testable import Orbe

/// Dispatch の Enter（worktree 新規作成）が打ち切られたときの見え方。
///
/// Git 層は文言を持たない（`GitFailure` は理由だけを返す）ので、UI 言語へ写すのはモデル層の責務。
/// ここが抜けると、120 秒待たされた末に**空のエラー**がパレットに出て、ユーザーには何が起きたのか
/// 一切分からない。clone 側（`WorkspaceCreateModel`）と対になる、worktree 作成側の配線を固定する。
@MainActor
final class DispatchWorktreeTimeoutTests: OrbeTestCase {
  /// 打ち切りの文言が出るのは「**worktree の実体が出来る前に**打ち切られた」ときだけ。実体が出来た
  /// 後（post-checkout hook のハング）は成功として読み替えるので、その形で書くと文言経路へ到達せず
  /// 何も測らないテストになる。`reference-transaction` は ref 更新時＝`<path>/.git` が書かれる前に
  /// 走るので（実測）、この形なら確実に打ち切りが失敗として返る。
  func testTimedOutWorktreeCreationShowsDedicatedMessage() throws {
    let fixture = try GitHangFixture()
    addTeardownBlock { fixture.cleanup() }
    try fixture.installHook("reference-transaction", script: fixture.waitingScript)

    // CI は英語なので、`.en` だと既定ストアと文言が一致して写しの経路が測れない。
    let localization = LocalizationStore(language: .ja)
    let provider = DispatchDataProvider(
      cwd: fixture.root, model: DispatchPaletteModel(), localization: localization,
      // 作成先を fixture の中へ落とす（後始末に乗せる）。
      worktreeTemplate: "{parent}/wt-{slug}", runner: GitRunner(idleTimeout: 0.6))
    provider.load()
    XCTAssertTrue(
      pumpMainUntil({ provider.repo != nil }, timeout: 10), "前提: リポジトリを解決できていること")

    var resolution: DispatchDataProvider.DirectoryResolution?
    let done = expectation(description: "prepareDirectory")
    provider.prepareDirectory(for: .issue(number: 44, existingWorktree: nil, existingBranch: false))
    {
      resolution = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 20)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.dir.appendingPathComponent("wt-issue-44/.git").path),
      "前提: 実体が出来る前に止まっている（出来ていれば成功読み替えに吸われ、文言経路を測れない）")
    guard case .failed(let message) = try XCTUnwrap(resolution) else {
      return XCTFail("打ち切られた作成は失敗として返る")
    }
    XCTAssertEqual(
      message, localization.string(.gitTimedOut),
      "git は何も言い残さないので、モデル層が専用文言を当てる")
  }

  /// main queue を回しながら条件の成立を待つ（`GitRepo` の completion は main で届く）。
  private func pumpMainUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }
}
