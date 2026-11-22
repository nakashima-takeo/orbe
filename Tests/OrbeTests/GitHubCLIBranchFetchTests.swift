import OrbeTestSupport
import XCTest

@testable import Orbe

/// ブランチ PR 取得の並列口（`GitHubCLI.branchPullRequests(cwd:heads:each:)`）。
///
/// **head 単位で着地し、失敗も head に閉じ、同時実行は上限で頭打ちになる**——この 3 つが崩れると、
/// 「1 本の失敗で全 head の事実が消える」「worktree 本数ぶんの往復が直列に積み上がる」という、
/// clean の鮮度がそのまま落ちる形に戻る。PATH に偽の `gh` を置いて本物の子プロセスで測る。
final class GitHubCLIBranchFetchTests: OrbeTestCase {
  private var dir: URL!
  private var log: String!
  private var gate: URL { dir.appendingPathComponent("gate") }

  override func setUpWithError() throws {
    dir = TestScratch.caseDir
      .appendingPathComponent("orbe-gh-branch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    log = dir.appendingPathComponent("lanes.log").path
    try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
    // `--head <name>` の name を拾い、`bad/*` は非 0 で落ち、それ以外は 1 件返す。
    // 走っている間の重なりを記録して、同時実行の上限を測る。門（`gate`）が在るあいだは、始めたまま終わらない。
    // 門が消えないまま 60 秒（壁時計）が過ぎたら、失敗する（exit 1。テストのプロセスが落ちて門が残っても、居座らない）。
    let script = """
      #!/bin/sh
      head=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "--head" ]; then head="$2"; fi
        shift
      done
      printf 'S\\n' >> "\(log!)"
      end=$(( $(date +%s) + 60 ))
      while [ -d "\(gate.path)" ]; do
        [ "$(date +%s)" -lt "$end" ] || exit 1
        sleep 0.05
      done
      printf 'E\\n' >> "\(log!)"
      case "$head" in
        bad/*) exit 1 ;;
      esac
      printf '[{"number":1,"headRefName":"%s","state":"OPEN","baseRefName":"main",' "$head"
      printf '"headRepositoryOwner":{"login":"o"},"headRepository":{"name":"r"}}]'
      """
    let gh = dir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直すので、申告制は残さない。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })
  }

  /// head ごとに 1 回ずつ `each` が返り、**失敗した head だけが失敗**になる。
  /// 同時に走る本数は `branchFetchConcurrency`（4）を超えない。
  ///
  /// 上限は、4 本が門で止まっているあいだに 5 本めが始まらないことを、実時間で見張って確かめる（上限を超える起動が、もう
  /// 起きないと言える出来事が無い）。前提は、本番が固定の 4 本のレーンで、各レーンが自分の担当を直列に回すこと。上限を 5 以上に
  /// すると見張りが落ち、1 にすると 4 本が揃わずに期限で落ちることを確かめてある。レーンの組み方か上限を変えたときは、
  /// 確かめ直す。
  func testEachHeadLandsSeparatelyAndFailuresStayLocal() throws {
    let heads = (0..<9).map { $0 == 3 ? "bad/x" : "feat/\($0)" }
    var landed: [String: Result<[GitHubBranchPR], GitHubFailure>] = [:]
    let done = expectation(description: "branchPullRequests")
    done.expectedFulfillmentCount = heads.count
    GitHubCLI().branchPullRequests(cwd: dir.path, heads: heads) { head, prs in
      landed[head] = prs
      done.fulfill()
    }
    pumpMain(until: { started() == 4 }, "上限の 4 本が同時に走る")
    XCTAssertTrue(holds(for: 0.2) { started() == 4 }, "4 本が走っているあいだ、5 本めは始まらない")
    try FileManager.default.removeItem(at: gate)
    wait(for: [done], timeout: 30)

    XCTAssertEqual(Set(landed.keys), Set(heads), "head ごとに 1 回ずつ返る")
    XCTAssertEqual(
      try landed["feat/0"]?.get().first?.headRefName, "feat/0", "取れた head は自分の結果を受ける")
    XCTAssertEqual(landed["bad/x"], .failure(.reason("")), "落ちた head だけが失敗")
    XCTAssertEqual(
      landed.values.filter { (try? $0.get()) != nil }.count, heads.count - 1,
      "1 本の失敗が他を巻き込まない")
    XCTAssertLessThanOrEqual(maxOverlap(), 4, "同時実行は上限（4）を超えない")
    XCTAssertGreaterThan(maxOverlap(), 1, "直列に積み上がっていない")
  }

  /// 偽 `gh` が始めた本数。
  private func started() -> Int {
    let marks = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n") ?? []
    return marks.filter { $0 == "S" }.count
  }

  /// 偽 `gh` のログから同時に走っていた最大本数を数える。
  private func maxOverlap() -> Int {
    let marks = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n") ?? []
    var running = 0
    var peak = 0
    for mark in marks {
      running += mark == "S" ? 1 : -1
      peak = max(peak, running)
    }
    return peak
  }
}
