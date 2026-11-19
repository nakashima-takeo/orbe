import OrbeEditorCore
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの層——スレッドが付いた行の下に置き、行の右端の印から新しいコメントの欄を開き、書き込みの結果で欄を
/// 空にするか本文を残す。PR の中身とレビューのやりとりは差し替えの構造体が答える。
///
/// 壊れると何が起きるか: スレッドが別の行の下に出る。印を押しても欄が開かない・焦点が入らない・⌘↵ で書けない。書いた行と
/// 違う行にコメントが付く（rename の判定が GitHub と食い違うファイルの古い側の行を含む）。2 回押すと同じコメントが 2 つ付く。
/// 失敗した書き込みで書きかけが消える。通った後も欄が残る。空の欄が開いたまま残る。同じ PR の別のタブの書きかけが消える。同じ行の両側のスレッドが時刻の順に並ばない。消えたスレッドの絵の差し込みが層に残り続ける。PR に
/// push があると書きかけが消える・欄が元の行の番号のまま別の行の下に残る・書き換えられた行へのコメントを古い行の番号で送れる。
extension EditorDiffTests {
  /// 差し替えの GitHub のレビューのやりとり（テストが書き換える）と、届いた書き込み。
  private final class Remote {
    var head = ""
    var content: GitHubPullRequestContent?
    var threads: [GitHubPullRequestReview.Thread] = []
    var writes: [GitHubReviewWrite] = []
    var failure: GitHubFailure?
    /// 真なら書き込みの答えを返さずに `held` に溜める（書き込みの最中を作る）。
    var holds = false
    var held: [() -> Void] = []
  }

  /// PR の diff を開く。PR のコミットは `edit`（無ければ a.txt の行 3 を変える）で、GitHub はファイル `path` を `change`
  /// と答える。
  private func commentedDiff(
    _ remote: Remote, path: String = "a.txt",
    change: GitHubPullRequestContent.Change = .modified, edit: (() throws -> Void)? = nil
  ) throws -> (EditorDiff, MetalTextSurface) {
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try (edit ?? { try self.repo.write("a.txt", "one\ntwo\nTHREE\nfour\n") })()
    XCTAssertTrue(repo.git(["commit", "-qam", "change"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    remote.head = head
    remote.content = GitHubPullRequestContent(
      nodeID: "PR_7", number: 7, title: "題", url: "https://github.com/me/r/pull/7", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: head, commitCount: 1, commits: [],
      files: [.init(path: path, change: change, isViewed: false)])
    let state = PullRequestState.shared(
      for: PullRequestState.Key(
        commonDir: repo.root + "/.git", id: try XCTUnwrap(GitHubItemID(repo: "me/r", number: 7))),
      source: PullRequestSource(
        branchPullRequests: { _, _, _ in }, branchExists: { _, _ in },
        content: { _, completion in
          completion(remote.content.map { .success($0) } ?? .failure(.reason("")))
        },
        setViewed: { _, _, _, _ in },
        review: { _, completion in
          completion(
            .success(
              GitHubPullRequestReview(
                viewer: "me", viewerIsAuthor: false, headCommit: remote.head, pendingReview: nil,
                threads: remote.threads)))
        },
        writeReview: { write, _, pending, _, completion in
          remote.writes.append(write)
          let answer = {
            completion(GitHubReviewWriteResult(pendingReview: pending, failure: remote.failure))
          }
          if remote.holds { remote.held.append(answer) } else { answer() }
        }))
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    return try open(state, path: path)
  }

  /// PR の状態 `state` のファイル `path` の diff を、新しいタブで開く。
  private func open(_ state: PullRequestState, path: String = "a.txt") throws -> (
    EditorDiff, MetalTextSurface
  ) {
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id(path, .pullRequest(state)), as: .pinned)
    pumpMain(
      until: {
        diff.content == .ready && diff.comments?.isSettled == true && diff.newSurface != nil
      },
      "PR の diff と印を出せる行が揃う")
    return (diff, try engine(diff.newSurface))
  }

  /// 新しい側の行 3 のスレッドは文書の行 3 の下に置かれ、その行の地はスレッドのある行の型になる。変更の前後 3 行は印を出せ、
  /// 本文の末尾の改行の後の空の行（GitHub の diff の行ではない）は出せない。
  func testAThreadSitsUnderItsLineAndCommentableLinesCarryTheMark() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .new, line: 3, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [
          .init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: true)
        ])
    ]
    let (diff, surface) = try commentedDiff(remote)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    XCTAssertEqual(surface.rows.style(ofLine: 2), DiffStyle.addedThread)
    let spans = surface.rows.spans
    XCTAssertTrue(
      spans.filter { $0.line < 4 }.allSatisfy(\.allowsTrailingMark), "4 行は全部が区間の前後 3 行に入る")
    XCTAssertEqual(
      spans.last { $0.line <= 4 }?.allowsTrailingMark, false, "改行の後の空の行は GitHub の diff に無い")
  }

  /// 文脈の行の古い側と新しい側に付いたスレッドは同じ所に並び、側を問わず最初のコメントの時刻の順に上から置く。
  func testThreadsOnBothSidesOfOneLineFollowTheirFirstCommentTime() throws {
    let remote = Remote()
    let thread = { (id: String, side: GitHubDiffSide, time: TimeInterval) in
      GitHubPullRequestReview.Thread(
        id: id, path: "a.txt", side: side, line: 1, isResolved: false, canReply: true,
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
        id: "T", path: "a.txt", side: .new, line: 3, isResolved: false, canReply: true,
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
    layer.surface(surface, didPressTrailingMarkOn: .document(1))
    let draft = try XCTUnwrap(layer.draft(.new, line: 1))
    XCTAssertEqual(surface.primary, .field(draft.field.id), "欄に焦点が入る")
    surface.replaceText(of: draft.field, with: "直す")
    XCTAssertTrue(window.performKeyEquivalent(with: .key("\r")))
    pumpMain(until: { layer.draft(.new, line: 1) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [.addThread(path: "a.txt", side: .new, line: 2, commit: remote.head, body: "直す")])
  }

  /// 書き込みが通らなければ、欄は開いたまま本文が残り、失敗の文が出る。
  func testAFailedWriteKeepsTheDraftAndShowsTheFailure() throws {
    let remote = Remote()
    remote.failure = .unreachable
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didPressTrailingMarkOn: .document(0))
    let draft = try XCTUnwrap(layer.draft(.new, line: 0))
    surface.replaceText(of: draft.field, with: "残る")
    draft.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { draft.failure != nil }, "失敗が届く")
    XCTAssertIdentical(layer.draft(.new, line: 0), draft)
    XCTAssertEqual(draft.text, "残る")
    XCTAssertFalse(draft.isWriting)
  }

  /// 空の欄から焦点が外れたら欄は閉じ、本文がある欄は焦点が外れても開いたまま。
  func testAnEmptyDraftClosesWhenItLosesFocus() throws {
    let (diff, surface) = try commentedDiff(Remote())
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didPressTrailingMarkOn: .document(0))
    surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertNil(layer.draft(.new, line: 0), "空の欄は閉じる")
    layer.surface(surface, didPressTrailingMarkOn: .document(0))
    let draft = try XCTUnwrap(layer.draft(.new, line: 0))
    surface.replaceText(of: draft.field, with: "書きかけ")
    surface.selectedRange = NSRange(location: 0, length: 0)
    XCTAssertIdentical(layer.draft(.new, line: 0), draft, "本文のある欄は残る")
  }

  /// rename の判定が GitHub と手元で食い違うファイルでは、古い側の行（削除行）に印を出さない。新しい側の行には出す。
  func testARenameGitHubDoesNotSeeKeepsMarksOffTheOldSide() throws {
    let (diff, surface) = try commentedDiff(Remote(), path: "b.txt", change: .modified) {
      XCTAssertTrue(self.repo.git(["mv", "a.txt", "b.txt"]).isSuccess)
      try self.repo.write("b.txt", "one\ntwo\nTHREE\nfour\n")
    }
    XCTAssertEqual(diff.comments?.path, "b.txt")
    let removed = surface.rows.contents.flatMap { content -> [InsertedLine] in
      if case .lines(let lines) = content { lines } else { [] }
    }
    XCTAssertFalse(removed.isEmpty, "前提: 手元は rename として削除行を出す")
    XCTAssertFalse(removed.contains(where: \.allowsTrailingMark))
    XCTAssertTrue(surface.rows.spans.contains(where: \.allowsTrailingMark))
  }

  /// 新しいスレッドの書き込みの最中は欄が書き込みの最中の姿で、「レビューに追加」を 2 回押しても書き込みは 1 回。
  func testPressingAddTwiceWhileWritingWritesOneThread() throws {
    let remote = Remote()
    remote.holds = true
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didPressTrailingMarkOn: .document(1))
    let draft = try XCTUnwrap(layer.draft(.new, line: 1))
    surface.replaceText(of: draft.field, with: "一度だけ")
    draft.zone(.pressed(PrCommentControl.add))
    XCTAssertTrue(draft.isWriting)
    draft.zone(.pressed(PrCommentControl.add))

    remote.holds = false
    while !remote.held.isEmpty { remote.held.removeFirst()() }
    pumpMain(until: { layer.draft(.new, line: 1) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(remote.writes.count, 1)
  }

  /// 同じ PR の diff を 2 つのタブで開いても、片方のタブの返信が通って欄が空になる・失敗の文が出るのはそのタブだけで、
  /// もう片方の書きかけは変わらない。
  func testTwoTabsOfOnePullRequestKeepTheirOwnReplyDrafts() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .new, line: 3, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    ]
    let (first, _) = try commentedDiff(remote)
    let (second, _) = try open(try XCTUnwrap(first.comments).state)
    let mine = try XCTUnwrap(first.comments?.zone(thread: "T"))
    let other = try XCTUnwrap(second.comments?.zone(thread: "T"))
    pumpMain(until: { mine.surface != nil && other.surface != nil }, "両方のタブにスレッドが置かれる")
    other.surface?.replaceText(of: other.field, with: "別のタブの書きかけ")

    mine.surface?.replaceText(of: mine.field, with: "通る返信")
    mine.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { mine.text.isEmpty }, "通れば欄が空になる")
    XCTAssertEqual(other.text, "別のタブの書きかけ")

    remote.failure = .unreachable
    mine.surface?.replaceText(of: mine.field, with: "通らない返信")
    mine.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { mine.failure != nil }, "失敗が届く")
    XCTAssertNil(other.failure)
    XCTAssertEqual(other.text, "別のタブの書きかけ")
  }

  /// PR の feat に a.txt を `text` にするコミットを足し、PR の状態を読み直して、diff が新しい先頭の版を見せ終えるのを待つ。
  private func push(_ text: String, _ remote: Remote, _ diff: EditorDiff) throws {
    XCTAssertTrue(repo.git(["switch", "-q", "feat"]).isSuccess)
    try repo.write("a.txt", text)
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    remote.head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    let content = try XCTUnwrap(remote.content)
    remote.content = GitHubPullRequestContent(
      nodeID: content.nodeID, number: content.number, title: content.title, url: content.url,
      isDraft: false, state: .open, body: "", author: content.author,
      baseRefName: content.baseRefName, headRefName: content.headRefName,
      baseCommit: content.baseCommit, headCommit: remote.head, commitCount: 2, commits: [],
      files: content.files)
    try XCTUnwrap(diff.comments).state.reload()
    pumpMain(
      until: { self.text(diff.newRevision) == text && diff.comments?.isSettled == true },
      "新しい先頭の版と、欄の行の移しが揃う")
  }

  /// PR に push があっても、欄の行が新しい版にもあり印を出せるなら、欄は書きかけごとその行へ移り、新しい先頭のコミットの
  /// その行へ書く。
  func testAPushMovesADraftToItsLineInTheNewHead() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didPressTrailingMarkOn: .document(3))
    let draft = try XCTUnwrap(layer.draft(.new, line: 3))
    surface.replaceText(of: draft.field, with: "書きかけ")

    try push("zero\none\ntwo\nTHREE\nfour\n", remote, diff)
    XCTAssertIdentical(layer.draft(.new, line: 4), draft, "行「four」は 1 行下へ移った")
    XCTAssertEqual(draft.text, "書きかけ")
    XCTAssertFalse(draft.isLineGone)
    draft.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { layer.draft(.new, line: 4) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [.addThread(path: "a.txt", side: .new, line: 5, commit: remote.head, body: "書きかけ")])
  }

  /// PR に push があって欄の行が書き換えられたら、欄は閉じずに書きかけを残し、送れない姿になる。「取り消す」で閉じる。
  func testAPushThatRewritesTheLineKeepsTheDraftButStopsItsWrite() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didPressTrailingMarkOn: .document(2))
    let draft = try XCTUnwrap(layer.draft(.new, line: 2))
    surface.replaceText(of: draft.field, with: "書きかけ")

    try push("one\ntwo\nTRES\nfour\n", remote, diff)
    XCTAssertIdentical(layer.draft(.new, line: 2), draft, "書き換えられた区間の終わりの行の下に残る")
    XCTAssertEqual(draft.text, "書きかけ")
    XCTAssertTrue(draft.isLineGone)
    draft.zone(.pressed(PrCommentControl.add))
    XCTAssertEqual(remote.writes, [], "行が現在の diff に無い欄は送れない")
    draft.zone(.pressed(PrCommentControl.cancel))
    XCTAssertNil(layer.draft(.new, line: 2))
  }
}
