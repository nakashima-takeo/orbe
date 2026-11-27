import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの層——スレッドが付いた行の下に置き、行の右端の印から新しいコメントの欄を開き、書き込みの結果で欄を
/// 空にするか本文を残す。PR の中身とレビューのやりとりは差し替えの構造体が答える。
///
/// 壊れると何が起きるか: スレッドが別の行の下に出る。印を押しても欄が開かない・焦点が入らない・⌘↵ で書けない。書いた行と
/// 違う行にコメントが付く（古い側の行の印から新しい側の行へ書く・rename の判定が GitHub と食い違うファイルの古い側の行に
/// 印やスレッドが出る）。2 回押すと同じコメントが 2 つ付く。
/// 失敗した書き込みで書きかけが消える。通った後も欄が残る。空の欄が開いたまま残る。
/// 同じ行の両側のスレッドが時刻の順に並ばない。消えたスレッドの絵の差し込みが層に残り続ける。
extension EditorDiffTests {
  /// 差し替えの GitHub のレビューのやりとり（テストが書き換える）と、届いた書き込み。
  final class Remote {
    var head = ""
    var content: GitHubPullRequestContent?
    var threads: [GitHubPullRequestReview.Thread] = []
    var writes: [GitHubReviewWrite] = []
    var failure: GitHubFailure?
    /// 真なら書き込みの答えを返さずに `held` に溜める（書き込みの最中を作る）。
    var holds = false
    var held: [() -> Void] = []
    /// 真ならレビューのやりとりの読みの答えを返さずに `heldReviews` に溜める（答えは返す時点の `head` と `threads` で作る）。
    var holdsReviews = false
    var heldReviews: [() -> Void] = []
  }

  /// PR の diff を開く。PR のコミットは `edit`（無ければ a.txt の行 3 を変える）で作り、GitHub はファイル `path` を `change`
  /// と答える。窓の幅は `width`（→ `tab(width:)`）。
  func commentedDiff(
    _ remote: Remote, path: String = "a.txt",
    change: GitHubPullRequestContent.Change = .modified, width: CGFloat = 900,
    edit: (() throws -> Void)? = nil
  ) throws -> (EditorDiff, MetalTextSurface) {
    let opened = try commentedTab(remote, path: path, change: change, width: width, edit: edit)
    return (opened.diff, try engine(opened.diff.newSurface))
  }

  /// `commentedDiff` と同じ PR の diff を開き、そのタブも返す。
  func commentedTab(
    _ remote: Remote, path: String = "a.txt",
    change: GitHubPullRequestContent.Change = .modified, width: CGFloat = 900,
    edit: (() throws -> Void)? = nil
  ) throws -> (diff: EditorDiff, tab: TerminalTab) {
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try (edit ?? { try self.repo.write("a.txt", "one\ntwo\nTHREE\nfour\n") })()
    XCTAssertTrue(repo.git(["commit", "-qam", "change"]).isSuccess)
    let head = repo.head()
    remote.head = head
    remote.content = GitHubPullRequestContent(
      nodeID: "PR_7", number: 7, title: "題", url: "https://github.com/me/r/pull/7", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: head, commitCount: 1, commits: [],
      files: [.init(path: path, change: change, isViewed: false)])
    let me = GitHubRepoName(nameWithOwner: "me/r")
    let state = PullRequestState.shared(
      for: PullRequestState.Key(
        commonDir: try repo.open().commonDir,
        id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 7))
      ),
      source: PullRequestSource(
        // 根の worktree（ブランチ feat）の今の PR は、この PR。
        branchPullRequests: { _, branch, completion in
          let pullRequest = GitHubBranchPR(
            number: 7, headRefName: "feat", state: "OPEN", baseRefName: "main",
            headRepository: me, url: "https://github.com/me/r/pull/7")
          completion(
            GitHubBranchPullRequests(
              ledger: nil,
              branches: [
                branch: .gitHub(
                  GitHubBranchRef(repo: me, branch: branch), pullRequests: .success([pullRequest]))
              ]))
        },
        branchExists: { _, _ in },
        content: { _, completion in
          completion(remote.content.map { .success($0) } ?? .failure(.reason("")))
        },
        setViewed: { _, _, _, _ in },
        review: { _, completion in
          let answer = {
            completion(
              .success(
                GitHubPullRequestReview(
                  viewerIsAuthor: false, headCommit: remote.head, pendingReview: nil,
                  threads: remote.threads)))
          }
          if remote.holdsReviews { remote.heldReviews.append(answer) } else { answer() }
        },
        writeReview: { write, _, pending, _, completion in
          remote.writes.append(write)
          let answer = {
            completion(GitHubReviewWriteResult(pendingReview: pending, failure: remote.failure))
          }
          if remote.holds { remote.held.append(answer) } else { answer() }
        }))
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    // 面が作る PR のパネルより先に、根の worktree の今の PR を差し替えの出どころで登録する（本物の gh を呼ばない）。
    _ = BranchPullRequest.shared(for: repo.root, source: state.source)
    return try open(state, path: path, width: width)
  }

  /// PR の状態 `state` のファイル `path` の diff を、タブ `into`（無ければ新しいタブ）の PR の画面で開く。
  func open(
    _ state: PullRequestState, path: String = "a.txt", width: CGFloat = 900,
    into: TerminalTab? = nil
  ) throws -> (diff: EditorDiff, tab: TerminalTab) {
    let tab = into ?? tab(width: width).0
    let diff = try tab.group.editor.openDiff(id(path, .pullRequest(state)))
    tab.group.editor.selectScreen(.pullRequest)
    pumpMain(
      until: {
        diff.content == .ready && diff.comments?.isSettled == true && diff.newSurface != nil
          && diff.comments?.isCurrentPullRequest == true
      },
      "PR の diff と印を出せる行が揃い、PR が根の worktree の今の PR と分かる")
    return (diff, tab)
  }

  /// diff の PR が diff の根の worktree の今の PR でなくなったら（ブランチを切り替えた後）、新しいスレッドを書かずに、送れる所を
  /// 告げる（積んでも、Orbe から送る所が無い）。
  func testAPullRequestThatIsNoLongerTheWorktreesDoesNotTakeNewComments() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(3), to: .document(3))
    let draft = try XCTUnwrap(layer.draft(at: .at(.new, 3)))
    surface.replaceText(of: draft.field, with: "書きかけ")
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    pumpMain(until: { !layer.isCurrentPullRequest }, "前提: ブランチを切り替えると今の PR でなくなる")

    draft.zone(.pressed(PrCommentControl.add))
    XCTAssertEqual(remote.writes, [])
    XCTAssertTrue(
      [Language.ja, .en].map { L10n.string(.editorPrThreadNotCurrent, $0) }.contains(draft.failure),
      "送れる所を告げる")
    XCTAssertEqual(draft.text, "書きかけ")
  }

  /// 新しい側の行 3 のスレッドは文書の行 3 の下に置かれ、その行の地はスレッドのある行の型になる。変更の前後 3 行は印を出せ、
  /// 本文の末尾の改行の後の空の行（GitHub の diff の行ではない）は出せない。
  func testAThreadSitsUnderItsLineAndCommentableLinesCarryTheMark() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", lines: .at(.new, 3), isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [
          .init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: true)
        ])
    ]
    let (diff, surface) = try commentedDiff(remote)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    XCTAssertEqual(surface.rows.style(ofLine: 2), DiffStyle.added)
    XCTAssertEqual(surface.rows.lineSpan(ofLine: 2)?.override, DiffStyle.threadOverride)
    let spans = surface.rows.spans
    XCTAssertTrue(
      spans.filter { $0.line < 4 }.allSatisfy { $0.markGroup != nil }, "4 行は全部が区間の前後 3 行に入る")
    XCTAssertEqual(
      spans.last { $0.line <= 4 }?.markGroup, nil, "改行の後の空の行は GitHub の diff に無い")
  }

  /// 文脈の行の古い側と新しい側に付いたスレッドは同じ所に並び、側を問わず最初のコメントの時刻の順に上から置く。
  func testThreadsOnBothSidesOfOneLineFollowTheirFirstCommentTime() throws {
    let remote = Remote()
    let thread = { (id: String, side: GitHubDiffSide, time: TimeInterval) in
      GitHubPullRequestReview.Thread(
        id: id, path: "a.txt", lines: .at(side, 1), isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [
          .init(
            id: "C_\(id)", author: "you", body: id, createdAt: Date(timeIntervalSince1970: time),
            isPending: false)
        ])
    }
    remote.threads = [thread("OLD", .old, 200), thread("NEW", .new, 100)]
    let (diff, surface) = try commentedDiff(remote)
    let old = try XCTUnwrap(diff.comments?.zone(thread: "OLD"))
    let new = try XCTUnwrap(diff.comments?.zone(thread: "NEW"))
    pumpMain(
      until: {
        surface.rows.block(ofZone: ObjectIdentifier(old)) != nil
          && surface.rows.block(ofZone: ObjectIdentifier(new)) != nil
      }, "両方のスレッドが置かれる")
    XCTAssertLessThan(
      try XCTUnwrap(surface.rows.block(ofZone: ObjectIdentifier(new))),
      try XCTUnwrap(surface.rows.block(ofZone: ObjectIdentifier(old))), "先に書かれた新しい側のスレッドが上")
  }

  /// 読み直しでレビューのやりとりから消えたスレッドは、層からも消える。
  func testAThreadGoneFromTheReviewLeavesTheLayer() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", lines: .at(.new, 3), isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    ]
    let (diff, _) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    XCTAssertNotNil(layer.zone(thread: "T"))
    remote.threads = []
    layer.state.reload()
    pumpMain(until: { layer.zone(thread: "T") == nil }, "消えたスレッドの絵の差し込みを手放す")
  }

  /// 印を押すとその行の下に新しいコメントの欄が開いて主になり、欄の ⌘↵ でその側と行（1 始まり）・diff の先頭のコミットの
  /// スレッドを書く。通れば欄は閉じる。
  func testTheMarkOpensADraftThatWritesAThreadOnItsLine() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let window = try XCTUnwrap(surface.textView.window)
    window.makeFirstResponder(surface.textView)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    let draft = try XCTUnwrap(layer.draft(at: .at(.new, 1)))
    XCTAssertEqual(surface.primary, .field(draft.field.id), "欄に焦点が入る")
    surface.replaceText(of: draft.field, with: "直す")
    XCTAssertTrue(window.performKeyEquivalent(with: .key("\r")))
    pumpMain(until: { layer.draft(at: .at(.new, 1)) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [.addThread(path: "a.txt", lines: .at(.new, 2), commit: remote.head, body: "直す")])
  }

  /// 古い側の行の印——インラインで差し込まれた削除行と、並列の左の面の行——は、古い側のその行に欄を開き、古い側の行（1 始まり）
  /// へ書く。
  func testOldSideMarksWriteToTheOldSideLine() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let window = try XCTUnwrap(surface.textView.window)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .source(2), to: .source(2))
    let draft = try XCTUnwrap(layer.draft(at: .at(.old, 2)), "削除行「three」の下に開く")
    surface.replaceText(of: draft.field, with: "消した行")
    draft.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { layer.draft(at: .at(.old, 2)) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [.addThread(path: "a.txt", lines: .at(.old, 3), commit: remote.head, body: "消した行")])

    resize(window, width: Self.sideWidth)
    pumpMain(until: { diff.oldSurface != nil && layer.isSettled }, "並列の 2 面が揃う")
    layer.surface(try engine(diff.oldSurface), didMarkFrom: .document(1), to: .document(1))
    XCTAssertNotNil(layer.draft(at: .at(.old, 1)), "左の面の行は古い側の行")
    XCTAssertNil(layer.draft(at: .at(.new, 1)))
  }

  /// 書き込みが通らなければ、欄は開いたまま本文が残り、失敗の文が出る。
  func testAFailedWriteKeepsTheDraftAndShowsTheFailure() throws {
    let remote = Remote()
    remote.failure = .unreachable
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(0), to: .document(0))
    let draft = try XCTUnwrap(layer.draft(at: .at(.new, 0)))
    surface.replaceText(of: draft.field, with: "残る")
    draft.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { draft.failure != nil }, "失敗が届く")
    XCTAssertIdentical(layer.draft(at: .at(.new, 0)), draft)
    XCTAssertEqual(draft.text, "残る")
    XCTAssertFalse(draft.isWriting)
  }

  /// 空の欄（空白と改行だけの欄も空とみなす）から焦点が外れたら欄は閉じ、本文がある欄は焦点が外れても開いたまま。
  func testAnEmptyDraftClosesWhenItLosesFocus() throws {
    let (diff, surface) = try commentedDiff(Remote())
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(0), to: .document(0))
    surface.replaceText(of: try XCTUnwrap(layer.draft(at: .at(.new, 0))).field, with: " \n")
    surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertNil(layer.draft(at: .at(.new, 0)), "空白と改行だけの欄は閉じる")
    layer.surface(surface, didMarkFrom: .document(0), to: .document(0))
    let draft = try XCTUnwrap(layer.draft(at: .at(.new, 0)))
    surface.replaceText(of: draft.field, with: "書きかけ")
    surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertIdentical(layer.draft(at: .at(.new, 0)), draft, "本文のある欄は残る")
  }

  /// 返信欄の空白と改行だけの本文は空とみなす——「レビューに追加」は書かず、「解決して返信」は解決だけを書く。
  func testABlankReplyCountsAsEmpty() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", lines: .at(.new, 3), isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    ]
    let (diff, _) = try commentedDiff(remote)
    let thread = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { thread.surface != nil }, "スレッドが置かれる")
    try XCTUnwrap(thread.surface).replaceText(of: thread.field, with: " \n")
    thread.zone(.pressed(PrCommentControl.add))
    thread.zone(.pressed(PrCommentControl.resolveReply))
    pumpMain(until: { !remote.writes.isEmpty }, "解決が届く")
    XCTAssertEqual(remote.writes, [.setResolved(thread: "T", true)])
  }

  /// rename の判定が GitHub と手元で食い違うファイルでは、古い側の行（削除行）に印もスレッドも出さない。新しい側の行には
  /// 出す。
  func testARenameGitHubDoesNotSeeKeepsMarksAndThreadsOffTheOldSide() throws {
    let remote = Remote()
    remote.threads = [GitHubDiffSide.old, .new].map { side in
      GitHubPullRequestReview.Thread(
        id: "T_\(side)", path: "b.txt", lines: .at(side, 3), isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [
          .init(id: "C_\(side)", author: "you", body: "本文", createdAt: Date(), isPending: false)
        ])
    }
    let (diff, surface) = try commentedDiff(remote, path: "b.txt", change: .modified) {
      XCTAssertTrue(self.repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
      try self.repo.write("b.txt", "one\ntwo\nTHREE\nfour\n")
    }
    let layer = try XCTUnwrap(diff.comments)
    XCTAssertEqual(layer.path, "b.txt")
    pumpMain(until: { layer.zone(thread: "T_new") != nil }, "新しい側のスレッドは置く")
    XCTAssertNil(layer.zone(thread: "T_old"))
    let removed = surface.rows.contents.flatMap { content -> [InsertedLine] in
      if case .lines(let lines) = content { lines } else { [] }
    }
    XCTAssertFalse(removed.isEmpty, "前提: 手元は rename として削除行を出す")
    XCTAssertFalse(removed.contains { $0.markGroup != nil })
    XCTAssertTrue(surface.rows.spans.contains { $0.markGroup != nil })
  }

  /// 新しいスレッドの書き込みの最中は欄が書き込みの最中の姿で、「レビューに追加」を 2 回押しても書き込みは 1 回。
  func testPressingAddTwiceWhileWritingWritesOneThread() throws {
    let remote = Remote()
    remote.holds = true
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    let draft = try XCTUnwrap(layer.draft(at: .at(.new, 1)))
    surface.replaceText(of: draft.field, with: "一度だけ")
    draft.zone(.pressed(PrCommentControl.add))
    XCTAssertTrue(draft.isWriting)
    draft.zone(.pressed(PrCommentControl.add))

    remote.holds = false
    while !remote.held.isEmpty { remote.held.removeFirst()() }
    pumpMain(until: { layer.draft(at: .at(.new, 1)) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(remote.writes.count, 1)
  }
}

extension GitHubPullRequestContent {
  /// 先頭のコミットだけを `head` に替えた中身（PR への push）。
  func withHead(_ head: String) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: nodeID, number: number, title: title, url: url, isDraft: isDraft, state: state,
      body: body, author: author, baseRefName: baseRefName, headRefName: headRefName,
      baseCommit: baseCommit, headCommit: head, commitCount: commitCount + 1, commits: commits,
      files: files)
  }
}
