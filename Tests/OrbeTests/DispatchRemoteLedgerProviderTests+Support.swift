import XCTest

@testable import Orbe

/// 偽の `gh` と一時リポジトリの足場（`DispatchRemoteLedgerProviderTests` とその分冊が使う）。
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

  func section(_ model: DispatchPaletteModel, _ title: String) -> DispatchSection? {
    model.sections.first { $0.title == title }
  }

  func item(_ model: DispatchPaletteModel, _ name: String) -> DispatchItem? {
    section(model, "Worktrees")?.items.first { $0.name == name }
  }

  func pullRequestRow(_ model: DispatchPaletteModel, _ number: Int) -> DispatchItem? {
    section(model, "Pull requests")?.items.first { $0.idText == "#\(number)" }
  }

  /// 台帳が確定し、origin を確かめられない。
  func originUnverified(_ provider: DispatchDataProvider) -> Bool {
    guard case .settled(let resolved) = provider.remoteLedger else { return false }
    return resolved.defaultRemoteUnverified
  }

  /// 偽 `gh` を PATH に置く。認証確認は通り、正式名は `resolve/<owner>__<name>` の中身を返し（無ければ
  /// 答えずに落ちる）、open PR 一覧は `prs.json`、ブランチの PR は `branch/<name>` を返す。`<種別>.gate`
  /// がある間はその問い合わせが着地しない。正式名とブランチの PR の問い合わせは `calls.log` に残す。
  func stageGh() throws {
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

  /// 実 gh と同じく、存在しない（見えない）リポジトリは部分エラーの JSON を出して非 0 で終わる。
  func answerNotFound(_ name: String) throws {
    try write(
      #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"x"}]}"#,
      to: resolveFile(name))
    try write("1", to: resolveFile(name) + ".exit")
  }

  func resolveFile(_ name: String) -> String {
    ghDir.appendingPathComponent("resolve/\(name.replacingOccurrences(of: "/", with: "__"))").path
  }

  /// open PR 一覧を、この 1 件だけにする。
  func servePullRequest(_ number: Int, head: String, from repository: String) throws {
    try servePullRequests([pullRequestNode(number, head: head, from: repository)])
  }

  /// open PR 一覧を、この並び（`pullRequestNode` の出力）にする。
  func servePullRequests(_ nodes: [String]) throws {
    try write(
      #"{"nodes":[\#(nodes.joined(separator: ","))],"#
        + #""pageInfo":{"hasNextPage":false,"endCursor":null}}"#,
      to: ghDir.appendingPathComponent("prs.json").path)
  }

  /// open PR 一覧の 1 件（GraphQL の 1 node）。
  func pullRequestNode(_ number: Int, head: String, from repository: String) -> String {
    let parts = repository.split(separator: "/").map(String.init)
    return #"{"number":\#(number),"title":"pr \#(number)","headRefName":"\#(head)","#
      + #""headRepositoryOwner":{"login":"\#(parts[0])"},"headRepository":{"name":"\#(parts[1])"},"#
      + #""reviewDecision":null}"#
  }

  /// ブランチの PR 1 件（`gh pr list --json` の 1 要素）。
  func branchPR(
    _ number: Int, head: String, state: String, base: String = "main", from repository: String
  ) -> String {
    let parts = repository.split(separator: "/").map(String.init)
    return #"{"number":\#(number),"headRefName":"\#(head)","state":"\#(state)","#
      + #""baseRefName":"\#(base)","headRepositoryOwner":{"login":"\#(parts[0])"},"#
      + #""headRepository":{"name":"\#(parts[1])"}}"#
  }

  func serveBranchPullRequests(_ head: String, _ json: String) throws {
    try write(
      json,
      to: ghDir.appendingPathComponent("branch/\(head.replacingOccurrences(of: "/", with: "_"))")
        .path)
  }

  func gate(_ kind: String) throws {
    try write("", to: ghDir.appendingPathComponent("\(kind).gate").path)
  }

  func ungate(_ kind: String) throws {
    try FileManager.default.removeItem(at: ghDir.appendingPathComponent("\(kind).gate"))
  }

  /// 偽 `gh` が受けた問い合わせ（`R` = 正式名、`H` = ブランチの PR）の対象を順に返す。
  func calls(_ kind: String) -> [String] {
    let text =
      (try? String(contentsOf: ghDir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").filter { $0.hasPrefix("\(kind) ") }.map {
      String($0.dropFirst(kind.count + 1))
    }
  }

  func write(_ text: String, to path: String) throws {
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
