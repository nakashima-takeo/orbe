import XCTest

@testable import Orbe

/// remote の台帳を provider の中で育てる経路（正式名の問い合わせ・キャッシュ・着地後の描き直し）と、
/// clean の PR の事実をその台帳で絞る経路。実 git の一時リポジトリと偽の `gh` で、本物の着地経路を通す。
///
/// 壊れると、次のどれかが黙って起きる。
/// - 問い合わせが揃う前に撃たれて失敗し、PR がローディングのまま、チップも出ないまま固まる。
/// - 同じ名前を何度も問い合わせる。
/// - 一時的な失敗がキャッシュに焼かれ、開き直しても直らない。
/// - clean が他人の fork の PR で行を塞ぐ、または自分の PR（追跡先の名前が違う行・fork の運用）を
///   見落として、レビュー中の worktree を安全群に入れる。
@MainActor
final class DispatchRemoteLedgerProviderTests: OrbeTestCase {
  var dir: URL!
  var root: String!
  private var ghDir: URL!

  let mine = GitHubRepoName(nameWithOwner: "me/r")

  override func setUpWithError() throws {
    let created = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
    dir = URL(fileURLWithPath: String(cString: realpath(created.path, nil)))
    root = dir.appendingPathComponent("repo").path
    XCTAssertTrue(run(["init", "-q", "-b", "main", root], in: dir.path).isSuccess)
    XCTAssertTrue(git(["config", "user.email", "t@example.com"]).isSuccess)
    XCTAssertTrue(git(["config", "user.name", "t"]).isSuccess)
    // origin を github.com の URL にしても、提示時の fetch がネットへ出ないようにする（即失敗する）。
    XCTAssertTrue(git(["config", "protocol.https.allow", "never"]).isSuccess)
    try "x".write(
      toFile: (root as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    XCTAssertTrue(git(["add", "-A"]).isSuccess)
    XCTAssertTrue(git(["commit", "-qm", "init"]).isSuccess)
    try stageGh()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - 正式名の問い合わせ

  /// 正式名が分かるまでは PR 行の行き先もチップも決まらないのでローディング行だけ。答えが着地したら
  /// PR 行とチップが出る。origin の URL が改名前の名前でも、正式名で PR の head と同じと分かる。
  func testPullRequestsWaitForTheCanonicalNameThenLinkRows() throws {
    addRemote("origin", "me/old-name")
    try answer("me/old-name", found: "me/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    let worktree = try addWorktree("wt-feat", branch: "feat")
    try gate("resolve")
    // ブランチの PR の着地による描き直しに頼らず、答えの着地そのもので描き直すことを見る。
    try gate("branch")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        self.calls("R").contains("me/old-name") && provider.pullRequests.count == 1
          && !provider.pullRequestsFetching && !provider.issuesFetching
          && model.classification != nil && provider.probingPaths.isEmpty
      }), "前提: 一覧と分類は着地し、正式名の問い合わせだけが着地していない")
    XCTAssertEqual(
      section(model, "Pull requests")?.items.map(\.isLoadingRow), [true], "PR 行を出さずローディング行だけ")
    XCTAssertNil(item(model, "wt-feat")?.linkedPRNumber, "チップを出さない")
    XCTAssertEqual(provider.branchPRStates["feat"], .fetching, "clean の PR の事実はまだ分からない")

    try ungate("resolve")
    // ブランチの PR の問い合わせが打ち切り（15 秒）で着地して描き直すより前に出ること。
    XCTAssertTrue(pump({ self.pullRequestRow(model, 1) != nil }, timeout: 5), "答えの着地で PR 行が出る")
    XCTAssertEqual(item(model, "wt-feat")?.linkedPRNumber, 1)
    XCTAssertEqual(
      pullRequestRow(model, 1)?.action, .pullRequest(number: 1, open: .worktree(path: worktree)))
  }

  /// 撃つのは remote の一覧と認証確認の両方が揃ってから。GitHub の remote ごとに 1 回だけで、着地前に
  /// git の一覧が引き直されても二重に撃たない。GitHub でない remote は問い合わせない。
  func testLookupFiresOnceEachGitHubRemoteAfterBothLanesLand() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "base/r")
    XCTAssertTrue(git(["remote", "add", "mirror", "/srv/mirror.git"]).isSuccess)
    try answer("me/r", found: "me/r")
    try answer("base/r", found: "base/r")
    try gate("auth")
    try gate("resolve")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ provider.remoteListing != nil && model.classification != nil }))
    XCTAssertFalse(pump({ !self.calls("R").isEmpty }, timeout: 1), "認証確認が着地するまで撃たない")

    try ungate("auth")
    XCTAssertTrue(pump({ self.calls("R").count == 2 }), "認証確認の着地で撃つ")
    var relanded = false
    provider.loadGit(try XCTUnwrap(provider.repo), classifying: false) { relanded = true }
    XCTAssertTrue(pump({ relanded }), "前提: 問い合わせ中に git の一覧が引き直された")

    try ungate("resolve")
    XCTAssertTrue(pump({ provider.remoteLedger != .pending }))
    XCTAssertEqual(calls("R").sorted(), ["base/r", "me/r"])
  }

  /// 問い合わせが失敗したら台帳は失敗のまま（PR はローディング・チップ無し・clean は取得失敗）で、
  /// その回は問い合わせ直さない。失敗は覚えないので、開き直せば問い合わせ直して直る。
  func testFailedLookupIsNotRememberedAndIsAskedAgainOnReopen() throws {
    addRemote("origin", "me/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    _ = try addWorktree("wt-feat", branch: "feat")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ provider.remoteLedger == .failed && provider.pullRequests.count == 1 }))
    XCTAssertEqual(section(model, "Pull requests")?.items.map(\.isLoadingRow), [true])
    XCTAssertNil(item(model, "wt-feat")?.linkedPRNumber)
    XCTAssertEqual(provider.branchPRStates["feat"], .failed, "安全群に入らない側に倒れる")
    var relanded = false
    provider.loadGit(try XCTUnwrap(provider.repo), classifying: false) { relanded = true }
    XCTAssertTrue(pump({ relanded }))
    XCTAssertEqual(calls("R"), ["me/r"], "同じ回では問い合わせ直さない")

    try answer("me/r", found: "me/r")
    let (reopened, again) = makeProvider()
    again.load()
    XCTAssertTrue(pump({ self.pullRequestRow(reopened, 1) != nil }), "開き直すと直る")
    XCTAssertEqual(calls("R"), ["me/r", "me/r"], "失敗は覚えていないので問い合わせ直す")
  }

  /// 答え（正式名・存在しない）はプロセス内に残るので、2 回目に開いたときは gh を待たずに最初の描画から
  /// PR 行とチップが出て、問い合わせ直さない。
  func testSecondOpenShowsPullRequestsFromTheFirstFrameWithoutAskingAgain() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "base/r")
    try answer("me/r", found: "me/r")
    try answerNotFound("base/r")
    try servePullRequest(1, head: "feat", from: "me/r")
    _ = try addWorktree("wt-feat", branch: "feat")
    let (first, provider) = makeProvider()
    provider.load()
    XCTAssertTrue(pump({ self.pullRequestRow(first, 1) != nil }), "前提: 1 回目で答えが揃う")

    try gate("auth")
    let (model, again) = makeProvider()
    again.load()
    XCTAssertTrue(pump({ model.hasLoadedOnce }))
    XCTAssertNotNil(pullRequestRow(model, 1), "認証確認より前の描画から PR 行が出る")
    XCTAssertEqual(item(model, "wt-feat")?.linkedPRNumber, 1)

    try ungate("auth")
    XCTAssertTrue(pump({ again.githubReady && !again.pullRequestsFetching }))
    XCTAssertEqual(calls("R").sorted(), ["base/r", "me/r"], "存在しない答えも含めて問い合わせ直さない")
  }

  // MARK: - clean の PR の事実

  /// clean の PR は worktree の追跡先のブランチ名で問い合わせ、head がその worktree の ref と等しいもの
  /// だけを事実にする。origin が自分の fork の運用でも自分の PR が残り、他人の fork の同名ブランチの
  /// レビュー中 PR は行を塞がない。
  func testCleanPullRequestFactsFollowTheTrackedBranchAndDropOtherForks() throws {
    addRemote("origin", "me/r")
    addRemote("upstream", "base/r")
    try answer("me/r", found: "me/r")
    try answer("base/r", found: "base/r")
    XCTAssertTrue(git(["update-ref", "refs/remotes/origin/feature-x", "HEAD"]).isSuccess)
    let worktree = try addWorktree("wt-feat", branch: "feat")
    XCTAssertTrue(
      run(["branch", "-q", "--set-upstream-to=origin/feature-x"], in: worktree).isSuccess)
    try serveBranchPullRequests(
      "feature-x",
      #"[{"number":6,"headRefName":"feature-x","state":"OPEN","baseRefName":"main","#
        + #""headRepository":{"nameWithOwner":"x/r"}},"#
        + #"{"number":5,"headRefName":"feature-x","state":"MERGED","baseRefName":"develop","#
        + #""headRepository":{"nameWithOwner":"me/r"}}]"#)
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(
      pump({
        guard case .loaded = provider.branchPRStates["feat"] else { return false }
        return model.classification != nil
      }))

    XCTAssertEqual(calls("H"), ["feature-x"], "ローカル名 feat ではなく追跡先の feature-x で問う")
    XCTAssertEqual(
      provider.branchPRStates["feat"],
      .loaded([
        GitHubBranchPR(
          number: 5, headRefName: "feature-x", state: "MERGED", baseRefName: "develop",
          headRepository: mine)
      ]))
    let row = try XCTUnwrap(model.classification?.first { $0.branch == "feat" })
    XCTAssertTrue(row.vocabulary.contains(.mergedPR(5, base: "develop")), "自分の merged PR は事実になる")
    XCTAssertFalse(row.vocabulary.contains(.openPR(6)), "他人の fork のレビュー中 PR は事実にしない")
  }

  /// GitHub でない remote を追跡する worktree は、PR の事実を「確かめて 0 件」として問い合わせない。
  func testWorktreeTrackingANonGitHubRemoteHasNoPullRequestsToAsk() throws {
    addRemote("origin", "me/r")
    try answer("me/r", found: "me/r")
    XCTAssertTrue(git(["remote", "add", "mirror", "/srv/mirror.git"]).isSuccess)
    XCTAssertTrue(git(["update-ref", "refs/remotes/mirror/side", "HEAD"]).isSuccess)
    let worktree = try addWorktree("wt-side", branch: "side")
    XCTAssertTrue(run(["branch", "-q", "--set-upstream-to=mirror/side"], in: worktree).isSuccess)
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ provider.remoteLedger != .pending && model.classification != nil }))
    XCTAssertEqual(provider.branchPRStates["side"], .loaded([]))
    XCTAssertEqual(calls("H"), [])
  }

  /// origin が GitHub でないリポジトリは gh を使わないので、GitHub の remote が別にあって台帳が確定
  /// しなくても、clean はそれを待たない（確認対象が無いので git の事実だけで判定する）。
  func testNonGitHubRepositoryDoesNotWaitForTheLedger() throws {
    XCTAssertTrue(git(["remote", "add", "origin", "/srv/origin.git"]).isSuccess)
    addRemote("upstream", "base/r")
    _ = try addWorktree("wt-feat", branch: "feat")
    let (model, provider) = makeProvider()

    provider.load()
    XCTAssertTrue(pump({ model.classification != nil && !provider.classificationPending }))
    XCTAssertEqual(provider.remoteLedger, .pending, "前提: GitHub の remote の正式名は問い合わせない")
    XCTAssertEqual(provider.branchPRStates["feat"], .loaded([]))
  }
}

// MARK: - ヘルパ

extension DispatchRemoteLedgerProviderTests {

  func makeProvider(cwd: String? = nil) -> (DispatchPaletteModel, DispatchDataProvider) {
    let model = DispatchPaletteModel()
    let provider = DispatchDataProvider(
      cwd: cwd ?? root, model: model, localization: LocalizationStore(language: .ja),
      worktreeTemplate: WorktreePathTemplate.defaultTemplate, gitHub: GitHubCLI())
    return (model, provider)
  }

  func addRemote(_ name: String, _ repository: String) {
    XCTAssertTrue(git(["remote", "add", name, "https://github.com/\(repository).git"]).isSuccess)
  }

  func addWorktree(_ name: String, branch: String) throws -> String {
    let path = dir.appendingPathComponent(name).path
    XCTAssertTrue(git(["worktree", "add", "-q", "-b", branch, path]).isSuccess)
    return path
  }

  private func section(_ model: DispatchPaletteModel, _ title: String) -> DispatchSection? {
    model.sections.first { $0.title == title }
  }

  func item(_ model: DispatchPaletteModel, _ name: String) -> DispatchItem? {
    section(model, "Worktrees")?.items.first { $0.name == name }
  }

  func pullRequestRow(_ model: DispatchPaletteModel, _ number: Int) -> DispatchItem? {
    section(model, "Pull requests")?.items.first { $0.idText == "#\(number)" }
  }

  /// 偽 `gh` を PATH に置く。認証確認は通り、正式名は `resolve/<owner>__<name>` の中身を返し（無ければ
  /// 答えずに落ちる）、open PR 一覧は `prs.json`、ブランチの PR は `branch/<name>` を返す。`<種別>.gate`
  /// がある間はその問い合わせが着地しない。正式名とブランチの PR の問い合わせは `calls.log` に残す。
  private func stageGh() throws {
    ghDir = dir.appendingPathComponent("gh")
    for sub in ["resolve", "branch"] {
      try FileManager.default.createDirectory(
        at: ghDir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try write(
      #"{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}"#,
      to: ghDir.appendingPathComponent("prs.json").path)
    let d = ghDir.path
    let script = """
      #!/bin/sh
      D="\(d)"
      wait_gate() { while [ -e "$D/$1.gate" ]; do sleep 0.05; done; }
      if [ "$1" = "auth" ]; then wait_gate auth; echo token; exit 0; fi
      if [ "$1" = "pr" ]; then
        head=""
        while [ $# -gt 0 ]; do [ "$1" = "--head" ] && head="$2"; shift; done
        echo "H $head" >> "$D/calls.log"
        wait_gate branch
        f="$D/branch/$(echo "$head" | tr / _)"
        if [ -e "$f" ]; then cat "$f"; else printf '[]'; fi
        exit 0
      fi
      query=""; o=""; n=""; jq=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -f|-F)
            case "$2" in query=*) query="${2#query=}" ;; o=*) o="${2#o=}" ;; n=*) n="${2#n=}" ;; esac
            shift ;;
          --jq) jq="$2"; shift ;;
        esac
        shift
      done
      case "$query" in
        *'repository(owner:$o,'*)
          echo "R $o/$n" >> "$D/calls.log"
          wait_gate resolve
          f="$D/resolve/${o}__${n}"
          [ -e "$f" ] || exit 1
          cat "$f"
          [ -e "$f.exit" ] && exit "$(cat "$f.exit")"
          exit 0 ;;
      esac
      case "$jq" in
        *pullRequests*) cat "$D/prs.json" ;;
        *) printf '{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}' ;;
      esac
      """
    let gh = ghDir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直す。
    let path = ghDir.path
    ShellPATH.shared = ShellPATH(probe: { "\(path):/usr/bin:/bin" })
  }

  func answer(_ name: String, found canonical: String) throws {
    try write(#"{"data":{"repository":{"nameWithOwner":"\#(canonical)"}}}"#, to: resolveFile(name))
  }

  /// 実 gh と同じく、存在しないリポジトリは部分エラーの JSON を出して非 0 で終わる。
  private func answerNotFound(_ name: String) throws {
    try write(
      #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"x"}]}"#,
      to: resolveFile(name))
    try write("1", to: resolveFile(name) + ".exit")
  }

  private func resolveFile(_ name: String) -> String {
    ghDir.appendingPathComponent("resolve/\(name.replacingOccurrences(of: "/", with: "__"))").path
  }

  /// open PR 一覧を、この 1 件だけにする。
  func servePullRequest(_ number: Int, head: String, from repository: String) throws {
    let node =
      #"{"number":\#(number),"title":"pr \#(number)","headRefName":"\#(head)","#
      + #""headRepository":{"nameWithOwner":"\#(repository)"},"reviewDecision":null}"#
    try write(
      #"{"nodes":[\#(node)],"pageInfo":{"hasNextPage":false,"endCursor":null}}"#,
      to: ghDir.appendingPathComponent("prs.json").path)
  }

  func serveBranchPullRequests(_ head: String, _ json: String) throws {
    try write(
      json,
      to: ghDir.appendingPathComponent("branch/\(head.replacingOccurrences(of: "/", with: "_"))")
        .path)
  }

  private func gate(_ kind: String) throws {
    try write("", to: ghDir.appendingPathComponent("\(kind).gate").path)
  }

  private func ungate(_ kind: String) throws {
    try FileManager.default.removeItem(at: ghDir.appendingPathComponent("\(kind).gate"))
  }

  /// 偽 `gh` が受けた問い合わせ（`R` = 正式名、`H` = ブランチの PR）の対象を順に返す。
  private func calls(_ kind: String) -> [String] {
    let text =
      (try? String(contentsOf: ghDir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").filter { $0.hasPrefix("\(kind) ") }.map {
      String($0.dropFirst(kind.count + 1))
    }
  }

  private func write(_ text: String, to path: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
  }

  @discardableResult
  func git(_ args: [String]) -> GitRunner.Output {
    run(args, in: root)
  }

  @discardableResult
  func run(_ args: [String], in cwd: String) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: cwd)
  }

  /// main queue を回しながら条件の成立を待つ（provider の completion は main で届く）。
  func pump(_ condition: () -> Bool, timeout: TimeInterval = 20) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
      usleep(5_000)
    }
    return condition()
  }
}
