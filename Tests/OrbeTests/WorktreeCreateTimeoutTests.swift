import OrbeTestSupport
import XCTest

@testable import Orbe

/// worktree パレットの Enter（worktree 新規作成）が打ち切られたときの見え方。
///
/// Git 層は文言を持たない（`GitFailure` は理由だけを返す）ので、UI 言語へ写すのはモデル層の責務。
/// ここが抜けると、120 秒待たされた末に**空のエラー**がパレットに出て、ユーザーには何が起きたのか
/// 一切分からない。clone 側（`WorkspaceCreateModel`）と対になる、worktree 作成側の配線を固定する。
@MainActor
final class WorktreeCreateTimeoutTests: OrbeTestCase {
  /// 打ち切りの文言が出るのは「**worktree の実体が出来る前に**打ち切られた」ときだけ。実体が出来た
  /// 後（post-checkout hook のハング）は成功として読み替えるので、その形で書くと文言経路へ到達せず
  /// 何も測らないテストになる。`reference-transaction` は ref 更新時＝`<path>/.git` が書かれる前に
  /// 走るので（実測）、この形なら確実に打ち切りが失敗として返る。
  func testTimedOutWorktreeCreationShowsDedicatedMessage() throws {
    let fixture = try GitHangFixture()
    try fixture.installHook("reference-transaction", body: fixture.waitingBody)
    let clock = ManualClock()

    // CI は英語なので、`.en` だと既定ストアと文言が一致して写しの経路が測れない。
    let localization = LocalizationStore(language: .ja)
    let provider = WorktreePaletteDataProvider(
      cwd: fixture.root, model: WorktreePaletteModel(), localization: localization,
      // 作成先を fixture の中へ落とす（後始末に乗せる）。
      worktreeTemplate: "{parent}/wt-{slug}", runner: GitRunner(clock: clock.waits))
    provider.load()
    XCTAssertTrue(
      waitUntil(10) { provider.facts.repo != nil }, "前提: リポジトリを解決できていること")

    var resolution: WorktreeRepoFacts.DirectoryResolution?
    var done = false
    provider.facts.prepareDirectory(for: .newBranch(name: "issue/44", base: .defaultBranch)) {
      if case .resolved(let resolved) = $0 { resolution = resolved }
      done = true
    }
    XCTAssertTrue(fixture.pumpUntilHung(), "前提: worktree の作成が hook で止まっている")
    fixture.expireIdleLimit(on: clock, until: { done })

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
}
