import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR のパネルの面ごとの見せ方（`PrPanel`）——出している間だけ worktree の今の PR を見ること、列のキー（↑↓ は選べる行だけを
/// 渡り、ファイル行なら PR の diff を仮の文書として開く。← → はフォルダと区分の開閉と親・子への移動。Enter はファイル行を
/// 普通の文書として開き、フォルダと見出しは開閉。押し続けた ↑↓ は離すまで開かない）、選択の選び直し、フォルダのチェック。
/// GitHub は差し替えの構造体が答え、git は一時リポジトリで実際に問う。
///
/// 壊れると何が起きるか: パネルを隠しても GitHub に問い合わせ続ける・出しても PR が出ない。↓ がコミットの行に止まる・
/// フォルダへ動いただけで diff が開く。← で親へ戻れない。畳んだ後や、選んでいた行が読み直しで消えた後の ↑↓ が列の先頭へ
/// 飛ぶ。Enter でファイルが普通の文書として開かない。↓ を押し続けると 1 行ごとに diff を開く・Enter や本文へ移った後に、待って
/// いた前の行の diff が開く。一部だけ確認済みのフォルダのチェックを押すと、付けるはずが配下の確認済みを全部外す。
@MainActor
final class PrPanelTests: OrbeTestCase {
  private var repo: TempGitRepo!
  var panel: PrPanel!
  private var writes: [(viewed: Bool, paths: Set<String>)] = []
  private var opened: [(key: EditorDiff.Key, opening: ScmPanel.Opening)] = []
  private let me = GitHubRepoName(nameWithOwner: "me/r")
  /// 変更ファイル（テストが書き換えて、次の読み直しに答えさせる）。src/a/x.swift だけが確認済み。
  private var files = ["src/a/x.swift", "src/a/y.swift", "src/b.swift", "README.md"]
  /// ツリーかリストか（アプリ全体の選択の代わり）。
  private var asTree = true
  /// ブランチに open の PR があるか（偽なら、PR が無いと答える）。
  private var open = true
  /// PR の番号（テストが替えて、次の引き直しに答えさせる）。
  var number = 9
  /// レビューのやりとりの答え（自分が作者か・未送信のコメントの数・スレッド）と、届いたレビューへの書き込みとその答えの失敗。
  var viewerIsAuthor = false
  var pendingComments = 0
  var threads: [GitHubPullRequestReview.Thread] = []
  var reviewWrites: [GitHubReviewWrite] = []
  var reviewFailure: GitHubFailure?
  /// 真ならレビューへの書き込みの答えを返さずに `heldReviewWrites` に溜める（送信の最中を作る）。
  var holdsReviewWrites = false
  var heldReviewWrites: [() -> Void] = []
  /// GitHub の読み（ブランチの PR の問い合わせ・中身・レビューのやりとり）の失敗と、確認済みの書き込みの失敗。
  var readFailure: GitHubFailure?
  /// レビューのやりとりの読みだけの失敗。
  var reviewReadFailure: GitHubFailure?
  var viewedFailure: GitHubFailure?
  /// GitHub が rename と答える変更ファイル。真なら中身の読みの答えを `heldContents` に溜める。
  var renamed: Set<String> = []
  var holdsContents = false
  var heldContents: [() -> Void] = []
  /// PR の先頭のコミット（手元の feat の先頭。ベースも同じコミット）と、レビューのやりとりが答える先頭のコミット。
  var head = ""
  var reviewHead = ""

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    head = repo.head()
    reviewHead = head
    writes = []
    opened = []
    asTree = true
    open = true
    panel = PrPanel(root: repo.root, source: source)
    panel.filesAsTree = { [unowned self] in asTree }
    panel.onViewAsTree = { [unowned self] in asTree = $0 }
    panel.navigation.delay.schedule = { _, fire in fire() }
    panel.onOpenDiff = { [unowned self] key, opening in opened.append((key, opening)) }
  }

  override func tearDown() {
    hide(panel)
    super.tearDown()
  }

  /// 面が見えていて PR の画面を出している姿にする（追ってから中身も読む）。
  private func show(_ panel: PrPanel) {
    panel.isTracking = true
    panel.isShown = true
  }

  /// 面が隠れた姿にする（中身を読むのをやめてから追うのをやめる）。
  private func hide(_ panel: PrPanel) {
    panel.isShown = false
    panel.isTracking = false
  }

  private var source: PullRequestSource {
    let ref = GitHubBranchRef(repo: me, branch: "feat")
    return PullRequestSource(
      branchPullRequests: { [unowned self] _, branch, completion in
        let pullRequest = GitHubBranchPR(
          number: number, headRefName: "feat", state: "OPEN", baseRefName: "main",
          headRepository: me, url: "https://github.com/me/r/pull/\(number)")
        let found: Result<[GitHubBranchPR], GitHubFailure> =
          readFailure.map { .failure($0) } ?? .success(open ? [pullRequest] : [])
        completion(
          GitHubBranchPullRequests(
            ledger: nil, branches: [branch: .gitHub(ref, pullRequests: found)]))
      },
      branchExists: { _, completion in completion(.success(true)) },
      content: { [unowned self] _, completion in
        let answer = { [unowned self] in
          completion(readFailure.map { .failure($0) } ?? .success(content))
        }
        if holdsContents { heldContents.append(answer) } else { answer() }
      },
      setViewed: { [unowned self] viewed, paths, _, completion in
        writes.append((viewed, paths))
        completion(
          GitHubViewedWrite(written: viewedFailure == nil ? paths : [], failure: viewedFailure))
      },
      review: { [unowned self] _, completion in
        completion(
          (readFailure ?? reviewReadFailure).map { .failure($0) }
            ?? .success(
              GitHubPullRequestReview(
                viewerIsAuthor: viewerIsAuthor, headCommit: reviewHead,
                pendingReview: pendingComments > 0
                  ? .init(id: "R", commentCount: pendingComments) : nil, threads: threads)))
      },
      writeReview: { [unowned self] write, _, pending, _, completion in
        reviewWrites.append(write)
        let answer = { [unowned self] in
          completion(GitHubReviewWriteResult(pendingReview: pending, failure: reviewFailure))
        }
        if holdsReviewWrites { heldReviewWrites.append(answer) } else { answer() }
      })
  }

  private var content: GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: number, title: "題", url: "https://github.com/me/r/pull/\(number)",
      isDraft: false, state: .open, body: "", author: "me", baseRefName: "main",
      headRefName: "feat",
      baseCommit: head, headCommit: head, commitCount: 2,
      commits: [.init(oid: "c1", headline: "一"), .init(oid: "c2", headline: "二")],
      files: files.map {
        .init(
          path: $0, change: renamed.contains($0) ? .renamed : .modified,
          isViewed: $0 == "src/a/x.swift")
      })
  }

  /// 変更ファイルを `next` にして読み直し、列の行が組み直されるまで待つ。
  private func reload(files next: [String]) {
    files = next
    panel.refresh()
    pumpMain(
      until: {
        self.panel.layout.items.count(where: { if case .file = $0 { true } else { false } })
          == next.count
      },
      "前提: 読み直した中身で行を組み直す")
  }

  /// パネルを出して、PR の中身・レビューのやりとり・diff の両端が揃うまで待つ。
  func reviewed() throws -> PullRequestState {
    let state = try shown()
    pumpMain(until: { state.review != nil && state.diffEnds != nil }, "前提: レビューのやりとりと diff の両端が届く")
    return state
  }

  /// パネルを出して、PR の中身が届くまで待つ。
  func shown() throws -> PullRequestState {
    show(panel)
    pumpMain(until: { self.panel.state?.content != nil }, "前提: PR の中身が届く")
    return try XCTUnwrap(panel.state)
  }

  private func row(_ id: PrRowID) throws -> Int {
    try XCTUnwrap(panel.layout.index[id], "\(id) の行")
  }

  // MARK: - 出し入れ

  /// 出している間だけ worktree の今の PR とその PR の状態を見て、隠せば見るのをやめる。
  func testShowingThePanelWatchesThePullRequestAndHidingStops() throws {
    XCTAssertNil(panel.state, "出す前は PR を引かない")
    let state = try shown()
    XCTAssertTrue(state.isWatched)

    hide(panel)
    XCTAssertFalse(state.isWatched, "隠せば PR の状態を見るのをやめる")
  }

  // MARK: - キー

  /// ↓ は未選択なら先頭から、区分の見出し・フォルダ・ファイル行だけを順に渡り（コミットの行は飛ばす）、末尾で止まる。
  /// ファイル行へ動いたときだけ、その PR の diff を仮の文書として開く。
  func testDownCrossesOnlySelectableRowsAndPreviewsTheFilesItReaches() throws {
    let state = try shown()
    var visited: [PrRowID?] = []
    for _ in 0..<9 {
      panel.moveSelection(by: 1, isRepeat: false, in: panel.layout)
      visited.append(panel.selection)
    }
    XCTAssertEqual(
      visited,
      [
        .section(.commits), .section(.files), .folder("src"), .folder("src/a"),
        .file("src/a/x.swift"), .file("src/a/y.swift"), .file("src/b.swift"), .file("README.md"),
        .file("README.md"),
      ])
    XCTAssertEqual(
      opened.map(\.key.path), ["src/a/x.swift", "src/a/y.swift", "src/b.swift", "README.md"],
      "見出しとフォルダでは開かない")
    XCTAssertTrue(opened.allSatisfy { $0.key.kind == .pullRequest(state) && $0.opening == .browse })
  }

  /// ← はファイル・フォルダから親のフォルダへ、開いたフォルダなら畳み、一番上のフォルダからは変更ファイルの見出しへ。
  /// → は畳んだフォルダを開き、開いたフォルダなら最初の子へ動く（ファイルなら仮の文書として開く）。
  func testLeftAndRightWalkUpAndDownTheTree() throws {
    _ = try shown()
    panel.select(.file("src/a/y.swift"))
    var walked: [PrRowID?] = []
    for _ in 0..<5 {
      panel.moveLeft(in: panel.layout)
      walked.append(panel.selection)
    }
    XCTAssertEqual(
      walked,
      [.folder("src/a"), .folder("src/a"), .folder("src"), .folder("src"), .section(.files)])
    XCTAssertEqual(panel.closedFolders, ["src", "src/a"], "開いたフォルダは ← で畳む")

    panel.select(.folder("src"))
    walked = []
    for _ in 0..<4 {
      panel.moveRight(isRepeat: false, in: panel.layout)
      walked.append(panel.selection)
    }
    XCTAssertEqual(
      walked, [.folder("src"), .folder("src/a"), .folder("src/a"), .file("src/a/x.swift")])
    XCTAssertEqual(panel.closedFolders, [], "畳んだフォルダは → で開く")
    XCTAssertEqual(opened.map(\.key.path), ["src/a/x.swift"], "ファイルへ動いたときだけ開く")
  }

  /// Enter はファイル行を普通の文書として開き、フォルダと区分の見出しは開閉するだけで開かない。
  func testEnterOpensAFileForGoodAndTogglesFoldersAndHeaders() throws {
    _ = try shown()
    let list = PrListSource(panel: panel)
    let enter = RowListKey(action: .enter, isRepeat: false)

    panel.select(.file("README.md"))
    list.perform(enter, in: panel.layout)
    XCTAssertEqual(opened.map(\.key.path), ["README.md"])
    XCTAssertEqual(opened.last?.opening, .commit, "普通の文書")

    panel.select(.folder("src"))
    list.perform(enter, in: panel.layout)
    XCTAssertEqual(panel.closedFolders, ["src"], "フォルダは畳む")
    panel.select(.section(.commits))
    list.perform(enter, in: panel.layout)
    XCTAssertFalse(panel.isOpen(.commits), "見出しは畳む")
    XCTAssertEqual(opened.count, 1, "フォルダと見出しでは開かない")
  }

  /// ↓ を押し続けると、押し始めの行はすぐ開き、押している間は開かず、離したら最後の行を開く。
  func testHoldingDownOpensOnlyTheFirstAndTheLastFile() throws {
    _ = try shown()
    let list = PrListSource(panel: panel)
    panel.select(.folder("src/a"))

    list.perform(RowListKey(action: .down, isRepeat: false), in: panel.layout)
    XCTAssertEqual(opened.map(\.key.path), ["src/a/x.swift"], "押し始めはすぐ開く")
    list.perform(RowListKey(action: .down, isRepeat: true), in: panel.layout)
    XCTAssertEqual(panel.selection, .file("src/a/y.swift"))
    XCTAssertEqual(opened.count, 1, "押している間は開かない")
    list.keyDidRelease()
    XCTAssertEqual(opened.map(\.key.path), ["src/a/x.swift", "src/a/y.swift"], "離したら最後の行")
    XCTAssertEqual(opened.last?.opening, .browse)
  }

  /// 押し続けて待っている開きは、列から焦点が外れた・Enter で開いた・パネルが隠れたら捨てる（離しても前の行が開かない）。
  func testAPendingOpenIsDroppedWhenAttentionLeavesTheList() throws {
    _ = try shown()
    let list = PrListSource(panel: panel)
    let enter = RowListKey(action: .enter, isRepeat: false)
    let leaves: [(String, () -> Void)] = [
      ("列から焦点が外れた", { list.focusDidChange(false) }),
      ("Enter", { list.perform(enter, in: self.panel.layout) }),
      ("パネルが隠れた", { self.panel.isShown = false }),
    ]
    for (name, leave) in leaves {
      panel.select(.file("src/b.swift"))
      list.perform(RowListKey(action: .up, isRepeat: true), in: panel.layout)
      XCTAssertEqual(panel.selection, .file("src/a/y.swift"), name)
      leave()
      let count = opened.count
      list.keyDidRelease()
      XCTAssertEqual(opened.count, count, "\(name): 待っていた開きは走らない")
    }
  }

  /// 選択はいつも見えている行にある——フォルダを畳めば、その下の選択（ファイルでもフォルダでも）はそのフォルダへ、
  /// 区分を畳めば、その下の選択は区分の見出しへ移る。
  func testCollapsingMovesAHiddenSelectionToTheCollapsedRow() throws {
    _ = try shown()
    panel.select(.file("src/a/x.swift"))
    panel.toggleFolder("src")
    XCTAssertEqual(panel.selection, .folder("src"), "下のファイル")
    panel.toggleFolder("src")

    panel.select(.folder("src/a"))
    panel.toggleFolder("src")
    XCTAssertEqual(panel.selection, .folder("src"), "下のフォルダ")
    panel.toggleFolder("src")

    panel.select(.file("README.md"))
    panel.toggle(.files)
    XCTAssertEqual(panel.selection, .section(.files), "区分の下")
  }

  /// 読み直しで選んでいた行が PR から消えれば、変更ファイルの区分の同じ位置の行（無ければ最後の行）を選び、区分に行が
  /// 無くなれば選択を外す。消えた行を選び直しても開かない。
  func testARowThatLeavesThePullRequestHandsTheSelectionToTheRowInItsPlace() throws {
    _ = try shown()
    panel.select(.file("src/a/y.swift"))
    reload(files: ["src/a/x.swift", "src/b.swift", "README.md"])
    XCTAssertEqual(panel.selection, .file("src/b.swift"), "同じ位置の行")

    panel.select(.file("README.md"))
    reload(files: ["src/b.swift"])
    XCTAssertEqual(panel.selection, .file("src/b.swift"), "同じ位置に行が無ければ最後の行")

    reload(files: [])
    XCTAssertNil(panel.selection, "区分に行が無ければ外す")
    XCTAssertTrue(opened.isEmpty, "選び直しでは開かない")
  }

  /// 列に当てる前に PR が無くなって行の組が空になれば、焦点の要求を捨て、列が消えることを知らせる（後で列が現れた瞬間に
  /// 焦点を奪わない）。
  func testAFocusRequestIsDroppedWhenTheRowsGoAway() throws {
    _ = try shown()
    var closings = 0
    panel.onFocusWillClose = { closings += 1 }
    panel.requestFocus()

    open = false
    panel.refresh()
    pumpMain(until: { self.panel.layout.items.isEmpty }, "PR が無いと分かる")
    XCTAssertFalse(panel.focusRequest, "当てる列の無い要求は捨てる")
    XCTAssertEqual(closings, 1, "列が消える前に 1 回知らせる")
  }

  /// 見出しの切り替えでリストにすれば、その場で行を組み直す。消えたフォルダの選択は配下の最初のファイルへ移り、ファイルの
  /// 選択はツリーに戻してもそのまま。
  func testSwitchingToTheListRebuildsTheRowsAtOnce() throws {
    _ = try shown()
    panel.select(.folder("src/a"))
    panel.press(try row(.section(.files)), .list, in: panel.layout)
    XCTAssertFalse(asTree, "アプリ全体の選択へ書く")
    XCTAssertNil(panel.layout.index[.folder("src")], "リストにはフォルダの行が無い")
    XCTAssertEqual(panel.selection, .file("src/a/x.swift"), "配下の最初のファイル")

    panel.press(try row(.section(.files)), .tree, in: panel.layout)
    XCTAssertNotNil(panel.layout.index[.folder("src")], "ツリーに戻す")
    XCTAssertEqual(panel.selection, .file("src/a/x.swift"), "ファイルの選択はそのまま")
  }

  // MARK: - フォルダのチェック

  /// フォルダのチェックは、配下（孫を含む）が一部だけ確認済みなら全部付け、全部確認済みなら全部外す。GitHub へは値の
  /// 変わるパスだけを書く。
  func testTheFolderCheckSetsAllUnlessAllAreViewedThenClearsAll() throws {
    let state = try shown()
    let src = ["src/a/x.swift", "src/a/y.swift", "src/b.swift"]

    panel.press(try row(.folder("src")), .viewed, in: panel.layout)
    XCTAssertTrue(src.allSatisfy(state.isViewed), "一部だけなら全部付ける")
    XCTAssertEqual(writes.map(\.viewed), [true])
    XCTAssertEqual(writes.last?.paths, ["src/a/y.swift", "src/b.swift"], "付いていないものだけ書く")

    panel.press(try row(.folder("src")), .viewed, in: panel.layout)
    XCTAssertFalse(src.contains(where: state.isViewed), "全部確認済みなら全部外す")
    XCTAssertEqual(writes.last?.viewed, false)
    XCTAssertEqual(writes.last?.paths, Set(src))
  }
}
