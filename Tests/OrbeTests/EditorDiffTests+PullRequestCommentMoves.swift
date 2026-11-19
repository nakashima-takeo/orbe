import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの層で、PR に push やベースの付け替えがあったとき、欄とスレッドの行を新しい版へ移し、行が無くなれば
/// 書きかけを残して送れない姿にする。
///
/// 壊れると何が起きるか: PR に push やベースの付け替えがあると、書きかけが消える・欄が元の行の番号のまま別の行の下に残る・
/// 書き換えられた行へのコメントを古い行の番号で送れる・置けなくなったスレッドの返信の書きかけが見えなくなる。
extension EditorDiffTests {
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
    XCTAssertNil(draft.notice)
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
    XCTAssertEqual(draft.notice, .lineGone)
    draft.zone(.pressed(PrCommentControl.add))
    XCTAssertEqual(remote.writes, [], "行が現在の diff に無い欄は送れない")
    draft.zone(.pressed(PrCommentControl.cancel))
    XCTAssertNil(layer.draft(.new, line: 2))
  }

  /// ベースの付け替えで先頭のコミットが同じまま古い側の版が替わっても、古い側の欄は書きかけごと新しい版の同じ行へ移り、
  /// その行へ書く。
  func testARetargetedBaseMovesAnOldSideDraft() throws {
    let first = repo.head()
    try repo.write("a.txt", "zero\none\ntwo\nthree\nfour\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "zero"]).isSuccess)
    let remote = Remote()
    let (diff, _) = try commentedDiff(remote) {
      try self.repo.write("a.txt", "zero\none\ntwo\nTHREE\nfour\n")
    }
    let layer = try XCTUnwrap(diff.comments)
    layer.openDraft(.old, line: 1)
    let draft = try XCTUnwrap(layer.draft(.old, line: 1))
    try XCTUnwrap(draft.surface).replaceText(of: draft.field, with: "古い側")

    let content = try XCTUnwrap(remote.content)
    remote.content = GitHubPullRequestContent(
      nodeID: content.nodeID, number: content.number, title: content.title, url: content.url,
      isDraft: false, state: .open, body: "", author: content.author,
      baseRefName: "release", headRefName: content.headRefName, baseCommit: first,
      headCommit: content.headCommit, commitCount: 2, commits: [], files: content.files)
    layer.state.reload()
    pumpMain(
      until: { self.text(diff.old) == "one\ntwo\nthree\nfour\n" && layer.isSettled },
      "付け替えたベースの版と、欄の行の移しが揃う")
    XCTAssertIdentical(layer.draft(.old, line: 0), draft, "行「one」は 1 行上へ移った")
    XCTAssertNil(draft.notice)
    draft.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { layer.draft(.old, line: 0) == nil }, "通れば欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [.addThread(path: "a.txt", side: .old, line: 1, commit: remote.head, body: "古い側")])
  }

  /// 返信の書きかけを持つスレッドが push で今の diff に置けなくなっても、書きかけごと残り、行に付いていない旨を出したまま
  /// 返信を送れる（返信は行を渡さないので GitHub は受ける）。GitHub からスレッドが消えると、書きかけは残り、削除された旨を
  /// 出して送れない姿になる。
  func testAThreadWithAReplyDraftStaysWhenItCannotBePlaced() throws {
    let remote = Remote()
    let thread = { (line: Int?) in
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .new, line: line, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    }
    remote.threads = [thread(3)]
    let (diff, surface) = try commentedDiff(remote)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    surface.replaceText(of: zone.field, with: "返信の書きかけ")

    remote.threads = [thread(nil)]
    try push("one\ntwo\nTRES\nfour\n", remote, diff)
    let next = try engine(diff.newSurface)
    pumpMain(
      until: { next.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "置けなくなったスレッドが残る")
    XCTAssertEqual(zone.notice, .detached)
    XCTAssertEqual(zone.text, "返信の書きかけ")

    remote.threads = []
    try XCTUnwrap(diff.comments).state.reload()
    pumpMain(until: { zone.notice == .deleted }, "消えたスレッドの書きかけが残る")
    XCTAssertEqual(zone.text, "返信の書きかけ")
    XCTAssertNotNil(next.rows.block(ofZone: ObjectIdentifier(zone)))
    zone.zone(.pressed(PrCommentControl.add))
    XCTAssertEqual(remote.writes, [], "消えたスレッドへは書かない")
  }

  /// 置けなくなったスレッドへの返信は送れる。
  func testAReplyToAThreadThatCannotBePlacedIsWritten() throws {
    let remote = Remote()
    let thread = { (line: Int?) in
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .new, line: line, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    }
    remote.threads = [thread(3)]
    let (diff, surface) = try commentedDiff(remote)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    surface.replaceText(of: zone.field, with: "返信")
    remote.threads = [thread(nil)]
    try push("one\ntwo\nTRES\nfour\n", remote, diff)
    pumpMain(until: { zone.notice == .detached }, "置けなくなったスレッドが残る")
    zone.zone(.pressed(PrCommentControl.add))
    pumpMain(until: { !remote.writes.isEmpty }, "返信が届く")
    XCTAssertEqual(remote.writes, [.reply(thread: "T", body: "返信", resolve: false)])
  }
}
