import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR の中身の読み取り（`GitHubCLI.pullRequestContent`）と確認済みの書き込み（`GitHubCLI.setViewed`）。PATH に偽の `gh` を
/// 置いて本物の子プロセスで測る。
///
/// 壊れると何が起きるか: コミットや変更ファイルが 100 件で切れ、欠けた一覧が全件として返る。読んでいる間に push が
/// あると、古い一覧と新しい一覧が混ざった中身が出る。途中のページの失敗で半分の一覧が出る。確認済みの書き込みが一部だけ
/// 通ったとき、どのパスが通らなかったかを呼び出し側が知れず、元に戻せない。
final class GitHubCLIPullRequestTests: OrbeTestCase {
  private var dir: URL!
  private let id = GitHubItemID(repo: "o/2048", number: 7)!

  /// 偽 `gh`。問い合わせを種類（`first`・`commits-<カーソル>`・`files-<カーソル>`・`viewed`）に分けて `calls.log` に残し、
  /// 中身は種類ごとのファイル（n 回目の呼び出しは `<種類>.<n>` があればそれ）から返す。`<種類>.exit` があればその終了コード
  /// で終わり、`<種類>.stderr` を標準エラーへ出す。`viewed` はパスごとの別名に答え、`reject` に書かれたパスだけ失敗にする。
  override func setUpWithError() throws {
    dir = TestScratch.caseDir.appendingPathComponent("orbe-gh-pr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      D="\(dir.path)"
      query=""; after=""; paths=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -f|-F)
            case "$2" in
              query=*) query="${2#query=}" ;;
              after=*) after="${2#after=}" ;;
              p[0-9]*=*) paths="$paths${2#*=}
      " ;;
            esac
            shift ;;
        esac
        shift
      done
      case "$query" in
        mutation*) kind=viewed ;;
        *'files(first:100,after'*) kind="files-$after" ;;
        *'commits(first:100,after'*) kind="commits-$after" ;;
        *) kind=first ;;
      esac
      echo "$kind $query" >> "$D/calls.log"
      n=$(( $(cat "$D/$kind.count" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$D/$kind.count"
      if [ "$kind" = viewed ]; then
        printf '{"data":{'
        i=0; failed=0
        printf '%s' "$paths" | while IFS= read -r p; do
          [ "$i" -gt 0 ] && printf ','
          if grep -qxF "$p" "$D/reject" 2>/dev/null; then printf '"f%d":null' "$i"
          else printf '"f%d":{"clientMutationId":null}' "$i"; fi
          i=$((i + 1))
        done
        printf '}}'
        printf '%s' "$paths" | grep -qxF -f "$D/reject" 2>/dev/null || exit 0
        echo "gh: Path is not part of the pull request" >&2
        exit 1
      fi
      f="$D/$kind"; [ -e "$f.$n" ] && f="$f.$n"
      [ -e "$f" ] && cat "$f"
      [ -e "$f.stderr" ] && cat "$f.stderr" >&2
      [ -e "$f.exit" ] && exit "$(cat "$f.exit")"
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

  private func calls(_ kind: String) -> Int {
    let text = (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8))
    return text?.split(separator: "\n").filter { $0.hasPrefix(kind + " ") }.count ?? 0
  }

  private func page(_ nodes: [String], next cursor: String?) -> String {
    #"{"nodes":[\#(nodes.joined(separator: ","))],"pageInfo":{"hasNextPage":\#(cursor != nil),"#
      + #""endCursor":"\#(cursor ?? "end")"}}"#
  }

  private func commit(_ oid: String) -> String {
    #"{"commit":{"oid":"\#(oid)","messageHeadline":"m \#(oid)"}}"#
  }

  private func file(_ path: String, _ change: String = "MODIFIED", _ viewed: String = "UNVIEWED")
    -> String
  {
    #"{"path":"\#(path)","changeType":"\#(change)","viewerViewedState":"\#(viewed)"}"#
  }

  /// 1 ページ目。コミットの列には総数（`commitCount`）を足す。
  private func firstPage(
    head: String = "h1", commits: String, files: String, author: String = #"{"login":"me"}"#,
    commitCount: Int = 1
  ) -> String {
    let counted = #"{"totalCount":\#(commitCount),"# + commits.dropFirst()
    return #"{"data":{"repository":{"pullRequest":{"id":"PR_1","number":7,"title":"t","#
      + #""url":"https://github.com/o/2048/pull/7","isDraft":true,"state":"OPEN","body":"b","#
      + #""author":\#(author),"baseRefName":"main","headRefName":"feat","baseRefOid":"b1","#
      + #""headRefOid":"\#(head)","commits":\#(counted),"files":\#(files)}}}}"#
  }

  private func nextPage(head: String = "h1", _ connection: String, _ page: String) -> String {
    #"{"data":{"repository":{"pullRequest":{"baseRefOid":"b1","headRefOid":"\#(head)","#
      + #""\#(connection)":\#(page)}}}}"#
  }

  private func read() -> Result<GitHubPullRequestContent, GitHubFailure>? {
    var result: Result<GitHubPullRequestContent, GitHubFailure>?
    let done = expectation(description: "pullRequestContent")
    GitHubCLI().pullRequestContent(id) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return result
  }

  /// 続きのページを最後まで読むと、PR の値と全件のコミット・変更ファイルが揃う。確認済みは「確認済み」だけが真で、後の push で
  /// 外れたもの（DISMISSED）は偽。
  func testEveryPageIsReadIntoOneContent() throws {
    try serve(
      "first",
      firstPage(
        commits: page([commit("c1")], next: "C1"),
        files: page([file("a", "ADDED", "VIEWED"), file("b", "RENAMED", "DISMISSED")], next: "F1"),
        author: "null", commitCount: 300))
    try serve("commits-C1", nextPage("commits", page([commit("c2")], next: "C2")))
    try serve("commits-C2", nextPage("commits", page([commit("c3")], next: nil)))
    try serve("files-F1", nextPage("files", page([file("c", "CHANGED")], next: nil)))

    let content = try XCTUnwrap(read()).get()

    XCTAssertEqual(content.nodeID, "PR_1")
    XCTAssertEqual(content.state, .open)
    XCTAssertTrue(content.isDraft)
    XCTAssertNil(content.author, "消えたアカウント")
    XCTAssertEqual(content.baseCommit, "b1")
    XCTAssertEqual(content.headCommit, "h1")
    XCTAssertEqual(content.commits.map(\.oid), ["c1", "c2", "c3"])
    XCTAssertEqual(content.commitCount, 300, "GitHub が返さない古い側のコミットも総数に入る")
    XCTAssertEqual(content.commits.first?.headline, "m c1")
    XCTAssertEqual(
      content.files,
      [
        .init(path: "a", change: .added, isViewed: true),
        .init(path: "b", change: .renamed, isViewed: false),
        .init(path: "c", change: .typeChanged, isViewed: false),
      ])
  }

  /// ページの間に push があれば（続きのページが答える PR の先頭のコミット `headRefOid` が 1 ページ目と違えば）、最初から読み直して新しい時点の中身だけを返す。
  func testAPushBetweenPagesRereadsFromTheStart() throws {
    try serve(
      "first.1",
      firstPage(head: "h1", commits: page([commit("old")], next: "C1"), files: page([], next: nil)))
    try serve("commits-C1.1", nextPage(head: "h2", "commits", page([commit("new2")], next: nil)))
    try serve(
      "first.2",
      firstPage(head: "h2", commits: page([commit("new1")], next: "C1"), files: page([], next: nil))
    )
    try serve("commits-C1.2", nextPage(head: "h2", "commits", page([commit("new2")], next: nil)))

    let content = try XCTUnwrap(read()).get()

    XCTAssertEqual(content.headCommit, "h2")
    XCTAssertEqual(content.commits.map(\.oid), ["new1", "new2"])
    XCTAssertEqual(calls("first"), 2)
  }

  /// 読み直しても動き続けるなら、混ざった中身を返さずに失敗する（読み直しは 1 回まで）。
  func testAPullRequestThatKeepsMovingFails() throws {
    try serve(
      "first",
      firstPage(head: "h1", commits: page([commit("c1")], next: "C1"), files: page([], next: nil)))
    try serve("commits-C1", nextPage(head: "h2", "commits", page([commit("c2")], next: nil)))

    XCTAssertEqual(read(), .failure(.reason("")))
    XCTAssertEqual(calls("first"), 2)
  }

  /// 途中のページの失敗は全体の失敗（半分の一覧を返さない）で、失敗の種類つき。
  func testAFailedPageFailsTheWholeRead() throws {
    try serve(
      "first",
      firstPage(commits: page([commit("c1")], next: nil), files: page([file("a")], next: "F1")))
    try serve("files-F1.stderr", "error connecting to api.github.com\n")
    try serve("files-F1.exit", "1")

    XCTAssertEqual(read(), .failure(.unreachable))
  }

  private func setViewed(_ viewed: Bool, _ paths: Set<String>) -> GitHubViewedWrite? {
    var result: GitHubViewedWrite?
    let done = expectation(description: "setViewed")
    GitHubCLI().setViewed(viewed, paths: paths, pullRequest: "PR_1") {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)
    return result
  }

  /// 1 回の問い合わせで一部だけ通ったら、通ったパスと失敗の種類を返す。確認済みを外すときは、外す書き込み（`unmarkFileAsViewed`）を送る。
  func testAPartlyFailedWriteTellsWhichPathsPassed() throws {
    try serve("reject", "b\n")

    XCTAssertEqual(
      setViewed(false, ["a", "b"]),
      GitHubViewedWrite(
        written: ["a"], failure: .reason("gh: Path is not part of the pull request")))
    let log = try String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)
    XCTAssertTrue(log.contains("unmarkFileAsViewed"))
    XCTAssertFalse(log.contains(" markFileAsViewed") || log.contains(":markFileAsViewed"))
  }

  /// 件数が多ければ 50 件ごとに分けて順に送り、失敗した回より後の回は送らない。
  func testManyPathsAreSplitAndStopAtTheFirstFailedQuery() throws {
    let paths = Set((0..<120).map { "p\($0)" })
    XCTAssertEqual(setViewed(true, paths), GitHubViewedWrite(written: paths, failure: nil))
    XCTAssertEqual(calls("viewed"), 3)

    try serve("reject", "p60\n")
    let partial = setViewed(true, paths)
    XCTAssertEqual(partial?.written, Set(paths.sorted().prefix(100)).subtracting(["p60"]))
    XCTAssertNotNil(partial?.failure)
    XCTAssertEqual(calls("viewed"), 5, "失敗した 2 回目の後の 3 回目は送らない")
  }
}
