import XCTest

@testable import Orbe

/// `.unmerged` を名乗ってよい条件と、そのとき出す件数。**この verdict だけは「どの比較先にも
/// patch 等価でない」という全称の主張**なので、比較先が増えるほど言い切るための条件が厳しくなる
/// ——数は全比較先の最小を取り、1 本でも確かめられなければ名乗らず判定不能に倒す。
extension GitWorktreeCleanIntegrationTests {

  /// **count の min は比較先をまたいで取る**。比較先ごとに patch 非等価数が違うとき、名乗るのは
  /// 最も取り込みが進んでいる比較先の残数——どの比較先の数も「真に失われる数」の過大評価なので、
  /// 最小がより良い過大評価になる。
  func testUnmergedCountIsTheMinAcrossEveryTarget() throws {
    XCTAssertTrue(git(["checkout", "-q", "-b", "develop", "main"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "-b", "feat/multi", "main"]).isSuccess)
    try write("a.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "a1"]).isSuccess)
    let first = git(["rev-parse", "HEAD"]).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try write("b.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "b1"]).isSuccess)
    // develop だけが a1 を（別 SHA で）取り込んでいる形にする。
    XCTAssertTrue(git(["checkout", "-q", "develop"]).isSuccess)
    XCTAssertTrue(git(["cherry-pick", first]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "main"]).isSuccess)
    try addOrigin(pushing: ["main", "develop"])

    XCTAssertEqual(plusCount(cherrying: "main", "feat/multi"), 2, "前提: 既定側は 2 件が未適用")
    XCTAssertEqual(
      plusCount(cherrying: "origin/develop", "feat/multi"), 1,
      "前提: develop は a1 を取り込み済みなので未適用は 1 件")

    XCTAssertEqual(
      try containment("feat/multi", targets: ["main", "origin/develop"]), .unmerged(count: 1),
      "比較先ごとに違う数のうち最小を名乗る（既定側の 2 ではない）")
  }

  /// **第2段が確かめられなければ `.unmerged` を名乗らない**。`.unmerged` は「どの比較先にも patch
  /// 等価でない」という主張なので、1 本でも確かめ切れていなければ偽になりうる。共通祖先の無い
  /// ブランチでは squash 検出の `merge-base` が落ちる——そこを「未取り込み」と断定せず判定不能に倒し、
  /// 行は独自コミット件数ではなく判定不能チップで語る。
  func testUnprovableSquashCheckYieldsNilRatherThanUnmerged() throws {
    XCTAssertTrue(git(["checkout", "-q", "--orphan", "feat/orphan"]).isSuccess)
    try write("o.txt", "1")
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "o1"]).isSuccess)
    XCTAssertTrue(git(["checkout", "-q", "-f", "main"]).isSuccess)
    try addOrigin(pushing: ["main"])

    XCTAssertEqual(
      plusCount(cherrying: "main", "feat/orphan"), 1,
      "前提: 第1段の cherry は共通祖先が無くても成立する（左右の対称差）")
    XCTAssertFalse(
      git(["merge-base", "main", "feat/orphan"]).isSuccess,
      "前提: 第2段の merge-base は共通祖先が無いので落ちる")

    XCTAssertNil(
      try containment("feat/orphan", targets: ["main"]),
      "確かめられなかった第2段を「未取り込み」と断定しない")
  }

  /// `git cherry <upstream> <head>` の未適用（`+`）件数。
  private func plusCount(cherrying upstream: String, _ head: String) -> Int {
    git(["cherry", upstream, head]).stdoutText.split(separator: "\n")
      .filter { $0.hasPrefix("+") }.count
  }

}
