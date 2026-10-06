import OrbeTestSupport
import XCTest

@testable import Orbe

/// 結び付いた項目を番号で直接まとめて問い合わせる口（`GitHubItemQuery` と `GitHubCLI.items`）。
///
/// 壊れると何が起きるか: 問い合わせの別名と読み取りの別名が食い違うと、値が別の項目に付くか、全部が
/// 「無かった」になって ⌘⇧X の行と右の欄が番号だけのままになる。1 つでも消えた番号を含むと gh は非 0 で
/// 終わるので、終了コードで切ると、見つかった項目の値まで捨てる。gh が無いときに答えを返さないと、
/// 置き場はその項目を取得中のまま持ち続け、次に開いても取り直さない。
///
/// 応答は、問い合わせの別名を読んで GitHub と同じ形に組む（`respond`）。別名の付け方は実装の自由に残し、
/// 「問い合わせたとおりに返ってきた応答を、その項目の値として読む」ことだけを固定する。
final class GitHubCLIItemsTests: OrbeTestCase {
  private func id(_ repo: String, _ number: Int) throws -> GitHubItemID {
    try XCTUnwrap(GitHubItemID(repo: repo, number: number))
  }

  // MARK: - GitHub の応答の代わり

  private enum Node {
    static func issue(_ title: String, _ state: String = "OPEN") -> [String: Any] {
      ["__typename": "Issue", "title": title, "state": state]
    }

    static func pullRequest(
      _ title: String, state: String = "OPEN", isDraft: Bool = false,
      review: String? = "REVIEW_REQUIRED", author: String? = "nakatake",
      checks: String? = "SUCCESS",
      head: [String: Any]? = nil
    ) -> [String: Any] {
      var node: [String: Any] = [
        "__typename": "PullRequest", "title": title, "state": state, "isDraft": isDraft,
        "reviewDecision": review ?? NSNull(),
        "author": author.map { ["login": $0] } ?? NSNull(),
        "commits": [
          "nodes": [["commit": ["statusCheckRollup": checks.map { ["state": $0] } ?? NSNull()]]]
        ],
      ]
      node.merge(head ?? [:]) { $1 }
      return node
    }
  }

  /// 問い合わせ（`arguments`）の別名どおりに `data` を組む。`repositories` に無いリポジトリと、
  /// `items` に無い番号は null（GitHub の NOT_FOUND と同じ）。
  private func respond(
    to arguments: [String], viewer: String? = "nakatake",
    repositories: [String: [Int: [String: Any]]]
  ) throws -> Data {
    var variables: [String: String] = [:]
    for (index, argument) in arguments.enumerated() where argument == "-f" {
      let pair = arguments[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
      variables[pair[0]] = pair[1]
    }
    let query = try XCTUnwrap(variables["query"], "問い合わせが無い")
    let repoPattern = try NSRegularExpression(
      pattern: #"(\w+):repository\(owner:\$(\w+),name:\$(\w+)\)"#)
    let itemPattern = try NSRegularExpression(pattern: #"(\w+):issueOrPullRequest\(number:(\d+)\)"#)
    let text = query as NSString
    let repoMatches = repoPattern.matches(
      in: query, range: NSRange(location: 0, length: text.length))
    var data: [String: Any] = ["viewer": viewer.map { ["login": $0] } ?? NSNull()]
    var notFound = false
    for (index, match) in repoMatches.enumerated() {
      let owner = try XCTUnwrap(variables[text.substring(with: match.range(at: 2))])
      let name = try XCTUnwrap(variables[text.substring(with: match.range(at: 3))])
      let end = index + 1 < repoMatches.count ? repoMatches[index + 1].range.location : text.length
      let segment = NSRange(location: match.range.location, length: end - match.range.location)
      guard let items = repositories["\(owner)/\(name)".lowercased()] else {
        data[text.substring(with: match.range(at: 1))] = NSNull()
        notFound = true
        continue
      }
      var nodes: [String: Any] = [:]
      for item in itemPattern.matches(in: query, range: segment) {
        let number = try XCTUnwrap(Int(text.substring(with: item.range(at: 2))))
        nodes[text.substring(with: item.range(at: 1))] = items[number] ?? NSNull()
        notFound = notFound || items[number] == nil
      }
      data[text.substring(with: match.range(at: 1))] = nodes
    }
    var body: [String: Any] = ["data": data]
    if notFound { body["errors"] = [["type": "NOT_FOUND", "message": "Could not resolve"]] }
    return try JSONSerialization.data(withJSONObject: body)
  }

  private func read(
    _ ids: [GitHubItemID], viewer: String? = "nakatake",
    _ repositories: [String: [Int: [String: Any]]]
  ) throws -> GitHubItemsBatch? {
    let response = try respond(
      to: GitHubItemQuery.arguments(ids), viewer: viewer, repositories: repositories)
    return GitHubItemQuery.batch(from: response, ids: ids)
  }

  // MARK: - 問い合わせと読み取り

  /// owner と name は文字列のまま（`-f`）渡す——`-F` は数字だけの名前を整数に変え、問い合わせが失敗し続ける。
  func testQueryAsksGitHubDotComWithOwnerAndNameAsStrings() throws {
    let arguments = GitHubItemQuery.arguments([try id("gabrielecirulli/2048", 1)])

    XCTAssertEqual(Array(arguments.prefix(4)), ["api", "graphql", "--hostname", "github.com"])
    for value in ["gabrielecirulli", "2048"] {
      let index = try XCTUnwrap(
        arguments.firstIndex { $0.hasSuffix("=\(value)") }, "\(value) を変数で渡す")
      XCTAssertEqual(arguments[index - 1], "-f", "\(value) は文字列として渡す")
    }
  }

  func testIssuesAndPullRequestsAcrossRepositoriesAreReadFromOneResponse() throws {
    let ids = [try id("o/n", 212), try id("o/n", 213), try id("x/y", 5), try id("x/y", 6)]

    let batch = try read(
      ids,
      [
        "o/n": [
          212: Node.issue("設計"),
          213: Node.pullRequest("土台", review: "APPROVED", author: "sato", checks: "FAILURE"),
        ],
        "x/y": [5: Node.issue("古い", "CLOSED"), 6: Node.pullRequest("済み", state: "MERGED")],
      ])

    XCTAssertEqual(batch?.viewerLogin, "nakatake")
    XCTAssertEqual(
      batch?.answers,
      [
        ids[0]: .found(.init(title: "設計", state: .open, pullRequest: nil)),
        ids[1]: .found(
          .init(
            title: "土台", state: .open,
            pullRequest: .init(isDraft: false, review: .approved, checks: .failure, author: "sato"))
        ),
        ids[2]: .found(.init(title: "古い", state: .closed, pullRequest: nil)),
        ids[3]: .found(
          .init(
            title: "済み", state: .merged,
            pullRequest: .init(
              isDraft: false, review: .reviewRequired, checks: .success, author: "nakatake"))),
      ])
  }

  /// 消えた番号・見えないリポジトリは「無かった」。ほかの項目の値は読む。
  func testItemsGitHubCannotResolveAreMissingAndTheRestAreStillRead() throws {
    let found = try id("o/n", 1)
    let gone = try id("o/n", 2)
    let hiddenRepo = try id("secret/repo", 3)

    let batch = try read([found, gone, hiddenRepo], ["o/n": [1: Node.issue("ある")]])

    XCTAssertEqual(
      batch?.answers[found], .found(.init(title: "ある", state: .open, pullRequest: nil)))
    XCTAssertEqual(batch?.answers[gone], .missing)
    XCTAssertEqual(batch?.answers[hiddenRepo], .missing)
  }

  func testPullRequestWithoutReviewChecksOrAuthorReadsThemAsAbsent() throws {
    let pr = try id("o/n", 1)

    let batch = try read(
      [pr],
      ["o/n": [1: Node.pullRequest("下書き", isDraft: true, review: nil, author: nil, checks: nil)]])

    XCTAssertEqual(
      batch?.answers[pr],
      .found(
        .init(
          title: "下書き", state: .open,
          pullRequest: .init(isDraft: true, review: nil, checks: nil, author: nil))))
  }

  /// PR の head（ブランチ名と、それが載るリポジトリ）を読む。タスクから開いた ⌘T が PR のブランチを探す元。
  /// head のリポジトリが消えていれば head は無い。
  func testPullRequestHeadIsReadAndAGoneHeadRepositoryReadsAsNoHead() throws {
    let fromFork = try id("o/n", 1)
    let goneFork = try id("o/n", 2)
    let arguments = GitHubItemQuery.arguments([fromFork, goneFork])
    for field in ["headRefName", "headRepositoryOwner", "headRepository"] {
      XCTAssertTrue(arguments.contains { $0.contains(field) }, "問い合わせが \(field) を求める")
    }

    let batch = try read(
      [fromFork, goneFork],
      [
        "o/n": [
          1: Node.pullRequest(
            "英訳",
            head: [
              "headRefName": "docs/readme-en", "headRepositoryOwner": ["login": "me"],
              "headRepository": ["name": "n"],
            ]),
          2: Node.pullRequest(
            "消えた",
            head: [
              "headRefName": "fix", "headRepositoryOwner": ["login": "ghost"],
              "headRepository": NSNull(),
            ]),
        ]
      ])

    guard case .found(let summary) = batch?.answers[fromFork],
      case .found(let gone) = batch?.answers[goneFork]
    else { return XCTFail("PR として読めない") }
    XCTAssertEqual(
      summary.pullRequest?.head,
      GitHubBranchRef(repo: GitHubRepoName(nameWithOwner: "me/n"), branch: "docs/readme-en"))
    XCTAssertNil(gone.pullRequest?.head)
  }

  /// `data` の無い応答（出力の無い失敗・問い合わせ自体のエラー）は、その回の失敗。
  func testAResponseWithoutDataIsAFailedQuery() throws {
    let ids = [try id("o/n", 1)]

    XCTAssertNil(GitHubItemQuery.batch(from: Data(), ids: ids), "出力の無い失敗")
    XCTAssertNil(
      GitHubItemQuery.batch(
        from: Data(#"{"errors":[{"message":"Bad credentials"}]}"#.utf8), ids: ids),
      "問い合わせ自体のエラー")
  }

  // MARK: - gh を起こす口

  /// 決まった出力と終了コードを返す偽 `gh` を PATH に置き、呼ばれるたびに 1 行を記録させる。
  private func stageGh(stdout: Data, exit: Int32) throws -> URL {
    let dir = TestScratch.caseDir
      .appendingPathComponent("orbe-gh-items-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = dir.appendingPathComponent("body.json")
    try stdout.write(to: body)
    let calls = dir.appendingPathComponent("calls.log")
    let gh = dir.appendingPathComponent("gh").path
    try "#!/bin/sh\necho call >> \"\(calls.path)\"\ncat \"\(body.path)\"\nexit \(exit)\n".write(
      toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直す。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })
    return calls
  }

  /// `items` が返す回を、届いた順に集める。
  private func fetch(_ ids: [GitHubItemID], batches: Int) -> [([GitHubItemID], GitHubItemsBatch?)] {
    var landed: [([GitHubItemID], GitHubItemsBatch?)] = []
    let done = expectation(description: "items")
    done.expectedFulfillmentCount = batches
    GitHubCLI().items(ids) { ids, batch in
      landed.append((ids, batch))
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return landed
  }

  func testValuesAreReadDespiteTheNonZeroExitOfANotFoundItem() throws {
    let found = try id("o/n", 1)
    let gone = try id("o/n", 2)
    let response = try respond(
      to: GitHubItemQuery.arguments([found, gone]), repositories: ["o/n": [1: Node.issue("ある")]])
    _ = try stageGh(stdout: response, exit: 1)

    let landed = fetch([gone, found], batches: 1)

    XCTAssertEqual(Set(landed.first?.0 ?? []), [found, gone])
    XCTAssertEqual(
      landed.first?.1?.answers[found], .found(.init(title: "ある", state: .open, pullRequest: nil)))
    XCTAssertEqual(landed.first?.1?.answers[gone], .missing)
  }

  /// 1 回に載せきれない数は、続く問い合わせに分けて出し、回ごとに答えを返す。どの項目も 1 回にだけ載る。
  func testItemsBeyondOneQueryAreAskedInFollowingQueriesEachAnsweredOnItsOwn() throws {
    let calls = try stageGh(stdout: Data(#"{"data":{}}"#.utf8), exit: 0)
    let ids = try (1...(GitHubCLI.itemsPerQuery * 2 + 1)).map { try id("o/n", $0) }

    let landed = fetch(ids, batches: 3)

    XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 3)
    XCTAssertTrue(landed.allSatisfy { $0.0.count <= GitHubCLI.itemsPerQuery }, "1 回は上限まで")
    XCTAssertEqual(landed.flatMap(\.0).sorted { $0.number < $1.number }, ids, "どの項目も 1 回にだけ載る")
    for (batchIDs, batch) in landed {
      XCTAssertEqual(Set(batch?.answers.keys.map { $0 } ?? []), Set(batchIDs), "その回の項目に答える")
    }
  }

  /// gh が答えを返さずに落ちたら（未認証・オフライン・打ち切り）、どの回も失敗（nil）として返る——
  /// 返らなければ置き場はその項目を取得中のまま持ち続ける。
  func testWhenGhFailsEveryQueryReturnsAsFailed() throws {
    _ = try stageGh(stdout: Data(), exit: 1)
    let ids = try (1...(GitHubCLI.itemsPerQuery + 1)).map { try id("o/n", $0) }

    let landed = fetch(ids, batches: 2)

    XCTAssertEqual(Set(landed.flatMap(\.0)), Set(ids))
    XCTAssertTrue(landed.allSatisfy { $0.1 == nil })
  }
}
