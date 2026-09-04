import XCTest

@testable import Orbe

/// `GitHangFixture` が置いた実行体は、git が**初めて** exec しても評価コストを払わない
/// ——という fixture の契約の検証。
///
/// 短いアイドル上限（0.6 秒）で打ち切りを測るテストは、この契約が無いと初回 exec の評価
/// （実測 150〜450 ms で変動し、明確な上限は無い）と競合して不定に落ちる。契約を支えているのは
/// 「評価は inode 単位でキャッシュされ、priming した別プロセスの exec にも効く」という実測事実で、
/// Apple が文書化した保証ではない。前提が崩れればここが落ちる。OS が評価そのものをやめた場合は
/// 差 ≈ 0 で通り、priming は無害な冗長になる。
final class GitHangFixtureTests: OrbeTestCase {
  /// 測るのは hook を踏む `git commit` の所要時間——hook 側で変動するのが exec だけになるよう、
  /// 本体はシェル組み込みの追記と `exit 0` だけにする（待ち・孫・tick も追加の exec も混ぜない）。
  ///
  /// 主張は絶対時間ではなく**同じ hook の 1 回目と 2 回目の差**。git 自体が遅いマシンでも揺れず、
  /// 3 組の最小どうしを取るので 1 回のスパイクで偽陽性にならない。priming を外すと、hook は毎回
  /// 「初回 exec」（`write(body:to:)` の契約）なので 3 組すべての 1 回目に評価コストが乗り、
  /// min を取っても差が残る。
  func testInstalledExecutableCostsNoFirstExecEvaluation() throws {
    let fixture = try GitHangFixture()
    addTeardownBlock { fixture.cleanup() }

    let marker = fixture.dir.appendingPathComponent("hook-ran").path
    var firsts: [TimeInterval] = []
    var seconds: [TimeInterval] = []
    for round in 0..<3 {
      try fixture.installHook("pre-commit", body: "echo \(round) >> \"\(marker)\"\nexit 0")
      firsts.append(try commitDuration(fixture, message: "first-\(round)"))
      seconds.append(try commitDuration(fixture, message: "second-\(round)"))
      XCTAssertEqual(
        try hookRunCount(marker), 2 * (round + 1),
        "前提: このラウンドの 2 回の commit で hook が走っている（偽ならこのテストは何も測らない）")
    }

    let fastestFirst = try XCTUnwrap(firsts.min())
    let fastestSecond = try XCTUnwrap(seconds.min())
    let gap = fastestFirst - fastestSecond
    XCTAssertLessThan(
      gap, 0.05,
      "fixture が置いた hook の初回 exec に評価コストが乗っている（差 \(gap)s）"
        + "。priming が効いていれば差は ±10ms、外すと 3 組すべての 1 回目に 150〜450ms が乗る")
  }

  /// hook が追記したマーカーの行数＝hook が exec された回数。
  private func hookRunCount(_ marker: String) throws -> Int {
    try String(contentsOfFile: marker, encoding: .utf8).split(separator: "\n").count
  }

  /// 変更を 1 つ作って commit し、その所要時間を返す。
  private func commitDuration(_ fixture: GitHangFixture, message: String) throws -> TimeInterval {
    try message.appending("\n").write(
      toFile: (fixture.root as NSString).appendingPathComponent("a.txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(fixture.git(["add", "-A"]).isSuccess)

    let start = Date()
    XCTAssertTrue(fixture.git(["commit", "-qm", message]).isSuccess)
    return Date().timeIntervalSince(start)
  }
}
