import OrbeTestSupport
import XCTest

@testable import Orbe

/// ステージ済みの変更の、追加と削除の行数（`GitRepo.stagedLineCounts`）。実 git の一時リポジトリで数える。
///
/// 壊れると何が起きるか: 上のバーの「コミット」のボタンに添える行数（「ステージ済み +125 −3」）が、コミットに入る中身と食い違う——作業ツリーだけの変更まで数える、
/// バイナリのファイルが 1 つ在るだけで数が出ない、名前だけ変えたファイルを全行の追加と削除に数える（利用者が rename の検出を
/// 切っていると）、初回コミットの前に数が出ない。
@MainActor
final class GitRepoStagedLinesTests: OrbeTestCase {
  private func counts(_ temp: TempGitRepo) -> GitLineCounts? {
    var opened: GitRepo?
    GitRepo.open(cwd: temp.root) { opened = $0 }
    pumpMain(until: { opened != nil }, "開く")
    var result: GitLineCounts??
    opened?.stagedLineCounts { result = .some($0) }
    pumpMain(until: { result != nil }, "行数が読める")
    return result ?? nil
  }

  /// 全ファイルの合計で、ステージ済みの分だけを数える（作業ツリーだけの変更は数えない）。バイナリのファイルは 0 行。
  func testTheStagedChangesOfEveryFileAreSummedAndABinaryCountsZero() throws {
    let temp = try TempGitRepo()
    try temp.write("a.txt", "two\nthree\n")
    try temp.write("b.txt", "1\n2\n3\n")
    try Data([0, 1, 2, 0]).write(to: temp.dir.appendingPathComponent("bin.dat"))
    XCTAssertTrue(temp.git(["add", "-A"]).isSuccess)
    try temp.write("a.txt", "two\nthree\nunstaged\n")

    XCTAssertEqual(counts(temp), GitLineCounts(added: 5, deleted: 1))
  }

  /// 名前だけ変えたファイルは 0 行——利用者の設定で rename の検出を切っていても。
  func testARenameOnlyCountsZeroEvenWithRenameDetectionTurnedOff() throws {
    let temp = try TempGitRepo()
    XCTAssertTrue(temp.git(["config", "diff.renames", "false"]).isSuccess)
    XCTAssertTrue(temp.git(["mv", "a.txt", "moved.txt"]).isSuccess)

    XCTAssertEqual(counts(temp), GitLineCounts(added: 0, deleted: 0))
  }

  /// 初回コミットの前も、ステージ済みのファイルの行を追加として数える。
  func testBeforeTheFirstCommitTheStagedLinesCountAsAdded() throws {
    let temp = try TempGitRepo(initialCommit: false)
    try temp.write("x.txt", "1\n2\n")
    XCTAssertTrue(temp.git(["add", "x.txt"]).isSuccess)

    XCTAssertEqual(counts(temp), GitLineCounts(added: 2, deleted: 0))
  }
}
