import XCTest

@testable import Orbe

/// 結び付いた Issue・PR の表示規則（`GitHubItemText`）。一覧の行と右の欄の Issue・PR の欄は、どちらも
/// この規則を読むだけで出し方を決める。
///
/// 壊れると何が起きるか: GitHub の値が届くまで（再起動直後・オフライン・gh が無い）行から番号まで消え、
/// どのタスクがどの Issue かが分からなくなる。状態の強さを取り違えると、マージ済みの PR が「レビュー待ち」と
/// 出て、人が終わった作業に手を戻す。終わった PR に CI を出すと、もう直せない失敗が人を呼ぶ。保存した種別と
/// 実体の種別が食い違うまま値を出すと、Issue のタイトルが PR の札に載る。自分の PR に「レビュー」と出ると、
/// 人は自分を待つ。
final class GitHubItemTextTests: OrbeTestCase {
  private func link(_ kind: GitHubItemKind, _ number: Int, repo: String = "o/n") -> TaskLink {
    TaskLink(item: GitHubItemID(repo: repo, number: number)!, kind: kind)
  }

  private func issue(_ state: GitHubItemSummary.State = .open) -> GitHubItemSummary {
    GitHubItemSummary(title: "issue", state: state, pullRequest: nil)
  }

  private func pullRequest(
    _ state: GitHubItemSummary.State = .open, draft: Bool = false,
    review: GitHubItemSummary.ReviewDecision? = .reviewRequired,
    checks: GitHubItemSummary.Checks? = .success, author: String? = "nakatake"
  ) -> GitHubItemSummary {
    GitHubItemSummary(
      title: "pr", state: state,
      pullRequest: .init(isDraft: draft, review: review, checks: checks, author: author))
  }

  // MARK: - 主の印と番号・番号の表示

  func testMarkIsThePrimaryLinksKindAndNumberWithoutWaitingForGitHub() {
    XCTAssertEqual(
      GitHubItemText.mark([link(.pr, 213), link(.issue, 212)]), .init(kind: .pr, number: 213),
      "先頭が主")
    XCTAssertEqual(GitHubItemText.mark([link(.issue, 212)]), .init(kind: .issue, number: 212))
    XCTAssertNil(GitHubItemText.mark([]), "結び付きが無ければ出さない")
  }

  /// 主と同じリポジトリ（大小文字を問わない）なら `#番号`、違えば owner を除いた名前を添える。
  func testLabelNamesTheRepositoryOnlyWhenItDiffersFromThePrimary() {
    let primary = link(.issue, 212, repo: "nakatake/orbe").item

    XCTAssertEqual(
      GitHubItemText.label(link(.pr, 213, repo: "Nakatake/Orbe").item, primary: primary), "#213")
    XCTAssertEqual(
      GitHubItemText.label(link(.pr, 88, repo: "nakatake/api").item, primary: primary), "api#88")
  }

  /// 出す値は、保存した種別と GitHub 上の実体の種別が一致するときだけ。
  func testValueIsWithheldUntilItArrivesOrWhenTheStoredKindDiffersFromGitHub() {
    let pr = pullRequest()
    let storedAsIssue = link(.issue, 213)

    XCTAssertEqual(GitHubItemText.summary(link(.pr, 213), [storedAsIssue.item: .found(pr)]), pr)
    XCTAssertNil(
      GitHubItemText.summary(storedAsIssue, [storedAsIssue.item: .found(pr)]),
      "Issue として付けた番号が実は PR")
    XCTAssertNil(GitHubItemText.summary(link(.pr, 213), [:]), "値が届くまで")
    XCTAssertNil(GitHubItemText.summary(link(.pr, 213), [link(.pr, 213).item: .missing]), "無かった")
  }

  // MARK: - 状態

  /// PR の段階はマージ済み > 閉じた > 下書き > レビュー状態の順に強い。
  func testPullRequestPhaseTakesTheStrongestState() {
    let phase = { GitHubItemText.phase($0) }

    XCTAssertEqual(phase(pullRequest(.merged, draft: true, review: .approved)), .merged)
    XCTAssertEqual(phase(pullRequest(.closed, draft: true, review: .approved)), .closed)
    XCTAssertEqual(phase(pullRequest(draft: true, review: .approved)), .draft)
    XCTAssertEqual(phase(pullRequest(review: .reviewRequired)), .reviewRequired)
    XCTAssertEqual(phase(pullRequest(review: .approved)), .approved)
    XCTAssertEqual(phase(pullRequest(review: .changesRequested)), .changesRequested)
    XCTAssertNil(phase(pullRequest(review: nil)), "レビュー状態の無い open の PR")
    XCTAssertNil(phase(issue()), "Issue")
  }

  /// Issue は open / closed。PR は CI と段階で、CI は open の PR にだけ出す。
  func testStateShowsChecksOnlyWhileThePullRequestIsOpen() {
    XCTAssertEqual(GitHubItemText.state(issue()), .issue(open: true))
    XCTAssertEqual(GitHubItemText.state(issue(.closed)), .issue(open: false))
    XCTAssertEqual(
      GitHubItemText.state(pullRequest(checks: .failure)),
      .pullRequest(checks: .failure, phase: .reviewRequired))
    XCTAssertEqual(
      GitHubItemText.state(pullRequest(.merged, checks: .failure)),
      .pullRequest(checks: nil, phase: .merged), "マージ済み")
    XCTAssertEqual(
      GitHubItemText.state(pullRequest(.closed, checks: .pending)),
      .pullRequest(checks: nil, phase: .closed), "閉じた")
  }

  // MARK: - PR の札

  func testBadgeIsTheFirstLinkedPullRequestOfAPrimaryIssue() {
    let links = [link(.issue, 212), link(.issue, 300), link(.pr, 213), link(.pr, 214)]
    let items: [GitHubItemID: GitHubItemAnswer] = [
      link(.pr, 213).item: .found(pullRequest(checks: .pending)),
      link(.pr, 214).item: .found(pullRequest(.merged)),
    ]

    XCTAssertEqual(
      GitHubItemText.pullRequestBadge(links, items),
      .init(number: 213, phase: .reviewRequired, checks: .pending))
  }

  /// 終わった PR の札には CI を出さない（右の欄の状態と同じ規則）。
  func testBadgeHidesChecksOnceThePullRequestIsOver() {
    let links = [link(.issue, 212), link(.pr, 213)]

    XCTAssertEqual(
      GitHubItemText.pullRequestBadge(
        links, [link(.pr, 213).item: .found(pullRequest(.merged, checks: .failure))]),
      .init(number: 213, phase: .merged, checks: nil))
  }

  /// 値が届くまで・無かった・実体が PR でないときは、番号だけの札。
  func testBadgeIsNumberOnlyWithoutAPullRequestValue() {
    let links = [link(.issue, 212), link(.pr, 213)]
    let numberOnly = GitHubItemText.PullRequestBadge(number: 213, phase: nil, checks: nil)

    XCTAssertEqual(GitHubItemText.pullRequestBadge(links, [:]), numberOnly, "値が届くまで")
    XCTAssertEqual(
      GitHubItemText.pullRequestBadge(links, [link(.pr, 213).item: .missing]), numberOnly, "無かった")
    XCTAssertEqual(
      GitHubItemText.pullRequestBadge(links, [link(.pr, 213).item: .found(issue())]), numberOnly,
      "PR として付けた番号が実は Issue")
  }

  func testNoBadgeUnlessThePrimaryIsAnIssueWithALinkedPullRequest() {
    XCTAssertNil(GitHubItemText.pullRequestBadge([link(.pr, 213), link(.pr, 214)], [:]), "主が PR")
    XCTAssertNil(
      GitHubItemText.pullRequestBadge([link(.issue, 212), link(.issue, 300)], [:]), "PR が無い")
  }

  // MARK: - 「レビュー」

  /// 主の PR を自分以外（login の大小文字は問わない）が作ったときだけ。
  func testReviewIsNeededOnlyWhenThePrimaryPullRequestIsSomeoneElses() {
    let pr = link(.pr, 213)
    let needsReview = { (links: [TaskLink], value: GitHubItemSummary?, viewer: String?) in
      GitHubItemText.needsReview(
        links, value.map { [pr.item: .found($0)] } ?? [:], viewerLogin: viewer)
    }

    XCTAssertTrue(needsReview([pr], pullRequest(author: "sato"), "nakatake"))
    XCTAssertFalse(needsReview([pr], pullRequest(author: "Nakatake"), "nakatake"), "自分の PR")
    XCTAssertFalse(needsReview([pr], pullRequest(author: "sato"), nil), "自分が分からない")
    XCTAssertFalse(needsReview([pr], nil, "nakatake"), "値が届くまで")
    XCTAssertFalse(needsReview([pr], issue(), "nakatake"), "PR として付けた番号が実は Issue")
    XCTAssertFalse(
      needsReview([link(.issue, 212), pr], pullRequest(author: "sato"), "nakatake"), "主が Issue")
  }
}
