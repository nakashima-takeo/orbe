import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの層——スレッドを付いた行の下に置き、行の右端の印から新しいコメントの欄を開き、書き込みの結果で欄を
/// 空にするか本文を残す。PR の中身とレビューのやりとりは差し替えの構造体が答える。
///
/// 壊れると何が起きるか: スレッドが別の行の下に出る。印を押しても欄が開かない・焦点が入らない。書いた行と違う行にコメントが
/// 付く。失敗した書き込みで書きかけが消える。通った後も欄が残る。空の欄が開いたまま残る。PR に push があると書きかけが消える・
/// 欄が元の行の番号のまま別の行の下に残る・書き換えられた行へのコメントを古い行の番号で送れる。
extension EditorDiffTests {
  /// 差し替えの GitHub のレビューのやりとり（テストが書き換える）と、届いた書き込み。
  private final class Remote {
    var head = ""
    var content: GitHubPullRequestContent?
    var threads: [GitHubPullRequestReview.Thread] = []
    var writes: [GitHubReviewWrite] = []
    var failure: GitHubFailure?
  }

  /// a.txt の行 3 を変えた PR の diff を開く。
  private func commentedDiff(_ remote: Remote) throws -> (EditorDiff, MetalTextSurface) {
    let base = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "-c", "feat"]).isSuccess)
    try repo.write("a.txt", "one\ntwo\nTHREE\nfour\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "change"]).isSuccess)
    let head = repo.head()
    XCTAssertTrue(repo.git(["switch", "-q", "main"]).isSuccess)
    remote.head = head
    remote.content = GitHubPullRequestContent(
      nodeID: "PR_7", number: 7, title: "題", url: "https://github.com/me/r/pull/7", isDraft: false,
      state: .open, body: "", author: "me", baseRefName: "main", headRefName: "feat",
      baseCommit: base, headCommit: head, commitCount: 1, commits: [],
      files: [.init(path: "a.txt", change: .modified, isViewed: false)])
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
          completion(GitHubReviewWriteResult(pendingReview: pending, failure: remote.failure))
        }))
    state.attach(repo: try repo.open(), fetchRemote: nil, headRemote: nil)
    let (tab, _) = tab()
    let diff = try tab.group.editor.openDiff(id("a.txt", .pullRequest(state)), as: .pinned)
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

  /// 印を押すとその行の下に新しいコメントの欄が開いて主になり、「レビューに追加」でその側と行（1 始まり）・diff の先頭の
  /// コミットのスレッドを書く。通れば欄は閉じる。
  func testTheMarkOpensADraftThatWritesAThreadOnItsLine() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didPressTrailingMarkOn: .document(1))
    let draft = try XCTUnwrap(layer.draft(.new, line: 1))
    XCTAssertEqual(surface.primary, .field(draft.field.id), "欄に焦点が入る")
    surface.replaceText(of: draft.field, with: "直す")
    draft.zone(.pressed(PrCommentControl.add))
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
