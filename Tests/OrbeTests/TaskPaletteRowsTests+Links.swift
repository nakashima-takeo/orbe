import XCTest

@testable import Orbe

/// タスクの行の、結び付いた Issue・PR の札（主の印と番号・PR の札・「レビュー」）。
///
/// 壊れると何が起きるか: GitHub の値が届くまで（再起動直後・オフライン・gh が無い）行から番号まで消え、
/// どのタスクがどの Issue かが分からなくなる。札の状態の強さを取り違えると、マージ済みの PR が
/// 「レビュー待ち」と出て、人が終わった作業に手を戻す。保存した種別と実体の種別が食い違うまま値を出すと、
/// Issue のタイトルが PR の札に載る。自分の PR に「レビュー」と出ると、人は自分を待つ。
extension TaskPaletteRowsTests {
  private func link(_ kind: GitHubItemKind, _ number: Int, repo: String = "o/n") -> TaskLink {
    TaskPaletteSamples.link(kind, number, repo: repo)
  }

  private func issue(_ state: GitHubItemSummary.State = .open) -> GitHubItemAnswer {
    .found(GitHubItemSummary(title: "issue", state: state, pullRequest: nil))
  }

  private func pullRequest(
    _ state: GitHubItemSummary.State = .open, draft: Bool = false,
    review: GitHubItemSummary.ReviewDecision? = .reviewRequired,
    checks: GitHubItemSummary.Checks? = .success, author: String? = "nakatake"
  ) -> GitHubItemAnswer {
    .found(
      GitHubItemSummary(
        title: "pr", state: state,
        pullRequest: .init(isDraft: draft, review: review, checks: checks, author: author)))
  }

  private func linked(_ links: [TaskLink]) -> TaskItem {
    task(1) { $0.links = links }
  }

  func testRowShowsThePrimaryLinksKindAndNumberWithoutWaitingForGitHub() throws {
    XCTAssertEqual(
      try taskRow(linked([link(.pr, 213), link(.issue, 212)])).link,
      .init(kind: .pr, number: 213), "先頭が主")
    XCTAssertEqual(try taskRow(linked([link(.issue, 212)])).link, .init(kind: .issue, number: 212))
    XCTAssertNil(try taskRow(task(1)).link, "結び付きが無ければ出さない")
  }

  func testPrimaryIssueCarriesTheFirstLinkedPullRequestsBadge() throws {
    let task = linked([link(.issue, 212), link(.issue, 300), link(.pr, 213), link(.pr, 214)])

    let row = try taskRow(
      task, items: [link(.pr, 213).item: pullRequest(), link(.pr, 214).item: pullRequest(.merged)])

    XCTAssertEqual(row.pullRequest, .init(number: 213, phase: .reviewRequired, checks: .success))
  }

  /// 値が届くまで・無かった・実体が PR でないときは、番号だけの札。
  func testBadgeIsNumberOnlyWithoutAPullRequestValue() throws {
    let task = linked([link(.issue, 212), link(.pr, 213)])
    let numberOnly = TaskPaletteTaskRow.PullRequestBadge(number: 213, phase: nil, checks: nil)

    XCTAssertEqual(try taskRow(task).pullRequest, numberOnly, "値が届くまで")
    XCTAssertEqual(
      try taskRow(task, items: [link(.pr, 213).item: .missing]).pullRequest, numberOnly, "無かった")
    XCTAssertEqual(
      try taskRow(task, items: [link(.pr, 213).item: issue()]).pullRequest, numberOnly,
      "PR として付けた番号が実は Issue")
  }

  /// 状態はマージ済み > 閉じた > 下書き > レビュー状態の順に強い。終わった PR には CI を出さない。
  func testBadgePhaseTakesTheStrongestStateAndHidesChecksOnceThePullRequestIsOver() throws {
    let task = linked([link(.issue, 212), link(.pr, 213)])
    let badge = { (answer: GitHubItemAnswer) in
      try self.taskRow(task, items: [self.link(.pr, 213).item: answer]).pullRequest
    }

    XCTAssertEqual(
      try badge(pullRequest(.merged, draft: true, review: .approved, checks: .failure)),
      .init(number: 213, phase: .merged, checks: nil), "マージ済み")
    XCTAssertEqual(
      try badge(pullRequest(.closed, draft: true, review: .approved, checks: .failure)),
      .init(number: 213, phase: .closed, checks: nil), "閉じた")
    XCTAssertEqual(
      try badge(pullRequest(draft: true, review: .approved, checks: .failure)),
      .init(number: 213, phase: .draft, checks: .failure), "下書き")
    XCTAssertEqual(
      try badge(pullRequest(review: .approved, checks: .pending)),
      .init(number: 213, phase: .approved, checks: .pending), "承認済み")
    XCTAssertEqual(
      try badge(pullRequest(review: .changesRequested, checks: nil)),
      .init(number: 213, phase: .changesRequested, checks: nil), "修正依頼")
    XCTAssertEqual(
      try badge(pullRequest(review: nil)), .init(number: 213, phase: nil, checks: .success),
      "レビュー状態なし")
  }

  func testNoBadgeUnlessThePrimaryIsAnIssueWithALinkedPullRequest() throws {
    XCTAssertNil(try taskRow(linked([link(.pr, 213), link(.pr, 214)])).pullRequest, "主が PR")
    XCTAssertNil(try taskRow(linked([link(.issue, 212), link(.issue, 300)])).pullRequest, "PR が無い")
  }

  /// 「レビュー」は、主の PR を自分以外（login の大小文字は問わない）が作ったときだけ。
  func testReviewIsShownOnlyWhenThePrimaryPullRequestIsSomeoneElses() throws {
    let pr = link(.pr, 213)
    let row = { (task: TaskItem, answer: GitHubItemAnswer?, viewer: String?) in
      try self.taskRow(task, items: answer.map { [pr.item: $0] } ?? [:], viewerLogin: viewer)
    }
    let primaryPR = linked([pr])

    XCTAssertTrue(try row(primaryPR, pullRequest(author: "sato"), "nakatake").needsReview)
    XCTAssertFalse(
      try row(primaryPR, pullRequest(author: "Nakatake"), "nakatake").needsReview, "自分の PR")
    XCTAssertFalse(try row(primaryPR, pullRequest(author: "sato"), nil).needsReview, "自分が分からない")
    XCTAssertFalse(try row(primaryPR, nil, "nakatake").needsReview, "値が届くまで")
    XCTAssertFalse(try row(primaryPR, issue(), "nakatake").needsReview, "PR として付けた番号が実は Issue")
    XCTAssertFalse(
      try row(linked([link(.issue, 212), pr]), pullRequest(author: "sato"), "nakatake").needsReview,
      "主が Issue")
  }

  /// 詳細の Issue・PR の欄に出す値は、保存した種別と GitHub 上の実体の種別が一致するときだけ。
  func testLinkValueIsWithheldWhenTheStoredKindDiffersFromGitHub() {
    let storedAsIssue = link(.issue, 213)
    let items = [storedAsIssue.item: pullRequest()]

    XCTAssertNil(TaskPaletteRows.summary(storedAsIssue, items), "Issue として付けた番号が実は PR")
    XCTAssertNotNil(TaskPaletteRows.summary(link(.pr, 213), items))
    XCTAssertNil(TaskPaletteRows.summary(link(.pr, 213), [:]), "値が届くまで")
  }

  /// 詳細の Issue・PR の欄の番号は、主と同じリポジトリなら `#番号`、違えば owner を除いた名前を添える。
  func testLinkLabelNamesTheRepositoryOnlyWhenItDiffersFromThePrimary() {
    let primary = link(.issue, 212, repo: "nakatake/orbe").item

    XCTAssertEqual(
      TaskPaletteRows.linkLabel(link(.pr, 213, repo: "Nakatake/Orbe").item, primary: primary),
      "#213")
    XCTAssertEqual(
      TaskPaletteRows.linkLabel(link(.pr, 88, repo: "nakatake/api").item, primary: primary),
      "api#88")
  }
}
