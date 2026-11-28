import OrbeTestSupport
import XCTest

@testable import Orbe

/// 範囲のスレッドの書き込みと読み——書き込みの mutation の字と変数、読みのレスポンスの始まりの行。壊れると、範囲のコメントが
/// 1 行のコメントとして積まれる・1 行のコメントの書き込みが GitHub に拒まれる・GitHub の画面で付いた範囲のスレッドが 1 行に出る。
final class GitHubReviewRangeTests: OrbeTestCase {
  private let range = GitHubLineRange(
    start: GitHubLine(side: .old, line: 16), end: GitHubLine(side: .new, line: 18))

  private func request(_ mutation: GitHubReviewMutation) throws -> (
    query: String, variables: [String: Any]
  ) {
    let body = try JSONSerialization.jsonObject(with: mutation.requestBody()) as? [String: Any]
    return (
      try XCTUnwrap(body?["query"] as? String),
      try XCTUnwrap(body?["variables"] as? [String: Any])
    )
  }

  /// 1 行のスレッドの mutation は、始まりの行の変数を宣言も渡しもしない。
  func testALineThreadDeclaresNoStart() throws {
    let thread = GitHubReviewMutation.Thread(path: "a.swift", lines: .at(.new, 3), body: "b")
    let created = try request(.createReview(pullRequest: "PR", commit: "h", thread: thread))
    XCTAssertEqual(
      created.query,
      "mutation($pr:ID!,$commit:GitObjectID!,$path:String!,$line:Int!,$side:DiffSide!,$body:String!)"
        + "{m:addPullRequestReview(input:{pullRequestId:$pr,commitOID:$commit,"
        + "threads:[{path:$path,line:$line,side:$side,body:$body}]}){pullRequestReview{id}}}")
    XCTAssertNil(created.variables["startLine"])
    let added = try request(.addThread(review: "R", thread))
    XCTAssertEqual(
      added.query,
      "mutation($review:ID!,$path:String!,$line:Int!,$side:DiffSide!,$body:String!)"
        + "{m:addPullRequestReviewThread(input:{pullRequestReviewId:$review,path:$path,"
        + "line:$line,side:$side,body:$body}){thread{id}}}")
  }

  /// 範囲のスレッドは、終わりの行を `line`・`side` に、始まりの行を `startLine`・`startSide` に渡す（未送信のレビューの有無の
  /// どちらの mutation でも）。
  func testARangeThreadSendsItsStart() throws {
    let thread = GitHubReviewMutation.Thread(path: "a.swift", lines: range, body: "b")
    for mutation in [
      GitHubReviewMutation.createReview(pullRequest: "PR", commit: "h", thread: thread),
      .addThread(review: "R", thread),
    ] {
      let sent = try request(mutation)
      XCTAssertTrue(sent.query.contains("$startLine:Int!,$startSide:DiffSide!"), sent.query)
      XCTAssertTrue(sent.query.contains("startLine:$startLine,startSide:$startSide"), sent.query)
      XCTAssertEqual(sent.variables["line"] as? Int, 18)
      XCTAssertEqual(sent.variables["side"] as? String, "RIGHT")
      XCTAssertEqual(sent.variables["startLine"] as? Int, 16)
      XCTAssertEqual(sent.variables["startSide"] as? String, "LEFT")
    }
  }

  /// 読みは、始まりの行と側を範囲の始まりにする。始まりの側が知らない値なら、1 行のスレッドとして読む。
  func testReadingAThreadReadsItsStart() throws {
    let node = { (start: String) in
      #"{"id":"T","isResolved":false,"isOutdated":false,"path":"a.swift","line":18,"#
        + #""diffSide":"RIGHT","startLine":16,"startDiffSide":\#(start),"subjectType":"LINE","#
        + #""viewerCanResolve":true,"viewerCanUnresolve":false,"viewerCanReply":true,"#
        + #""comments":{"nodes":[]}}"#
    }
    let decode = { (text: String) in
      try JSONDecoder().decode(GitHubPullRequestReview.Thread.self, from: Data(text.utf8))
    }
    XCTAssertEqual(try decode(node(#""LEFT""#)).lines, range)
    XCTAssertEqual(try decode(node(#""MIDDLE""#)).lines, .at(.new, 18))
    XCTAssertEqual(try decode(node("null")).lines, .at(.new, 18))
  }
}
