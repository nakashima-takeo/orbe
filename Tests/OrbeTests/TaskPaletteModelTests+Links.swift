import XCTest

@testable import Orbe

/// 結び付いた Issue・PR を、画面に出ている行の分だけ取りに行くことと、右の欄の Issue・PR の欄の行
/// （↑↓ で止まる・開く・外す・焦点の付け直し）。
///
/// 壊れると何が起きるか: 完了の欄に溜まった結び付きまで毎回取りに行き、使うほど ⌘⇧X を開くたびの
/// 問い合わせが膨らむ。逆に、agent が結び付けた項目や開いた完了の欄の項目を取りに行かず、番号だけのまま
/// 残る。外したときに焦点が右の欄の先頭へ飛ぶ、または消えた項目に残ってキーが効かなくなる。agent が
/// 結び付きを足しただけで、見ていた項目から焦点がずれ、⌫ が別の項目を外す。
extension TaskPaletteModelTests {
  /// 頼まれた項目を順に記録し、その場で全部「無かった」と答える取得（取得中に残る項目は無い）。
  final class FetchLog {
    private(set) var requested: [Set<GitHubItemID>] = []
    lazy var cache = GitHubItemCache { ids, batch in
      self.requested.append(Set(ids))
      batch(
        ids,
        GitHubItemsBatch(viewerLogin: nil, answers: ids.reduce(into: [:]) { $0[$1] = .missing }))
    }
  }

  func link(_ kind: GitHubItemKind, _ number: Int) -> TaskLink {
    TaskPaletteSamples.link(kind, number)
  }

  private func setLinks(_ palette: TaskPaletteModel, _ id: Int, _ links: [TaskLink]) throws {
    var update = TaskUpdate()
    update.links = links
    _ = try palette.store.update(id, update)
  }

  /// 未着手 a（Issue 1）と完了 b（Issue 3）。
  private var todoAndDone: [TaskItem] {
    [
      task(1, "a") { $0.links = [self.link(.issue, 1)] },
      task(2, "b", .done) { $0.links = [self.link(.issue, 3)] },
    ]
  }

  // MARK: - 取りに行く範囲

  /// 開いたときは、出ている行の結び付きだけを取り直す（畳んだ完了の欄のタスクの分は取らない）。
  func testOpeningFetchesOnlyTheLinksOfTheVisibleRows() {
    let log = FetchLog()

    _ = TaskPaletteSamples.model(
      [
        task(1, "a") { $0.links = [self.link(.issue, 1), self.link(.pr, 2)] },
        task(2, "b", .done) { $0.links = [self.link(.issue, 3)] },
      ], githubItems: log.cache)

    XCTAssertEqual(log.requested, [[link(.issue, 1).item, link(.pr, 2).item]])
  }

  /// 置き場はアプリで 1 つ。前に開いたときに取った項目も、開き直せば取り直す。
  func testReopeningFetchesAgainWhatAnEarlierOpeningAlreadyFetched() {
    let log = FetchLog()
    _ = TaskPaletteSamples.model(todoAndDone, githubItems: log.cache)

    _ = TaskPaletteSamples.model(todoAndDone, githubItems: log.cache)

    XCTAssertEqual(log.requested, [[link(.issue, 1).item], [link(.issue, 1).item]])
  }

  /// 完了の欄を開く・agent が結び付けるなどで新しく出た項目は、この開いている間に 1 回だけ取る。
  /// 前に開いたときの答えがあっても、この開いている間にまだ試していなければ取る。
  func testNewlyVisibleLinksAreFetchedOnceWhileOpenEvenWithAnEarlierAnswer() throws {
    let log = FetchLog()
    let earlier = TaskPaletteSamples.model(todoAndDone, githubItems: log.cache)
    earlier.toggleDoneExpanded()
    earlier.ensureVisibleItems()
    XCTAssertNotNil(log.cache.answers[link(.issue, 3).item], "前提: 完了の欄の項目に前の答えがある")

    let palette = TaskPaletteSamples.model(todoAndDone, githubItems: log.cache)
    palette.toggleDoneExpanded()
    palette.ensureVisibleItems()
    XCTAssertEqual(log.requested.last, [link(.issue, 3).item], "開いた完了の欄の項目")

    try setLinks(palette, 1, [link(.issue, 1), link(.pr, 4)])
    palette.reconcile()
    palette.ensureVisibleItems()
    XCTAssertEqual(log.requested.last, [link(.pr, 4).item], "agent が結び付けた項目")

    let count = log.requested.count
    palette.ensureVisibleItems()
    palette.toggleDoneExpanded()
    palette.ensureVisibleItems()
    XCTAssertEqual(log.requested.count, count, "答えが届いた後も、この開いている間に試した項目は頼まない")
  }

  // MARK: - 右の欄の Issue・PR の欄

  /// 3 つの結び付き（Issue 1・PR 2・Issue 3）を持つ a の右の欄に入った状態。
  func detailWithLinks() -> TaskPaletteModel {
    detailOfFirst([
      task(1, "a") { $0.links = [self.link(.issue, 1), self.link(.pr, 2), self.link(.issue, 3)] },
      task(2, "b"),
    ])
  }

  func testDetailStopsRunFromTheTitleThroughEachLinkToTheStatus() {
    let palette = detailWithLinks()
    var visited: [TaskPaletteArea] = []

    for _ in 0..<5 {
      palette.moveField(-1)
      visited.append(palette.area)
    }

    XCTAssertEqual(
      visited,
      [
        .detail(.addLink), .detail(.link(link(.issue, 3).item)), .detail(.link(link(.pr, 2).item)),
        .detail(.link(link(.issue, 1).item)), .detail(.field(.title)),
      ], "ステータスから上へ: 結び付ける → 各結び付き（並びの逆順）→ タイトル")
  }

  func testOpeningALinkHandsItsGitHubPageToTheBrowser() {
    let palette = detailWithLinks()
    var opened: [URL] = []
    palette.onOpenURL = { opened.append($0) }

    palette.openLink(link(.issue, 1).item)
    palette.openLink(link(.pr, 2).item)

    XCTAssertEqual(
      opened.map(\.absoluteString),
      ["https://github.com/o/n/issues/1", "https://github.com/o/n/pull/2"])
    XCTAssertEqual(palette.area, .detail(.link(link(.pr, 2).item)), "開いた行に居る")
  }

  /// 外すのはその 1 件だけで、焦点は同じ位置の止まる場所（次の結び付き、末尾なら「＋ 結び付ける」）へ移る。
  func testUnlinkingRemovesOnlyThatLinkAndFocusMovesToTheSamePosition() throws {
    let palette = detailWithLinks()

    palette.unlink(link(.pr, 2).item)
    XCTAssertEqual(try storedTask(palette, 1).links, [link(.issue, 1), link(.issue, 3)])
    XCTAssertEqual(palette.area, .detail(.link(link(.issue, 3).item)))

    palette.unlink(link(.issue, 3).item)
    XCTAssertEqual(palette.area, .detail(.addLink))
    XCTAssertEqual(TaskStore().tasks.first?.links, [link(.issue, 1)], "即時に保存される")
  }

  /// 焦点は位置でなく項目に付く。agent が前に結び付けても同じ項目に居続け、その項目が外されたら
  /// 同じ位置の止まる場所へ移る。
  func testFocusStaysOnTheSameLinkWhileAnAgentChangesTheLinks() throws {
    let palette = detailWithLinks()
    palette.area = .detail(.link(link(.pr, 2).item))

    try setLinks(palette, 1, [link(.pr, 9), link(.issue, 1), link(.pr, 2), link(.issue, 3)])
    palette.reconcile()
    XCTAssertEqual(palette.area, .detail(.link(link(.pr, 2).item)), "前に足されても同じ項目")

    try setLinks(palette, 1, [link(.pr, 9), link(.issue, 1), link(.issue, 3)])
    palette.reconcile()
    XCTAssertEqual(palette.area, .detail(.link(link(.issue, 3).item)), "外されたら同じ位置へ")
  }
}
