import OrbeTestSupport
import XCTest

@testable import Orbe

/// clean が読むブランチの PR の問い合わせと、gh の認証確認。
///
/// 壊れると何が起きるか: 窓落ちした PR のぶんだけ「マージ済みなのに merged チップが出ない」「レビュー中なのに
/// 安全確認を素通りする」が起きる。head のリポジトリを読む欄を頼み忘れると、自分の PR を「確かめて 0 件」と
/// 読む。疎通不能を未認証と読むと、PR を確かめないまま 0 件と読まれ、worktree の掃除が素通りする。
@MainActor
final class GitHubCacheTests: OrbeTestCase {
  // MARK: - ブランチの PR の取得

  /// ブランチの PR は一覧の窓ではなく **worktree にあるブランチの名指し**で、open / closed の両方を、gh が
  /// 1 往復で取れる上限（100 件）まで引く。
  func testBranchPRFetchNamesTheBranchAcrossAllStates() {
    let arguments = GitHubCLI.branchPRArguments(head: "refactor/phase2-2b")
    let pairs = zip(arguments, arguments.dropFirst())

    XCTAssertTrue(pairs.contains { $0 == ("--head", "refactor/phase2-2b") }, "ブランチを名指しする")
    XCTAssertTrue(pairs.contains { $0 == ("--state", "all") }, "閉じた PR も引く")
    XCTAssertTrue(pairs.contains { $0 == ("--limit", "100") }, "gh の上限まで引く")
  }

  /// gh に頼む欄（`--json`）だけを持つ出力から、clean と PR の自動の結び付けが読む値（head と URL）が揃う。
  func testBranchPRFetchRequestsEveryFieldThePullRequestIsReadFrom() throws {
    let arguments = GitHubCLI.branchPRArguments(head: "feat")
    let fields = try XCTUnwrap(arguments.firstIndex(of: "--json")) + 1
    let requested = Set(arguments[fields].split(separator: ",").map(String.init))
    let output: [String: Any] = [
      "number": 7, "headRefName": "feat", "state": "OPEN", "baseRefName": "main",
      "headRepository": ["name": "r"], "headRepositoryOwner": ["login": "o"],
      "url": "https://github.com/o/r/pull/7",
    ]

    let pr = try JSONDecoder().decode(
      GitHubBranchPR.self,
      from: JSONSerialization.data(withJSONObject: output.filter { requested.contains($0.key) }))

    XCTAssertEqual(
      pr.head, GitHubBranchRef(repo: GitHubRepoName(nameWithOwner: "o/r"), branch: "feat"))
    XCTAssertEqual(pr.url, "https://github.com/o/r/pull/7")
  }

  /// 対象は worktree にあるブランチだけ（main worktree は掃除の対象外・detached は PR の head に
  /// なり得ない）。ここが広がると worktree 本数で抑えているプロセス数の前提が崩れる。
  func testWorktreeBranchesTargetNonMainWorktreeBranchesOnly() {
    let heads = WorktreePaletteDataProvider.worktreeBranches(of: [
      GitWorktree(path: "/repo", branch: "main", head: "a", isMain: true),
      GitWorktree(path: "/wt/x", branch: "refactor/phase2-2b", head: "b", isMain: false),
      GitWorktree(path: "/wt/detached", branch: nil, head: "c", isMain: false),
    ])
    XCTAssertEqual(heads, ["refactor/phase2-2b"])
  }

  // MARK: - probe

  /// 認証はネットに触らずに確かめる。GitHub に届かない（ネットを要する gh の呼び出しが落ちる）ときも、
  /// github.com の認証情報があれば使える。
  func testAuthProbeIsReadyOfflineWithGitHubDotComCredentials() throws {
    let dir = TestScratch.caseDir
      .appendingPathComponent("orbe-gh-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // オフラインの gh: github.com の認証情報を読むだけの呼び出しは通り、それ以外は落ちる。
    let script = """
      #!/bin/sh
      [ "$1 $2" = "auth token" ] || exit 1
      case " $* " in *" --hostname github.com "*) exit 0 ;; esac
      exit 1
      """
    let gh = dir.appendingPathComponent("gh").path
    try script.write(toFile: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh)
    // 戻さない——`OrbeTestCase` が毎テスト `ShellPATH.shared` を張り直す。
    let path = dir.path
    ShellPATH.shared = ShellPATH(probe: { path })

    var availability: GitHubAvailability?
    let done = expectation(description: "probe")
    GitHubCLI().probe(cwd: dir.path, isGitHub: true) {
      availability = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 30)

    XCTAssertEqual(availability, .ready)
  }
}
