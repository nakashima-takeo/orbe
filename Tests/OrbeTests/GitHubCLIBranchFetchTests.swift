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

  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-gh-branch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    log = dir.appendingPathComponent("lanes.log").path
    // `--head <name>` の name を拾い、`bad/*` は非 0 で落ち、それ以外は 1 件返す。
    // 走っている間の重なりを記録して、同時実行の上限を測る。
    let script = """
      #!/bin/sh
      head=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "--head" ]; then head="$2"; fi
        shift
      done
      printf 'S\\n' >> "\(log!)"
      sleep 0.2
      printf 'E\\n' >> "\(log!)"
      case "$head" in
        bad/*) exit 1 ;;
      esac
      printf '[{"number":1,"headRefName":"%s","state":"OPEN","baseRefName":"main","isCrossRepository":false}]' "$head"
      """
    let gh = dir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直すので、申告制は残さない。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  /// head ごとに 1 回ずつ `each` が返り、**失敗した head だけが `nil`** になる。
  /// 同時に走る本数は `branchFetchConcurrency`（4）を超えない。
  func testEachHeadLandsSeparatelyAndFailuresStayLocal() throws {
    let heads = (0..<9).map { $0 == 3 ? "bad/x" : "feat/\($0)" }
    var landed: [String: [GitHubBranchPR]?] = [:]
    let done = expectation(description: "branchPullRequests")
    done.expectedFulfillmentCount = heads.count
    GitHubCLI().branchPullRequests(cwd: dir.path, heads: heads) { head, prs in
      landed[head] = prs
      done.fulfill()
    }
    wait(for: [done], timeout: 30)

    XCTAssertEqual(Set(landed.keys), Set(heads), "head ごとに 1 回ずつ返る")
    XCTAssertEqual(landed["feat/0"]??.first?.headRefName, "feat/0", "取れた head は自分の結果を受ける")
    XCTAssertEqual(landed["bad/x"], .some(nil), "落ちた head だけが nil")
    XCTAssertEqual(
      landed.values.filter { $0 != nil }.count, heads.count - 1, "1 本の失敗が他を巻き込まない")
    // 契約は「上限で頭打ち」と「直列でない」の 2 つ。ピークがちょうど 4 になるかは子プロセスの
    // 起動タイミング次第なので、そこは固定しない（壊れていないのに赤くなる）。
    XCTAssertLessThanOrEqual(maxOverlap(), 4, "同時実行は上限（4）を超えない")
    XCTAssertGreaterThan(maxOverlap(), 1, "直列に積み上がっていない")
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
