import OrbeTestSupport
import XCTest

@testable import Orbe

/// open 一覧の取得口（`GitHubCLI.openIssues` / `openPullRequests`）。
///
/// **1 ページ＝1 回の gh 呼び出しで、届いた順に渡し、上限か最後のページで止まり、途中の失敗までに渡した
/// ページは有効なまま**——これが崩れると、重いリポジトリで 1 回の打ち切りが一覧全体を失わせる形に戻るか、
/// 上限を越えて裏で問い合わせ続ける。PATH に偽の `gh` を置いて本物の子プロセスで測る。
final class GitHubCLIOpenListFetchTests: OrbeTestCase {
  private var dir: URL!
  private let repo = GitHubRepoName(nameWithOwner: "o/2048")

  /// 偽 `gh` の振る舞い。`available` 件の open 一覧を持ち、1 回に最大 `pageMax` 件返す。
  /// `failAt` の位置から始まるページは非 0 で落ちる。
  private func stageGh(available: Int, pageMax: Int = 100, failAt: Int = -1, sleep: Double = 0)
    throws
  {
    dir = TestScratch.caseDir
      .appendingPathComponent("orbe-gh-open-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 引数から first・endCursor・対象（--jq の connection）を拾って記録し、1 ページぶんの JSON を返す。
    // カーソルは「ここまでに返した件数」を c<n> で表す。
    let script = """
      #!/bin/sh
      first=""; cursor=""; jq=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -F) case "$2" in first=*) first="${2#first=}" ;; esac; shift ;;
          -f) case "$2" in endCursor=*) cursor="${2#endCursor=}" ;; esac; shift ;;
          --jq) jq="$2"; shift ;;
        esac
        shift
      done
      offset="${cursor#c}"; [ -z "$offset" ] && offset=0
      conn=issues; case "$jq" in *pullRequests*) conn=pullRequests ;; esac
      printf 'S %s %s %s\\n' "$conn" "$first" "${cursor:--}" >> "\(dir.path)/calls.log"
      sleep \(sleep)
      printf 'E\\n' >> "\(dir.path)/calls.log"
      [ "$offset" = "\(failAt)" ] && exit 1
      count=$first
      [ "$count" -gt \(pageMax) ] && count=\(pageMax)
      left=$((\(available) - offset))
      [ "$count" -gt "$left" ] && count=$left
      printf '{"nodes":['
      i=1
      while [ "$i" -le "$count" ]; do
        [ "$i" -gt 1 ] && printf ','
        n=$((offset + i))
        printf '{"__typename":"Issue","number":%d,"title":"t%d",' "$n" "$n"
        printf '"updatedAt":"2026-10-01T00:00:00Z"}'
        i=$((i + 1))
      done
      end=$((offset + count))
      next=false; [ "$end" -lt \(available) ] && next=true
      printf '],"pageInfo":{"hasNextPage":%s,"endCursor":"c%d"}}' "$next" "$end"
      """
    let gh = dir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直すので、申告制は残さない。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })
  }

  /// 偽 `gh` が受けた呼び出し（first・カーソル）を順に返す。
  private func calls() -> [(first: Int, cursor: String)] {
    let lines =
      (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8))?
      .split(separator: "\n") ?? []
    return lines.filter { $0.hasPrefix("S ") }.map {
      let parts = $0.split(separator: " ").map(String.init)
      return (Int(parts[2]) ?? -1, parts[3])
    }
  }

  /// 偽 `gh` が `connection`（issues / pullRequests）について受けた 1 ページの件数を順に返す。
  private func requestedFirsts(_ connection: String) -> [Int] {
    let lines =
      (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8))?
      .split(separator: "\n") ?? []
    return lines.map { $0.split(separator: " ").map(String.init) }
      .filter { $0.first == "S" && $0[1] == connection }
      .map { Int($0[2]) ?? -1 }
  }

  /// 走っていた gh の最大本数。
  private func maxOverlap() -> Int {
    let lines =
      (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8))?
      .split(separator: "\n") ?? []
    var running = 0
    var peak = 0
    for line in lines {
      running += line.hasPrefix("S ") ? 1 : -1
      peak = max(peak, running)
    }
    return peak
  }

  /// 1 本の取得で届いたページ（届いた順）と終わり方。
  private func fetchIssues() -> (pages: [[Int]], finished: [Bool]) {
    var pages: [[Int]] = []
    var finished: [Bool] = []
    let done = expectation(description: "openIssues")
    GitHubCLI().openIssues(
      repo: repo, page: { pages.append($0.map(\.number)) },
      finished: {
        finished.append($0)
        done.fulfill()
      })
    wait(for: [done], timeout: 60)
    return (pages, finished)
  }

  // MARK: - 問い合わせ

  /// ホストは認証確認と同じ github.com を名指しする（`gh api` は作業ディレクトリからホストを決めないので、
  /// 名指ししないと確かめた先と取りに行く先がずれうる）。リポジトリは `-f`（文字列のまま）で渡す——`-F` は
  /// 数字だけの名前を整数に変える。
  func testPageQueryNamesGitHubDotComAndPassesTheRepositoryAsStrings() throws {
    for page in [
      GitHubCLI.openIssuesPageArguments(repo: repo, first: 100, after: nil),
      GitHubCLI.openPullRequestsPageArguments(repo: repo, first: 50, after: "Y3Vyc29y"),
    ] {
      XCTAssertTrue(zip(page, page.dropFirst()).contains { $0 == ("--hostname", "github.com") })
      for field in ["owner=o", "name=2048"] {
        let index = try XCTUnwrap(page.firstIndex(of: field), "\(field) を渡す")
        XCTAssertEqual(page[index - 1], "-f", "\(field) は文字列のまま渡す")
      }
    }
  }

  // MARK: - ページの列

  /// 次のページがある間は前のページの位置から取り続け、最後のページで止まる。ページは届いた順に渡る。
  func testPagesArriveInOrderUntilTheLastPage() throws {
    try stageGh(available: 150)
    let result = fetchIssues()

    XCTAssertEqual(result.pages.map(\.count), [100, 50])
    XCTAssertEqual(result.pages.first?.first, 1, "新しい順の先頭から")
    XCTAssertEqual(result.pages.last?.first, 101, "2 ページ目は 1 ページ目の続き")
    XCTAssertEqual(calls().map(\.cursor), ["-", "c100"], "2 ページ目は 1 ページ目の位置から")
    XCTAssertEqual(result.finished, [true], "最後のページで取り終える")
  }

  /// 上限で止まり、最後のページは残り件数だけを頼む（上限を越えて問い合わせない）。
  func testFetchStopsAtTheLimitWithoutAskingBeyondIt() throws {
    let pageMax = 60
    try stageGh(available: 5000, pageMax: pageMax)
    let result = fetchIssues()
    let limit = GitHubCLI.openIssueLimit
    XCTAssertEqual(result.pages.joined().count, limit, "上限で止まる")
    XCTAssertEqual(calls().last?.first, limit - (calls().count - 1) * pageMax, "最後のページは残りだけ頼む")
    XCTAssertEqual(result.finished, [true], "上限に達したら取り終えた扱い")
  }

  /// PR は 1 ページ 50 件ずつ、issue は 100 件ずつ頼む——PR はレビュー状態・CI・レビュー依頼の算出で重く、
  /// 100 件では GitHub がサーバ側で打ち切る 10 秒に届き、一覧ごと取れなくなる。
  func testPullRequestPagesAskForFiftyAndIssuePagesForAHundred() throws {
    try stageGh(available: 120, pageMax: 1000)
    let done = expectation(description: "both")
    done.expectedFulfillmentCount = 2
    let cli = GitHubCLI()
    cli.openIssues(repo: repo, page: { _ in }, finished: { _ in done.fulfill() })
    cli.openPullRequests(repo: repo, page: { _ in }, finished: { _ in done.fulfill() })
    wait(for: [done], timeout: 60)

    XCTAssertEqual(requestedFirsts("pullRequests"), [50, 50, 50])
    XCTAssertEqual(requestedFirsts("issues"), [100, 100])
  }

  /// 途中のページが落ちたら失敗で終わるが、それまでに渡したページはそのまま（取り消しは来ない）。
  func testFailureMidwayEndsAfterTheDeliveredPages() throws {
    try stageGh(available: 300, failAt: 100)
    let result = fetchIssues()
    XCTAssertEqual(result.pages.map(\.count), [100], "落ちる前のページは渡っている")
    XCTAssertEqual(result.finished, [false])
    XCTAssertEqual(calls().count, 2, "落ちたページの先は問い合わせない")
  }

  /// issue と PR の一覧は互いを待たない（PR の表示が issue の取得完了を待たない）。
  func testIssueAndPullRequestListsRunInParallel() throws {
    try stageGh(available: 10, sleep: 0.5)
    let done = expectation(description: "both")
    done.expectedFulfillmentCount = 2
    let cli = GitHubCLI()
    cli.openIssues(repo: repo, page: { _ in }, finished: { _ in done.fulfill() })
    cli.openPullRequests(repo: repo, page: { _ in }, finished: { _ in done.fulfill() })
    wait(for: [done], timeout: 30)
    XCTAssertEqual(maxOverlap(), 2, "issue と PR の問い合わせが同時に走る")
  }
}
