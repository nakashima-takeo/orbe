import XCTest

@testable import Orbe

/// PR のパネルの面ごとの見せ方（`PrPanel`）——出している間だけ worktree の今の PR を見ること、列のキー（↑↓ は選べる行だけを
/// 渡り、ファイル行なら PR の diff を仮のタブで開く。← → はフォルダと区分の開閉と親・子への移動）、フォルダのチェック。
/// GitHub は差し替えの構造体が答え、git は一時リポジトリで実際に問う。
///
/// 壊れると何が起きるか: パネルを隠しても GitHub に問い合わせ続ける・出しても PR が出ない。↓ がコミットの行に止まる・
/// フォルダへ動いただけで diff が開く。← で親へ戻れない。畳んだ後や、選んでいた行が読み直しで消えた後の ↑↓ が列の先頭へ飛ぶ。一部だけ確認済みのフォルダのチェックを押すと、付けるはずが
/// 配下の確認済みを全部外す。
@MainActor
final class PrPanelTests: OrbeTestCase {
  private var repo: TempGitRepo!
  private var panel: PrPanel!
  private var writes: [(viewed: Bool, paths: Set<String>)] = []
  private var opened: [(key: EditorDiff.Key, opening: ScmPanel.Opening)] = []
  private let me = GitHubRepoName(nameWithOwner: "me/r")
  /// 変更ファイル（テストが書き換えて、次の読み直しに答えさせる）。src/a/x.swift だけが確認済み。
  private var files = ["src/a/x.swift", "src/a/y.swift", "src/b.swift", "README.md"]
  /// ツリーかリストか（アプリ全体の選択の代わり）。
  private var asTree = true

  override func setUpWithError() throws {
    repo = try TempGitRepo()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    writes = []
    opened = []
    asTree = true
    panel = PrPanel(root: repo.root, source: source)
    panel.filesAsTree = { [unowned self] in asTree }
    panel.onViewAsTree = { [unowned self] in asTree = $0 }
    panel.navigation.delay.schedule = { _, fire in fire() }
    panel.onOpenDiff = { [unowned self] key, opening in opened.append((key, opening)) }
  }

  override func tearDown() {
    panel.isShown = false
    super.tearDown()
  }

  private var source: PullRequestSource {
    let ref = GitHubBranchRef(repo: me, branch: "feat")
    let pullRequest = GitHubBranchPR(
      number: 9, headRefName: "feat", state: "OPEN", baseRefName: "main", headRepository: me,
      url: "https://github.com/me/r/pull/9")
    return PullRequestSource(
      branchPullRequests: { _, branch, completion in
        completion(
          GitHubBranchPullRequests(
            availability: .ready, ledger: nil,
            branches: [branch: .gitHub(ref, pullRequests: .success([pullRequest]))]))
      },
      branchExists: { _, completion in completion(.success(true)) },
      content: { [unowned self] _, completion in completion(.success(content)) },
      setViewed: { [unowned self] viewed, paths, _, completion in
        writes.append((viewed, paths))
        completion(GitHubViewedWrite(written: paths, failure: nil))
      })
  }

  private var content: GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: "PR_1", number: 9, title: "題", url: "https://github.com/me/r/pull/9", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: "b", headCommit: "h", commitCount: 2,
      commits: [.init(oid: "c1", headline: "一"), .init(oid: "c2", headline: "二")],
      files: files.map { .init(path: $0, change: .modified, isViewed: $0 == "src/a/x.swift") })
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

  /// パネルを出して、PR の中身が届くまで待つ。
  private func shown() throws -> PullRequestState {
    panel.isShown = true
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

    panel.isShown = false
    XCTAssertFalse(state.isWatched, "隠せば PR の状態を見るのをやめる")
  }

  // MARK: - キー

  /// ↓ は未選択なら先頭から、区分の見出し・フォルダ・ファイル行だけを順に渡り（コミットの行は飛ばす）、末尾で止まる。
  /// ファイル行へ動いたときだけ、その PR の diff を仮のタブで開く。
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
  /// → は畳んだフォルダを開き、開いたフォルダなら最初の子へ動く（ファイルなら仮のタブで開く）。
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

  /// 見出しの切り替えでリストにすれば、その場で行を組み直す。ファイルの選択はそのまま、消えたフォルダの選択は同じ位置の
  /// 行へ移る。
  func testSwitchingToTheListRebuildsTheRowsAtOnce() throws {
    _ = try shown()
    panel.select(.folder("src/a"))
    panel.press(try row(.section(.files)), .list, in: panel.layout)
    XCTAssertFalse(asTree, "アプリ全体の選択へ書く")
    XCTAssertNil(panel.layout.index[.folder("src")], "リストにはフォルダの行が無い")
    XCTAssertEqual(panel.selection, .file("src/b.swift"), "同じ位置の行")

    panel.press(try row(.section(.files)), .tree, in: panel.layout)
    XCTAssertNotNil(panel.layout.index[.folder("src")], "ツリーに戻す")
    XCTAssertEqual(panel.selection, .file("src/b.swift"), "ファイルの選択はそのまま")
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
