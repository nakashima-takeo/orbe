import AppKit
import XCTest

@testable import Orbe

/// エディター面に結んだ PR のパネル——レールで出したら、今の答えで行を組んでから、行があるときだけ列に焦点を入れる。列が
/// 消える・パネルを隠す・cd で根が変わるとき、列にあった焦点は面の本文へ戻り、当てる列の無い焦点の要求は残らない。cd で
/// 根が変わったら前の根の PR を見るのをやめる。ツリーかリストかをほかの面で選べば、この面の行も組み直し、言語を切り替え
/// れば見えている行を読み直す。GitHub は、面を作る前に登録した差し替えの出どころが答える。
///
/// 壊れると何が起きるか: 新しい面や cd の後にレールで PR のパネルを出しても列に焦点が入らない。PR が無くなったのに残った
/// 焦点の要求が、後で PR が現れた瞬間に本文や端末から焦点を奪う。PR がマージされた・ブランチを替えたときに焦点が窓へ落ち、
/// 打鍵がどこにも届かない。cd の後も前の worktree の PR を GitHub に問い合わせ続ける。ほかの面でリストにしても、この面が
/// ツリーのまま。言語を切り替えても、見えている見出しが前の言語のまま。
@MainActor
final class PullRequestPaneTests: OrbeTestCase {
  private struct Hosted {
    let pane: EditorPaneView
    let window: NSWindow
    var list: NSView { pane.pullRequestList.list }
  }

  /// 根ごとの差し替えの出どころ。`open` が偽なら、ブランチに open の PR が無いと答える。
  private final class FakeGitHub {
    var open = true
    private let me = GitHubRepoName(nameWithOwner: "me/r")

    var source: PullRequestSource {
      let ref = GitHubBranchRef(repo: me, branch: "feat")
      let pullRequest = GitHubBranchPR(
        number: 9, headRefName: "feat", state: "OPEN", baseRefName: "main", headRepository: me,
        url: "https://github.com/me/r/pull/9")
      let content = GitHubPullRequestContent(
        nodeID: "PR_1", number: 9, title: "題", url: "https://github.com/me/r/pull/9",
        isDraft: false, state: .open, body: "", author: "me", baseRefName: "main",
        headRefName: "feat", baseCommit: "b", headCommit: "h", commitCount: 0, commits: [],
        files: ["src/a.swift", "b.swift"].map {
          .init(path: $0, change: .modified, isViewed: false)
        })
      return PullRequestSource(
        branchPullRequests: { [unowned self] _, branch, completion in
          completion(
            GitHubBranchPullRequests(
              availability: .ready, ledger: nil,
              branches: [branch: .gitHub(ref, pullRequests: .success(open ? [pullRequest] : []))]))
        },
        branchExists: { _, completion in completion(.success(true)) },
        content: { _, completion in completion(.success(content)) },
        setViewed: { _, _, _, _ in })
    }
  }

  private var gitHub: FakeGitHub!

  override func setUpWithError() throws {
    gitHub = FakeGitHub()
  }

  /// ブランチ feat に居る一時リポジトリの根。面が作る PR のパネルが本物の gh を呼ばないよう、差し替えの出どころを先に
  /// 登録する。
  private func registeredRoot() throws -> String {
    let repo = try TempGitRepo()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    let root = GitWorktreeRoot.root(of: repo.root)
    _ = BranchPullRequest.shared(for: root, source: gitHub.source)
    return root
  }

  /// 根 `root` の連の面だけを窓に載せ、本文に焦点を置く。
  private func host(_ root: String) -> Hosted {
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    let pane = tab.group.view.editor
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    addTeardownBlock {
      MainActor.assumeIsolated {
        pane.shell.selectPanel(.files)
        window.orderOut(nil)
      }
    }
    window.makeFirstResponder(pane.focusTarget)
    return Hosted(pane: pane, window: window)
  }

  /// PR のパネルを出して、列に行が出るまで待つ。
  private func shownWithRows(_ hosted: Hosted) {
    hosted.pane.shell.selectPanel(.pullRequest)
    pumpMain(until: { !hosted.pane.pullRequest.layout.items.isEmpty }, "前提: 列に行が出る")
    pumpMain(until: { hosted.list.window != nil }, "前提: 列が窓に載る")
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }

  /// PR を読んである根の新しい面でレールから出せば、列に焦点が入る。PR が無ければ焦点を求めない。
  func testTheRailFocusesTheListOnlyWhenThereAreRows() throws {
    let root = try registeredRoot()
    shownWithRows(host(root))

    let other = host(root)
    other.pane.shell.selectPanel(.pullRequest)
    pumpMain(until: { other.window.firstResponder === other.list }, "新しい面でも列に焦点")

    gitHub.open = false
    let empty = host(try registeredRoot())
    empty.pane.shell.selectPanel(.pullRequest)
    XCTAssertFalse(empty.pane.pullRequest.focusRequest, "行が無ければ求めない")
  }

  /// 行がある状態で隠し、PR が無くなってから出し直したら、当てる列の無い焦点の要求は残らない——後で PR が現れても、本文の
  /// 焦点を奪わない。
  func testAFocusRequestForRowsThatGoAwayIsNotLeftBehind() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    hosted.pane.shell.selectPanel(.files)
    pumpMain(until: { hosted.window.firstResponder === hosted.pane.focusTarget }, "前提: 本文")

    gitHub.open = false
    hosted.pane.shell.selectPanel(.pullRequest)
    pumpMain(until: { hosted.pane.pullRequest.layout.items.isEmpty }, "PR が無いと分かる")
    XCTAssertFalse(hosted.pane.pullRequest.focusRequest, "当てる列の無い要求は捨てる")
    settle()
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "本文のまま")

    gitHub.open = true
    hosted.pane.pullRequest.refresh()
    pumpMain(until: { hosted.list.window != nil }, "PR が現れる")
    settle()
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "現れても焦点を奪わない")
  }

  /// 列に焦点がある間に、パネルを出したまま PR が無くなる・パネルを隠すと、焦点は面の本文へ戻る（窓へ落ちない）。
  func testTheFocusInTheListReturnsToTheBodyWhenTheListGoesAwayOrHides() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    hosted.window.makeFirstResponder(hosted.list)

    gitHub.open = false
    hosted.pane.pullRequest.refresh()
    pumpMain(
      until: { hosted.window.firstResponder === hosted.pane.focusTarget }, "列が消えたら本文へ")

    gitHub.open = true
    hosted.pane.pullRequest.refresh()
    pumpMain(until: { hosted.list.window != nil }, "前提: PR が戻る")
    hosted.window.makeFirstResponder(hosted.list)
    hosted.pane.shell.selectPanel(.files)
    pumpMain(
      until: { hosted.window.firstResponder === hosted.pane.focusTarget }, "隠したら本文へ")
  }

  /// cd で根が変われば、前の根の PR を見るのをやめ、列にあった焦点は本文へ戻り、新しい根の PR を見る。
  func testChangingTheRootStopsWatchingThePreviousPullRequest() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let previous = try XCTUnwrap(hosted.pane.pullRequest.state)
    hosted.window.makeFirstResponder(hosted.list)

    let next = try registeredRoot()
    hosted.pane.setRoot(next)
    XCTAssertFalse(previous.isWatched, "前の根の PR を見るのをやめる")
    pumpMain(until: { hosted.pane.pullRequest.state != nil }, "新しい根の PR を見る")
    XCTAssertEqual(hosted.pane.pullRequest.root, next)
    XCTAssertTrue(try XCTUnwrap(hosted.pane.pullRequest.state).isWatched)
    settle()
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "焦点は本文へ")
  }

  /// 出しているパネルで言語を切り替えれば、見えている行をその言語で読み直す。
  func testSwitchingTheLanguageRereadsTheVisibleRows() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    let header = { (language: Language) in
      L10n.string(.editorPrFiles, language) + ", "
        + L10n.format(.editorPrViewedCount, language, 0, 2)
    }
    let labels = { self.rowViews(in: hosted.list).compactMap { $0.accessibilityLabel() } }
    let before = hosted.pane.localization.language
    let after: Language = before == .ja ? .en : .ja
    pumpMain(until: { labels().contains(header(before)) }, "前提: 見出しの行が見えている")

    hosted.pane.localization.language = after
    pumpMain(until: { labels().contains(header(after)) }, "切り替えた言語で読み直す")
  }

  private func rowViews(in view: NSView) -> [PrRowView] {
    view.subviews.flatMap { ($0 as? PrRowView).map { [$0] } ?? rowViews(in: $0) }
  }

  /// ツリーかリストかがほかの面で選ばれても（アプリ全体の選択が変わる）、この面の行を組み直す。
  func testTheFilesViewChosenElsewhereRebuildsTheRows() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    XCTAssertNotNil(hosted.pane.pullRequest.layout.index[.folder("src")], "前提: ツリー")

    hosted.pane.sidebar.setPullRequestFilesAsTree(false)
    pumpMain(
      until: { hosted.pane.pullRequest.layout.index[.folder("src")] == nil }, "リストに組み直す")
    hosted.pane.sidebar.setPullRequestFilesAsTree(true)
    pumpMain(
      until: { hosted.pane.pullRequest.layout.index[.folder("src")] != nil }, "ツリーに組み直す")
  }
}
