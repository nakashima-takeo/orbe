import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR のレビューのやりとりの読み取り（`GitHubCLI.pullRequestReview`）と書き込み（`GitHubCLI.writeReview`）。PATH に偽の `gh`
/// を置いて本物の子プロセスで測る。
///
/// 壊れると何が起きるか: スレッドが 100 件で切れる。読んでいる間の push で古いスレッドと新しいスレッドが混ざる。本文が argv に
/// 出る・`@` で始まる本文がファイルの中身に化ける・長い本文が切れる。未送信のレビューが無いときのスレッドの追加で、空の未送信の
/// レビューが GitHub に残る。書き込みが読みと同じ短い上限で打ち切られ、届いたか分からない書き込みが増える。
final class GitHubCLIReviewTests: OrbeTestCase {
  private var dir: URL!
  private let id = GitHubItemID(repo: "o/2048", number: 7)!

  /// 偽 `gh`。呼び出しを種類（読みは `first`・`threads-<カーソル>`、書き込みは標準入力の mutation の名前から `create`・`thread`・
  /// `reply`・`resolve`・`unresolve`・`submit`）に分けて `calls.log` に残し、argv を `argv.<n>`、標準入力を `in.<n>` に
  /// 残す。答えは種類ごとのファイル（n 回目の呼び出しは `<種類>.<n>` があればそれ）、無ければ `{"data":{"m":{"x":{"id":
  /// "<種類>-id"}}}}`。`<種類>.gate` があれば、その種類の k 回目の呼び出しは、待ちに入った印 `<種類>.waiting.<k>` を置いて、
  /// 合図 `<種類>.open.<k>` が現れるまで待つ。`<種類>.stderr` を標準エラーへ出し、`<種類>.exit` の終了コードで終わる。
  override func setUpWithError() throws {
    dir = TestScratch.caseDir.appendingPathComponent("orbe-gh-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      D="\(dir.path)"
      n=$(( $(cat "$D/count" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$D/count"
      printf '%s\\n' "$@" > "$D/argv.$n"
      query=""; after=""; input=0
      while [ $# -gt 0 ]; do
        case "$1" in
          -f|-F)
            case "$2" in
              query=*) query="${2#query=}" ;;
              after=*) after="${2#after=}" ;;
            esac
            shift ;;
          --input) input=1; shift ;;
        esac
        shift
      done
      if [ "$input" = 1 ]; then
        cat > "$D/in.$n"
        case "$(cat "$D/in.$n")" in
          *addPullRequestReviewThreadReply*) kind=reply ;;
          *addPullRequestReviewThread*) kind=thread ;;
          *unresolveReviewThread*) kind=unresolve ;;
          *resolveReviewThread*) kind=resolve ;;
          *submitPullRequestReview*) kind=submit ;;
          *) kind=create ;;
        esac
      else
        case "$query" in
          *'reviewThreads(first:100,after'*) kind="threads-$after" ;;
          *) kind=first ;;
        esac
      fi
      echo "$kind" >> "$D/calls.log"
      k=$(( $(cat "$D/$kind.count" 2>/dev/null || echo 0) + 1 ))
      echo "$k" > "$D/$kind.count"
      f="$D/$kind"; [ -e "$f.$k" ] && f="$f.$k"
      if [ -e "$D/$kind.gate" ]; then
        : > "$D/$kind.waiting.$k"
        while [ ! -e "$D/$kind.open.$k" ] && [ -d "$D" ]; do sleep 0.05; done
      fi
      if [ -e "$f" ]; then cat "$f"; else printf '{"data":{"m":{"x":{"id":"%s-id"}}}}' "$kind"; fi
      [ -e "$D/$kind.stderr" ] && cat "$D/$kind.stderr" >&2
      [ -e "$D/$kind.exit" ] && exit "$(cat "$D/$kind.exit")"
      exit 0
      """
    let gh = dir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { "\(path):/usr/bin:/bin" })
  }

  private func serve(_ kind: String, _ text: String) throws {
    try text.write(to: dir.appendingPathComponent(kind), atomically: true, encoding: .utf8)
  }

  private func calls() -> [String] {
    let text = try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)
    return text?.split(separator: "\n").map(String.init) ?? []
  }

  /// n 回目の呼び出しの argv と、標準入力の JSON の変数。
  private func call(_ n: Int) throws -> (argv: [String], variables: [String: Any]) {
    let argv = try String(contentsOf: dir.appendingPathComponent("argv.\(n)"), encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    let input = try Data(contentsOf: dir.appendingPathComponent("in.\(n)"))
    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
    return (argv, try XCTUnwrap(request["variables"] as? [String: Any]))
  }

  // MARK: - 読み

  private func thread(
    _ id: String, line: String = "3", side: String = "RIGHT", subject: String = "LINE",
    outdated: Bool = false
  )
    -> String
  {
    #"{"id":"\#(id)","isResolved":false,"isOutdated":\#(outdated),"path":"a.swift","line":\#(line),"#
      + #""diffSide":"\#(side)","#
      + #""subjectType":"\#(subject)","viewerCanResolve":true,"viewerCanUnresolve":false,"#
      + #""viewerCanReply":true,"comments":{"nodes":[{"id":"C\#(id)","author":{"login":"you"},"#
      + #""body":"b","createdAt":"2026-11-17T01:02:03Z","state":"PENDING"},{"id":"D\#(id)","#
      + #""author":null,"body":"c","createdAt":"2026-11-17T02:00:00Z","state":"SUBMITTED"}]}}"#
  }

  private func threads(_ nodes: [String], next cursor: String?) -> String {
    #"{"nodes":[\#(nodes.joined(separator: ","))],"pageInfo":{"hasNextPage":\#(cursor != nil),"#
      + #""endCursor":"\#(cursor ?? "end")"}}"#
  }

  private func firstPage(head: String = "h1", _ page: String) -> String {
    #"{"data":{"repository":{"pullRequest":{"headRefOid":"\#(head)","#
      + #""viewerDidAuthor":true,"reviews":{"nodes":[{"id":"R1","#
      + #""comments":{"totalCount":2}}]},"reviewThreads":\#(page)}}}}"#
  }

  private func nextPage(head: String = "h1", _ page: String) -> String {
    #"{"data":{"repository":{"pullRequest":{"headRefOid":"\#(head)","reviewThreads":\#(page)}}}}"#
  }

  private func read() -> Result<GitHubPullRequestReview, GitHubFailure>? {
    var result: Result<GitHubPullRequestReview, GitHubFailure>?
    let done = expectation(description: "pullRequestReview")
    GitHubCLI().pullRequestReview(id) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return result
  }

  /// 100 件を超えるスレッドは続きのページを最後まで読み、自分が作者か・未送信のレビューとそのコメントの数も揃う。
  /// ファイル単位のスレッドと、行が null（古い版に付いた）のスレッドは行を持たない。
  func testEveryThreadPageIsReadWithThePendingReview() throws {
    let first = (0..<100).map { thread("T\($0)") }
    try serve("first", firstPage(threads(first, next: "P1")))
    try serve(
      "threads-P1",
      nextPage(
        threads(
          [
            thread("F", subject: "FILE"), thread("O", line: "null", side: "LEFT"),
            thread("K", line: "5", outdated: true),
          ], next: nil)))

    let review = try XCTUnwrap(read()).get()

    XCTAssertTrue(review.viewerIsAuthor)
    XCTAssertEqual(review.headCommit, "h1")
    XCTAssertEqual(review.pendingReview, .init(id: "R1", commentCount: 2))
    XCTAssertEqual(review.threads.count, 103)
    XCTAssertEqual(review.threads[0].lines, .at(.new, 3))
    XCTAssertTrue(review.threads[0].canReply)
    XCTAssertEqual(review.threads[0].comments.map(\.isPending), [true, false])
    XCTAssertNil(review.threads[0].comments[1].author, "消えたアカウント")
    XCTAssertEqual(
      review.threads[0].comments[0].createdAt, Date(timeIntervalSince1970: 1_794_877_323))
    XCTAssertNil(review.threads[100].lines, "ファイル単位")
    XCTAssertNil(review.threads[101].lines, "古い版に付いた")
    XCTAssertNil(review.threads[102].lines, "古い版に付いたスレッドは、行の値が残っていても置かない")
  }

  /// ページの間に push があれば、最初から読み直して新しい時点のスレッドだけを返す。読み直した後も PR の先頭のコミットが動けば失敗。
  func testAPushBetweenThreadPagesRereadsFromTheStart() throws {
    try serve("first.1", firstPage(head: "h1", threads([thread("old")], next: "P1")))
    try serve("threads-P1.1", nextPage(head: "h2", threads([thread("new2")], next: nil)))
    try serve("first.2", firstPage(head: "h2", threads([thread("new1")], next: "P1")))
    try serve("threads-P1.2", nextPage(head: "h2", threads([thread("new2")], next: nil)))

    let review = try XCTUnwrap(read()).get()
    XCTAssertEqual(review.threads.map(\.id), ["new1", "new2"])
    XCTAssertEqual(review.headCommit, "h2")

    try serve("threads-P1.3", nextPage(head: "h3", threads([], next: nil)))
    try serve("threads-P1.4", nextPage(head: "h4", threads([], next: nil)))
    try serve("first.3", firstPage(head: "h2", threads([], next: "P1")))
    try serve("first.4", firstPage(head: "h3", threads([], next: "P1")))
    XCTAssertEqual(read(), .failure(.reason("")))
  }

  /// 続きのページの失敗は、それまでのページを返さず、全体の失敗。
  func testAFailedThreadPageFailsTheWholeRead() throws {
    try serve("first", firstPage(threads([thread("T1")], next: "P1")))
    try serve("threads-P1.stderr", "error connecting to api.github.com\n")
    try serve("threads-P1.exit", "1")

    XCTAssertEqual(read(), .failure(.unreachable))
  }

  // MARK: - 書き込み

  private func write(
    _ write: GitHubReviewWrite, pendingReview: String?
  ) -> GitHubReviewWriteResult? {
    var result: GitHubReviewWriteResult?
    let done = expectation(description: "writeReview")
    GitHubCLI().writeReview(
      write, pullRequest: "PR_1", pendingReview: pendingReview, reviewedCommit: "seen"
    ) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return result
  }

  /// どの書き込みも、本文を argv に載せず標準入力の JSON で渡す。改行・引用符・`@`・先頭のハイフン・絵文字・64KB を超える長さ
  /// の本文も、そのまま届く。
  func testEveryWriteSendsItsBodyThroughStandardInput() throws {
    let bodies = [
      "1 行目\n2 行目\n\n\"引用\" と 'single'", "@path/to/file", "-F body=x", "絵文字 👍🏽🇯🇵",
      String(repeating: "長い本文 ", count: 20_000),
    ]
    var n = 0
    for body in bodies {
      for kind in [
        GitHubReviewWrite.addThread(path: "a.swift", lines: .at(.new, 3), commit: "h1", body: body),
        .reply(thread: "T1", body: body, resolve: false),
        .submit(.approve, body: body), .submit(.comment, body: body),
        .submit(.requestChanges, body: body),
      ] {
        XCTAssertEqual(write(kind, pendingReview: "R1")?.failure, nil)
        n += 1
        let sent = try call(n)
        XCTAssertEqual(sent.argv, ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        XCTAssertEqual(sent.variables["body"] as? String, body, "\(kind) の本文")
      }
    }
    XCTAssertEqual(try call(3).variables["event"] as? String, "APPROVE")
    XCTAssertEqual(try call(4).variables["event"] as? String, "COMMENT")
    XCTAssertEqual(try call(5).variables["event"] as? String, "REQUEST_CHANGES")
  }

  /// 解決と解決の取り消しはスレッドだけを名指しし、未送信のレビューを変えない。全体へのコメントが空の送信は本文を送らない。
  func testResolvingNamesTheThreadAndAnEmptySubmissionSendsNoBody() throws {
    XCTAssertEqual(
      write(.setResolved(thread: "T1", true), pendingReview: "R1"),
      GitHubReviewWriteResult(pendingReview: "R1", failure: nil))
    XCTAssertEqual(
      write(.setResolved(thread: "T1", false), pendingReview: nil),
      GitHubReviewWriteResult(pendingReview: nil, failure: nil))
    XCTAssertEqual(
      write(.submit(.approve, body: ""), pendingReview: "R1"),
      GitHubReviewWriteResult(pendingReview: nil, failure: nil), "送信が通れば未送信は無くなる")

    XCTAssertEqual(calls(), ["resolve", "unresolve", "submit"])
    XCTAssertEqual(try call(1).variables["thread"] as? String, "T1")
    XCTAssertNil(try call(3).variables["body"])
    XCTAssertFalse(
      try String(contentsOf: dir.appendingPathComponent("in.3"), encoding: .utf8).contains("$body"),
      "本文の変数を宣言もしない")
  }

  /// 未送信のレビューが無いときのスレッドの追加は、レビューの作成と最初のスレッドを 1 回で送る。無いときの返信は、利用者が
  /// 見ていた先頭のコミットに結んで作ってから返信し、在るときは作らない。無いときの送信は、作ってすぐ送る 1 回で、利用者が
  /// 見ていた先頭のコミットに結ぶ。在るときの送信は結ばない。
  func testAMissingPendingReviewIsCreatedInTheFewestCalls() throws {
    XCTAssertEqual(
      write(
        .addThread(path: "a.swift", lines: .at(.old, 9), commit: "h1", body: "b"),
        pendingReview: nil),
      GitHubReviewWriteResult(pendingReview: "create-id", failure: nil))
    XCTAssertEqual(calls(), ["create"])
    let created = try call(1).variables
    XCTAssertEqual(created["pr"] as? String, "PR_1")
    XCTAssertEqual(created["side"] as? String, "LEFT")
    XCTAssertEqual(created["line"] as? Int, 9)
    XCTAssertEqual(created["commit"] as? String, "h1", "行を数えた先頭のコミットにレビューを結ぶ")
    XCTAssertFalse(
      try String(contentsOf: dir.appendingPathComponent("in.1"), encoding: .utf8)
        .contains("event"), "作るときは送信の種類を渡さない")

    XCTAssertEqual(
      write(.reply(thread: "T1", body: "b", resolve: false), pendingReview: nil),
      GitHubReviewWriteResult(pendingReview: "create-id", failure: nil, replied: true))
    XCTAssertEqual(calls(), ["create", "create", "reply"])
    XCTAssertEqual(try call(3).variables["review"] as? String, "create-id")
    XCTAssertEqual(
      try call(2).variables["commit"] as? String, "seen", "行を持たない返信でも、見ていた先頭に結ぶ")

    _ = write(.reply(thread: "T1", body: "b", resolve: false), pendingReview: "R1")
    _ = write(
      .addThread(path: "a.swift", lines: .at(.new, 1), commit: "h1", body: "b"), pendingReview: "R1"
    )
    XCTAssertEqual(calls().suffix(2), ["reply", "thread"], "在れば作らない")
    XCTAssertEqual(try call(5).variables["review"] as? String, "R1")

    _ = write(.submit(.comment, body: "b"), pendingReview: nil)
    XCTAssertEqual(calls().last, "create")
    XCTAssertEqual(try call(6).variables["event"] as? String, "COMMENT")
    XCTAssertEqual(try call(6).variables["commit"] as? String, "seen", "見ていた先頭に結ぶ")

    _ = write(.submit(.comment, body: "b"), pendingReview: "R1")
    XCTAssertEqual(calls().last, "submit")
    XCTAssertNil(try call(7).variables["commit"])
  }

  /// 「解決して返信」は返信 → 解決の順で、返信が通らなければ解決を送らない。解決だけが通らなければ、返信が通ったことを返す。
  /// 作った未送信のレビューは、返信が通らなくても返す。
  func testReplyThenResolveStopsAtAFailedReply() throws {
    XCTAssertEqual(
      write(.reply(thread: "T1", body: "b", resolve: true), pendingReview: "R1")?.failure, nil)
    XCTAssertEqual(calls(), ["reply", "resolve"])

    try serve("resolve.exit", "1")
    let resolveFailed = write(.reply(thread: "T1", body: "b", resolve: true), pendingReview: "R1")
    XCTAssertNotNil(resolveFailed?.failure, "解決だけが通らない")
    XCTAssertEqual(resolveFailed?.replied, true, "返信が通ったことは分かる")
    try serve("resolve.exit", "0")

    try serve("reply.stderr", "gh: Could not resolve to a node\n")
    try serve("reply.exit", "1")
    XCTAssertEqual(
      write(.reply(thread: "T1", body: "b", resolve: true), pendingReview: nil),
      GitHubReviewWriteResult(
        pendingReview: "create-id", failure: .reason("gh: Could not resolve to a node")))
    XCTAssertEqual(calls().suffix(2), ["create", "reply"], "解決は送らない")
  }

  /// GitHub がエラーを返した書き込み（diff の外の行など）は、GitHub のエラー文の要点を持つ、失敗の種類の「それ以外」。gh が 0 で終わっても
  /// 書き込みの値が null なら失敗。
  func testAWriteGitHubRejectsFailsWithItsReason() throws {
    try serve("thread", #"{"data":{"m":null},"errors":[{"message":"Line could not be resolved"}]}"#)
    try serve("thread.stderr", "gh: Line could not be resolved\n")
    try serve("thread.exit", "1")
    XCTAssertEqual(
      write(
        .addThread(path: "a.swift", lines: .at(.new, 99), commit: "h1", body: "b"),
        pendingReview: "R1"),
      GitHubReviewWriteResult(
        pendingReview: "R1", failure: .reason("gh: Line could not be resolved")))

    try serve("resolve", #"{"data":{"m":null}}"#)
    XCTAssertEqual(
      write(.setResolved(thread: "T1", true), pendingReview: "R1")?.failure, .reason(""))
  }
}

// MARK: - 時間上限

extension GitHubCLIReviewTests {
  /// 偽 `gh` の、その種類の k 回目の呼び出しが、合図を待ちに入るまで待つ。
  private func awaitGate(_ kind: String, _ k: Int) -> Bool {
    let waiting = dir.appendingPathComponent("\(kind).waiting.\(k)").path
    return waitUntil(10) { FileManager.default.fileExists(atPath: waiting) }
  }

  /// 書き込みは読みより長く待つ。上限を越えた書き込みは時間切れの失敗。上限の長さは、本番の定数を書き写さず、眠った待ち手の期限から
  /// 読む（眠ってから時刻は進めていないので、期限 − いま が上限）。
  func testWritesWaitLongerThanReads() throws {
    let clock = ManualClock()
    let cli = GitHubCLI(clock: clock.waits)
    try serve("first.gate", "")
    var read: Result<GitHubPullRequestReview, GitHubFailure>?
    cli.pullRequestReview(id) { read = $0 }
    XCTAssertTrue(awaitGate("first", 1), "前提: 読みが gh の中で止まっている")
    let reading = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil })?.deadline, "読みは上限の期限で眠る")
    let readLimit = reading - clock.now
    clock.advance(to: reading)
    pumpMain(until: { read != nil }, "読みが返る")
    XCTAssertEqual(read, .failure(.timedOut), "読みは読みの上限で打ち切る")

    try serve("resolve.gate", "")
    var written: GitHubReviewWriteResult?
    func resolve(pendingReview: String?) {
      written = nil
      cli.writeReview(
        .setResolved(thread: "T1", true), pullRequest: "PR_1", pendingReview: pendingReview,
        reviewedCommit: "seen"
      ) { written = $0 }
    }
    resolve(pendingReview: nil)
    XCTAssertTrue(awaitGate("resolve", 1), "前提: 書き込みが gh の中で止まっている")
    let writing = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil }), "書き込みは上限の期限で眠る")
    clock.advance(by: readLimit)
    XCTAssertTrue(clock.isAsleep(writing), "読みの上限まで進めても、書き込みの待ち手は眠ったまま")
    try serve("resolve.open.1", "")
    pumpMain(until: { written != nil }, "書き込みが返る")
    XCTAssertEqual(written?.failure, nil)

    resolve(pendingReview: "R1")
    XCTAssertTrue(awaitGate("resolve", 2), "前提: 書き込みが gh の中で止まっている")
    let writeDeadline = try XCTUnwrap(
      clock.awaitSleeper(where: { $0.deadline != nil })?.deadline, "書き込みは上限の期限で眠る")
    clock.advance(to: writeDeadline)
    pumpMain(until: { written != nil }, "書き込みが返る")
    XCTAssertEqual(written, GitHubReviewWriteResult(pendingReview: "R1", failure: .timedOut))
  }
}
