import OrbeTestSupport
import XCTest

@testable import Orbe

/// 「コミット」の添え書きに出すステージ済みの行数（`ScmPanel.stagedLines`）——ステージ済みの中身が変われば読み直し、
/// ステージ済みが無くなれば持たない。
///
/// 壊れると何が起きるか。同じファイルをステージし直しても前の行数のまま出続ける。全部のステージを解いても「ステージ済み」の
/// 添え書きが残る。
extension ScmPanelTests {
  /// 同じパスをステージし直せば新しい中身の行数に追いつき、ステージを全部解けば行数を持たない。
  func testTheStagedLineCountsFollowTheStagedContentAndGoWithIt() throws {
    show(until: { $0.isManaged == true }, "パネル")
    try repo.write("a.txt", "one\ntwo\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(
      until: { self.panel.stagedLines?.counts == GitLineCounts(added: 1, deleted: 0) },
      "ステージした行数")

    try repo.write("a.txt", "one\ntwo\nthree\n")
    XCTAssertTrue(repo.git(["add", "a.txt"]).isSuccess)
    pumpMain(
      until: { self.panel.stagedLines?.counts == GitLineCounts(added: 2, deleted: 0) },
      "同じパスをステージし直した行数")

    XCTAssertTrue(repo.git(["reset", "-q"]).isSuccess)
    pumpMain(until: { self.panel.stagedLines == nil }, "ステージを全部解くと持たない")
  }
}
