import AppKit
import XCTest

@testable import Orbe

/// エディター面に結んだ PR のパネル——面が見えていれば、PR の画面を出していなくても今のブランチの PR を引く（中身は PR の画面を
/// 出してから読む）。上のバーで PR の画面を出したら、今の答えで行を組んでから、行があるときだけ列に焦点を入れる。列が
/// 消える・パネルを隠す・cd で根が変わるとき、列にあった焦点は面の本文へ戻り、当てる列の無い焦点の要求は残らない。cd で
/// 根が変わったら前の根の PR を見るのをやめる。ツリーかリストかをほかの面で選べば、この面の行も組み直し、言語を切り替え
/// れば見えている行を読み直す。全体へのコメント欄の ↵ は改行、⌘↵ はその欄に焦点がある間だけレビューの送信。GitHub は、面を
/// 作る前に登録した差し替えの出どころが答える。
///
/// 壊れると何が起きるか: PR の画面を一度出すまで、上のバーに PR の番号が出ない。見ているだけの面のために PR の中身と
/// スレッドを GitHub から読む。新しい面や cd の後に上のバーで PR の画面を出しても列に焦点が入らない。PR が無くなったのに残った
/// 焦点の要求が、後で PR が現れた瞬間に本文や端末から焦点を奪う。PR がマージされた・ブランチを替えたときに焦点が窓へ落ち、
/// 打鍵がどこにも届かない。cd の後も前の worktree の PR を GitHub に問い合わせ続ける。ほかの面でリストにしても、この面が
/// ツリーのまま。言語を切り替えても、見えている見出しが前の言語のまま。全体へのコメント欄の ⌘↵ で送れない・変換中の字が
/// 抜けた本文を送る・押し続けると何度も送る・欄の外の ⌘↵ でレビューを送る。↵ で改行できない。
@MainActor
final class PullRequestPaneTests: OrbeTestCase {
  struct Hosted {
    /// 連を生かしておく（面は連を弱く持つ）。
    let tab: TerminalTab
    let pane: EditorPaneView
    let window: NSWindow
    var list: NSView { pane.pullRequestList.list }
  }

  /// 根ごとの差し替えの出どころ。`open` が偽なら、ブランチに open の PR が無いと答える。レビューの送信は通し、届いた書き込みを
  /// `reviewWrites` に残す。
  final class FakeGitHub {
    var open = true
    var reviewWrites: [GitHubReviewWrite] = []
    /// PR の先頭のコミット（ベースも同じ）。手元のコミットにすると diff の両端が求まる。
    var head = "h"
    /// ブランチの open の PR の番号（替えると、worktree の今の PR が別の PR になる）。
    var number = 9
    private let me = GitHubRepoName(nameWithOwner: "me/r")

    var source: PullRequestSource {
      let ref = GitHubBranchRef(repo: me, branch: "feat")
      let content = { [head] (number: Int) in
        GitHubPullRequestContent(
          nodeID: "PR_\(number)", number: number, title: "題",
          url: "https://github.com/me/r/pull/\(number)", isDraft: false, state: .open, body: "",
          author: "me", baseRefName: "main", headRefName: "feat", baseCommit: head,
          headCommit: head, commitCount: 0, commits: [],
          files: ["src/a.swift", "b.swift"].map {
            .init(path: $0, change: .modified, isViewed: false)
          })
      }
      return PullRequestSource(
        branchPullRequests: { [unowned self] _, branch, completion in
          let pullRequest = GitHubBranchPR(
            number: number, headRefName: "feat", state: "OPEN", baseRefName: "main",
            headRepository: me, url: "https://github.com/me/r/pull/\(number)")
          completion(
            GitHubBranchPullRequests(
              ledger: nil,
              branches: [branch: .gitHub(ref, pullRequests: .success(open ? [pullRequest] : []))]))
        },
        branchExists: { _, completion in completion(.success(true)) },
        content: { id, completion in completion(.success(content(id.number))) },
        setViewed: { _, _, _, _ in },
        review: { [head] _, completion in
          completion(
            .success(
              GitHubPullRequestReview(
                viewerIsAuthor: false, headCommit: head, pendingReview: nil,
                threads: [])))
        },
        writeReview: { [unowned self] write, _, pending, _, completion in
          reviewWrites.append(write)
          completion(GitHubReviewWriteResult(pendingReview: pending, failure: nil))
        })
    }
  }

  var gitHub: FakeGitHub!

  override func setUpWithError() throws {
    gitHub = FakeGitHub()
  }

  /// ブランチ feat に居る一時リポジトリの根。面が作る PR のパネルが本物の gh を呼ばないよう、差し替えの出どころを先に
  /// 登録する。
  func registeredRoot() throws -> String {
    let repo = try TempGitRepo()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    gitHub.head = repo.head()
    let root = GitWorktreeRoot.root(of: repo.root)
    _ = BranchPullRequest.shared(for: root, source: gitHub.source)
    return root
  }

  /// 根 `root` の連の面だけを Files の画面で窓に載せ、本文に焦点を置く。
  func host(_ root: String) -> Hosted {
    let tab = TerminalTab.alone(cwd: root, editorSurfaces: EditorSurfaces(queriesRoot: nil))
    tab.group.editor.selectScreen(.files)
    let pane = tab.group.view.editor
    let window = OrbeWindowFake(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    addTeardownBlock {
      MainActor.assumeIsolated {
        pane.switchScreen(.files)
        window.orderOut(nil)
      }
    }
    window.makeFirstResponder(pane.focusTarget)
    return Hosted(tab: tab, pane: pane, window: window)
  }

  /// PR のパネルを出して、列に行が出るまで待つ。
  func shownWithRows(_ hosted: Hosted) {
    hosted.pane.switchScreen(.pullRequest)
    pumpMain(until: { !hosted.pane.pullRequest.layout.items.isEmpty }, "前提: 列に行が出る")
    pumpMain(until: { hosted.list.window != nil }, "前提: 列が窓に載る")
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }

  /// PR を読んである根の新しい面で上のバーから出せば、列に焦点が入る。PR が無ければ焦点を求めない。
  func testTheRailFocusesTheListOnlyWhenThereAreRows() throws {
    let root = try registeredRoot()
    shownWithRows(host(root))

    let other = host(root)
    other.pane.switchScreen(.pullRequest)
    pumpMain(until: { other.window.firstResponder === other.list }, "新しい面でも列に焦点")

    gitHub.open = false
    let empty = host(try registeredRoot())
    empty.pane.switchScreen(.pullRequest)
    XCTAssertFalse(empty.pane.pullRequest.focusRequest, "行が無ければ求めない")
  }

  /// 面が見えていれば、PR の画面を一度も出していなくても今のブランチの PR を引く（上のバーの番号が出る）。中身は PR の画面を
  /// 出すまで読まない。
  func testAShownPaneTracksThePullRequestWithoutReadingItsContentUntilThePullRequestScreen() throws
  {
    let hosted = host(try registeredRoot())
    pumpMain(
      until: { hosted.pane.pullRequest.state?.key.id.number == self.gitHub.number },
      "Files の画面のままでも今の PR が分かる")
    let state = try XCTUnwrap(hosted.pane.pullRequest.state)
    XCTAssertFalse(state.isWatched, "PR の画面を出すまで中身は読まない")

    hosted.pane.switchScreen(.pullRequest)
    XCTAssertTrue(state.isWatched, "PR の画面を出せば中身を読む")
  }

  /// 行がある状態で隠し、PR が無くなってから出し直したら、当てる列の無い焦点の要求は残らない——後で PR が現れても、本文の
  /// 焦点を奪わない。
  func testAFocusRequestForRowsThatGoAwayIsNotLeftBehind() throws {
    let hosted = host(try registeredRoot())
    shownWithRows(hosted)
    hosted.pane.switchScreen(.files)
    pumpMain(until: { hosted.window.firstResponder === hosted.pane.focusTarget }, "前提: 本文")

    gitHub.open = false
    hosted.pane.pullRequest.refresh()
    pumpMain(until: { hosted.pane.pullRequest.layout.items.isEmpty }, "PR が無いと分かる")
    hosted.pane.switchScreen(.pullRequest)
    XCTAssertFalse(hosted.pane.pullRequest.focusRequest, "当てる列の無い要求は捨てる")
    settle()
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "本文のまま")

    gitHub.open = true
    hosted.pane.pullRequest.refresh()
    pumpMain(until: { hosted.list.window != nil }, "PR が現れる")
    settle()
    XCTAssertTrue(hosted.window.firstResponder === hosted.pane.focusTarget, "現れても焦点を奪わない")
  }

  /// 焦点を置くパネルの中の場所。
  private enum Area: CaseIterable {
    case list
    case reviewField
  }

  /// 出したパネルの `area` に焦点を入れる。
  private func focus(_ area: Area, in hosted: Hosted) throws {
    switch area {
    case .list: hosted.window.makeFirstResponder(hosted.list)
    case .reviewField:
      pumpMain(until: { self.messageField(in: hosted.pane) != nil }, "前提: 全体へのコメント欄")
      hosted.window.makeFirstResponder(try XCTUnwrap(messageField(in: hosted.pane)))
    }
  }

  /// 列か全体へのコメント欄に焦点がある間に、パネルを出したまま PR が無くなる場合と、パネルを隠す場合のどちらでも、焦点は面の
  /// 本文へ戻る（窓へ落ちない）。
  func testTheFocusInThePanelReturnsToTheBodyWhenThePanelGoesAwayOrHides() throws {
    for area in Area.allCases {
      gitHub.open = true
      let hosted = host(try registeredRoot())
      shownWithRows(hosted)
      try focus(area, in: hosted)

      gitHub.open = false
      hosted.pane.pullRequest.refresh()
      pumpMain(
        until: { hosted.window.firstResponder === hosted.pane.focusTarget },
        "\(area) にあった焦点は、PR が消えたら本文へ")

      gitHub.open = true
      hosted.pane.pullRequest.refresh()
      pumpMain(until: { hosted.list.window != nil }, "前提: PR が戻る")
      try focus(area, in: hosted)
      hosted.pane.switchScreen(.files)
      pumpMain(
        until: { hosted.window.firstResponder === hosted.pane.focusTarget },
        "\(area) にあった焦点は、隠したら本文へ")
    }
  }

  /// cd で根が変われば、前の根の PR を見るのをやめ、列か全体へのコメント欄にあった焦点は本文へ戻り、新しい根の PR を見る。
  func testChangingTheRootStopsWatchingThePreviousPullRequest() throws {
    for area in Area.allCases {
      let hosted = host(try registeredRoot())
      shownWithRows(hosted)
      let previous = try XCTUnwrap(hosted.pane.pullRequest.state)
      try focus(area, in: hosted)

      let next = try registeredRoot()
      hosted.tab.group.rekey(next)
      XCTAssertFalse(previous.isWatched, "前の根の PR を見るのをやめる")
      pumpMain(until: { hosted.pane.pullRequest.state != nil }, "新しい根の PR を見る")
      XCTAssertEqual(hosted.pane.pullRequest.root, next)
      XCTAssertTrue(try XCTUnwrap(hosted.pane.pullRequest.state).isWatched)
      settle()
      XCTAssertTrue(
        hosted.window.firstResponder === hosted.pane.focusTarget, "\(area) にあった焦点は本文へ")
    }
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

  // MARK: - 全体へのコメント欄

  /// PR のパネルを出して、全体へのコメント欄に焦点を入れる。
  private func reviewField(_ hosted: Hosted) throws -> MessageTextView {
    shownWithRows(hosted)
    pumpMain(
      until: {
        self.messageField(in: hosted.pane) != nil
          && hosted.pane.pullRequest.state?.diffEnds != nil
      }, "前提: 全体へのコメント欄と diff の両端")
    let field = try XCTUnwrap(messageField(in: hosted.pane))
    hosted.window.makeFirstResponder(field)
    XCTAssertTrue(hosted.pane.pullRequest.isReviewFieldFocused, "前提: 欄に焦点")
    return field
  }

  private func messageField(in view: NSView) -> MessageTextView? {
    (view as? MessageTextView) ?? view.subviews.lazy.compactMap(messageField(in:)).first
  }

  /// 欄の ↵ は改行で、⌘↵ は見えている字（変換中の字を含む）をそのまま全体へのコメントにして送り、通れば欄が空になる。
  func testCommandReturnInTheReviewFieldSendsTheVisibleText() throws {
    let hosted = host(try registeredRoot())
    let field = try reviewField(hosted)
    field.insertText("見ました", replacementRange: NSRange(location: NSNotFound, length: 0))
    field.keyDown(with: .key("\r", []))
    XCTAssertEqual(field.string, "見ました\n", "↵ は改行")
    field.setMarkedText(
      "かくにん", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(gitHub.reviewWrites.isEmpty, "前提: まだ送っていない")

    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("\r")))
    XCTAssertEqual(gitHub.reviewWrites, [.submit(.comment, body: "見ました\nかくにん")])
    pumpMain(until: { field.string.isEmpty }, "通れば欄が空になる")
  }

  /// 変換中の字だけがある欄でも送れる姿になり、変換を取り消せば送れない姿に戻る。IME が確定すれば字は書きかけへ移り、その後の
  /// 姿は書きかけだけで決まる（終わった変換の字のせいで送れる姿のままになることはない）。
  func testOnlyAComposingTextMakesTheReviewSubmittable() throws {
    let hosted = host(try registeredRoot())
    let field = try reviewField(hosted)
    let panel = hosted.pane.pullRequest
    let compose = { (text: String) in
      field.setMarkedText(
        text, selectedRange: NSRange(location: text.utf16.count, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    XCTAssertFalse(panel.canSubmitReview, "前提: 空の欄")

    compose("けんとう")
    XCTAssertTrue(panel.canSubmitReview)
    compose("")
    XCTAssertFalse(panel.canSubmitReview, "変換を取り消した")

    compose("けんとう")
    field.insertText("検討", replacementRange: NSRange(location: NSNotFound, length: 0))
    pumpMain(until: { panel.state?.reviewDraft.body == "検討" }, "IME の確定が書きかけへ入る")
    panel.state?.reviewDraft.body = ""
    XCTAssertFalse(panel.canSubmitReview, "確定した後は、終わった変換の字のせいで送れる姿のままになることはない")
  }

  /// 全体へのコメント欄で変換中のまま worktree の今の PR が替わると、変換中の字は前の PR の書きかけへ確定し、次の PR の欄は
  /// 空のまま、焦点は面の本文へ移る。
  func testSwitchingThePullRequestWhileComposingLeavesTheTextWithThePreviousOne() throws {
    let hosted = host(try registeredRoot())
    let field = try reviewField(hosted)
    let panel = hosted.pane.pullRequest
    let previous = try XCTUnwrap(panel.state)
    field.insertText("前の", replacementRange: NSRange(location: NSNotFound, length: 0))
    field.setMarkedText(
      "かきかけ", selectedRange: NSRange(location: 4, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))

    gitHub.number = 10
    panel.refresh()
    pumpMain(
      until: { panel.state.map { $0 !== previous && $0.review != nil } ?? false }, "次の PR を見る")
    XCTAssertEqual(previous.reviewDraft.body, "前のかきかけ")
    XCTAssertEqual(panel.state?.reviewDraft.body, "")
    XCTAssertEqual(panel.reviewComposition, "")
    pumpMain(
      until: { hosted.window.firstResponder === hosted.pane.focusTarget }, "焦点は面の本文へ")
  }

  /// ⌘↵ が送るのは全体へのコメント欄に焦点がある間の 1 回だけ——送れない間と押し続けた繰り返しは食って送らず、焦点が欄の外
  /// なら扱わない。
  func testCommandReturnSendsOnlyOnceAndOnlyFromTheReviewField() throws {
    let hosted = host(try registeredRoot())
    let field = try reviewField(hosted)
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("\r")), "空の欄では送れず、食う")
    field.insertText("見ました", replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("\r", isRepeat: true)))
    XCTAssertTrue(gitHub.reviewWrites.isEmpty, "送れない間と繰り返しは送らない")

    hosted.window.makeFirstResponder(hosted.list)
    XCTAssertFalse(hosted.pane.performKeyEquivalent(with: .key("\r")))
    XCTAssertTrue(gitHub.reviewWrites.isEmpty, "欄の外の ⌘↵ は送らない")
  }
}
