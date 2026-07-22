import XCTest

@testable import Orbe

/// gh 着地の規則（`DispatchDataProvider.applyFetched*`）と、その保存先（`DispatchGitHubCache`）の検証。
/// gh は叩かず、取得結果に相当する値を直接着地させて sections の再描画有無で判定する。
@MainActor
final class DispatchGitHubCacheTests: XCTestCase {

  private func makeProvider(_ model: DispatchPaletteModel) -> DispatchDataProvider {
    DispatchDataProvider(
      cwd: "/tmp", model: model, localization: LocalizationStore(language: .ja))
  }

  private func issue(_ number: Int) -> GitHubIssue {
    GitHubIssue(number: number, title: "issue \(number)")
  }

  private func pullRequest(_ number: Int) -> GitHubPullRequest {
    GitHubPullRequest(
      number: number, title: "pr \(number)", headRefName: "feat/\(number)", reviewDecision: nil,
      isCrossRepository: false)
  }

  private func issueTitles(_ model: DispatchPaletteModel) -> [String] {
    model.sections.first { $0.title == "Issues" }?.items.map(\.name) ?? []
  }

  // MARK: - 着地の規則

  /// 条件4: 取得失敗（nil）は前回結果を差し替えず、再描画も起こさない。
  func testFetchFailureKeepsPreviousResultWithoutRebuild() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)])
    XCTAssertEqual(issueTitles(model), ["issue 1"])

    model.sections = []  // 以降の rebuild を検出するための目印
    provider.applyFetchedIssues(nil)
    XCTAssertTrue(model.sections.isEmpty, "失敗の着地は rebuild を打たない")

    // PR 側はまだ loading なので rebuild が走る。そこに issue 行が残っていれば据え置きの証明。
    provider.applyFetchedPullRequests(nil)
    XCTAssertEqual(issueTitles(model), ["issue 1"], "失敗しても前回の issue 行は消えない")
  }

  /// キャッシュ未ヒットで失敗したときは、ローディング行を畳むため 1 回だけ rebuild する。
  func testFetchFailureWhileLoadingRebuildsOnce() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues(nil)
    XCTAssertTrue(model.hasLoadedOnce, "ローディング行を畳むため rebuild は打つ")
    XCTAssertTrue(issueTitles(model).isEmpty, "ローディング行も残らない")
  }

  /// 条件2: 前回と等値なら再描画しない（ちらつかない）。
  func testEqualResultDoesNotRebuild() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)])
    model.sections = []
    provider.applyFetchedIssues([issue(1)])
    XCTAssertTrue(model.sections.isEmpty, "等値の着地は rebuild を打たない")
  }

  /// 成功した 0 件（`[]`）は失敗（`nil`）と違い、前回結果を消す（閉じた issue が残らない）。
  func testEmptySuccessClearsPreviousResult() {
    let model = DispatchPaletteModel()
    let provider = makeProvider(model)
    provider.applyFetchedIssues([issue(1)])
    provider.applyFetchedIssues([])
    XCTAssertTrue(issueTitles(model).isEmpty, "0 件の成功は行を消す")
  }

  // MARK: - 保存先

  func testCacheSeparatesEntriesByCommonDir() {
    let cache = DispatchGitHubCache.shared
    cache.setIssues([issue(1)], for: "/a/.git")
    cache.setIssues([issue(2)], for: "/b/.git")
    XCTAssertEqual(cache.entry(for: "/a/.git")?.issues, [issue(1)])
    XCTAssertEqual(cache.entry(for: "/b/.git")?.issues, [issue(2)])
    XCTAssertNil(cache.entry(for: "/c/.git"), "未取得のリポジトリはエントリを持たない")
  }

  /// issues と PR は独立に到着し独立に失敗する。片方の保存が他方を巻き込まない。
  func testCacheKeepsIssuesAndPullRequestsIndependent() {
    let cache = DispatchGitHubCache.shared
    let key = "/independent/.git"
    cache.setIssues([issue(1)], for: key)
    XCTAssertNil(cache.entry(for: key)?.pullRequests, "PR は未取得のまま（0 件ではない）")
    cache.setPullRequests([pullRequest(9)], for: key)
    XCTAssertEqual(cache.entry(for: key)?.issues, [issue(1)], "PR の保存が issues を壊さない")
  }

  // MARK: - probe

  /// 認証判定はネットに触らない `gh auth token` で行う。`gh auth status` はトークン検証で API を
  /// 叩き、疎通不能を未認証と誤判定してキャッシュ済みの行を誘導情報行に置き換えてしまう。
  func testAuthProbeDoesNotUseNetworkVerifyingCommand() {
    XCTAssertEqual(
      GitHubCLI.authProbeArguments, ["auth", "token", "--hostname", "github.com"])
  }
}
