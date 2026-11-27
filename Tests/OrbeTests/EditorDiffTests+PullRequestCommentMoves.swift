import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの層で、PR に push やベースの付け替えがあったとき、欄とスレッドの行を新しい版へ移し、行が無くなれば
/// 書きかけを残して送れない姿にする。
///
/// 壊れると何が起きるか: PR に push やベースの付け替えがあると、書きかけが消える・欄が元の行の番号のまま別の行の下に残る・
/// 書き換えられた行へのコメントを古い行の番号で送れる・置けなくなったスレッドの返信の書きかけが見えなくなる。
extension EditorDiffTests {
  /// PR の feat に a.txt を `text` にするコミットを足し、PR の状態を読み直して、diff が新しい先頭の版を見せ終えるのを待つ
  /// （待つ間、main の 1 周ごとに `observe` を呼ぶ）。
  private func push(
    _ text: String, _ remote: Remote, _ diff: EditorDiff, observe: () -> Void = {}
  ) throws {
    try repo.write("a.txt", text)
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    remote.head = repo.head()
    let content = try XCTUnwrap(remote.content)
    remote.content = GitHubPullRequestContent(
      nodeID: content.nodeID, number: content.number, title: content.title, url: content.url,
      isDraft: false, state: .open, body: "", author: content.author,
      baseRefName: content.baseRefName, headRefName: content.headRefName,
      baseCommit: content.baseCommit, headCommit: remote.head, commitCount: 2, commits: [],
      files: content.files)
    try XCTUnwrap(diff.comments).state.reload()
    pumpMain(
      until: {
        observe()
        return self.text(diff.newRevision) == text && diff.comments?.isSettled == true
      },
      "新しい先頭の版と、欄の行の移しが揃う")
  }

  /// PR に push があっても、欄の行が新しい版にもあり印を出せるなら、欄は書きかけごとその行へ移り、新しい先頭のコミットの
  /// その行へ書く。
  func testAPushMovesADraftToItsLineInTheNewHead() throws {
    let remote = Remote()
    let (diff, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.surface(surface, didMarkFrom: .document(3), to: .document(3))
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
    layer.surface(surface, didMarkFrom: .document(2), to: .document(2))
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

  /// 欄が行を数えた diff の両端が PR の今の両端でない間（ベースの付け替えを読んだ後、両端を求め終えるまで・求められない
  /// 間）は、新しいスレッドを書かず、最新の内容を読み込んでからやり直すよう告げる。
  func testADraftCountedOnOtherEndsIsNotWritten() throws {
    let remote = Remote()
    let (diff, _) = try commentedDiff(remote)
    let layer = try XCTUnwrap(diff.comments)
    layer.openDraft(.old, line: 1)
    let draft = try XCTUnwrap(layer.draft(.old, line: 1))
    try XCTUnwrap(draft.surface).replaceText(of: draft.field, with: "古い側")

    let content = try XCTUnwrap(remote.content)
    remote.content = GitHubPullRequestContent(
      nodeID: content.nodeID, number: content.number, title: content.title, url: content.url,
      isDraft: false, state: .open, body: "", author: content.author,
      baseRefName: content.baseRefName, headRefName: content.headRefName,
      baseCommit: String(repeating: "1", count: 40), headCommit: content.headCommit,
      commitCount: 1, commits: [], files: content.files)
    layer.state.reload()
    pumpMain(
      until: { if case .failed = layer.state.bounds { true } else { false } },
      "前提: 付け替えたベースの両端を求められない")
    draft.zone(.pressed(PrCommentControl.add))
    XCTAssertEqual(remote.writes, [])
    XCTAssertNotNil(draft.failure, "最新の内容を読み込んでからやり直すよう告げる")
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

  /// PR に push があっても、diff が新しい先頭の版を見せるまでの間、置いていたスレッドは並びから外れない（返信の書きかけの
  /// 欄の場が閉じない）。
  func testAPushKeepsAPlacedThreadUntilTheDiffShowsTheNewHead() throws {
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .new, line: 3, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    ]
    let (diff, surface) = try commentedDiff(remote)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    surface.replaceText(of: zone.field, with: "返信の書きかけ")

    var vanished = false
    try push("one\ntwo\nTHREE\nfour\nfive\n", remote, diff) {
      guard let surface = diff.newSurface as? MetalTextSurface else { return }
      if surface.rows.block(ofZone: ObjectIdentifier(zone)) == nil { vanished = true }
    }
    XCTAssertFalse(vanished, "push を読んで diff が新しい版を見せるまでの間も、スレッドは並びから外れない")
    XCTAssertEqual(zone.text, "返信の書きかけ")
  }

  /// 返信欄に焦点と書きかけを持つスレッドで、そのファイルを変える push を読んで面が作り直されても、新しい面でも返信欄が
  /// 主（キーと IME の行き先）のまま。壊れると、打っている途中の返信の字が本文へ行く（読むだけの本文には入らず消える）。
  func testAPushThatRemakesTheSurfaceKeepsTheReplyFocused() throws {
    try assertAPushKeepsTheReplyFocused(
      side: false, pushed: "one\ntwo\nTHREE\nfour\nfive\n", line: 3)
  }

  /// 上と同じで、スレッドの行が動く push。
  func testAPushThatMovesTheThreadKeepsTheReplyFocused() throws {
    try assertAPushKeepsTheReplyFocused(
      side: false, pushed: "zero\none\ntwo\nTHREE\nfour\n", line: 4)
  }

  /// 上と同じで、並列（新しい側のスレッドは右の面）。
  func testAPushInSideBySideKeepsTheReplyFocused() throws {
    try assertAPushKeepsTheReplyFocused(
      side: true, pushed: "zero\none\ntwo\nTHREE\nfour\n", line: 4)
  }

  /// 新しい側の行 3 のスレッドの返信欄に焦点と書きかけを置き、a.txt を `pushed`（スレッドは行 `line` へ）にする push を
  /// 読んだ後も、作り直した面で返信欄が主で、窓の焦点がその面にあり、書きかけが残ることを確かめる。
  private func assertAPushKeepsTheReplyFocused(side: Bool, pushed: String, line: Int) throws {
    let thread = { (line: Int) in
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .new, line: line, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
    }
    let remote = Remote()
    remote.threads = [thread(3)]
    let (diff, surface) = try commentedDiff(remote, width: side ? Self.sideWidth : 900)
    let window = try XCTUnwrap(surface.textView.window)
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(until: { surface.rows.block(ofZone: ObjectIdentifier(zone)) != nil }, "スレッドが置かれる")
    window.makeFirstResponder(surface.textView)
    surface.focus(zone.field)
    surface.replaceText(of: zone.field, with: "返信の書きかけ")

    remote.threads = [thread(line)]
    try push(pushed, remote, diff)
    pumpMain(until: { diff.carried == nil }, "位置を引き継ぎ終える")
    let after = try engine(diff.newSurface)
    XCTAssertFalse(after === surface, "前提: 新しい側の面が作り直された")
    XCTAssertEqual(after.primary, .field(zone.field.id))
    XCTAssertTrue(window.firstResponder === after.textView)
    XCTAssertEqual(zone.text, "返信の書きかけ")
  }

  /// 並列で、古い側の行のスレッドより下を読んでいる間に push があって新しい側の面が作り直されても、見えている先頭の行は
  /// 変わらない（面が大きさを持ち、スレッドの反対側の空きを揃えた並びの上で位置を引き継ぐ）。
  func testAPushInSideBySideKeepsTheLineBeingReadBelowAnOldSideThread() throws {
    let lines = (0..<200).map { "l\($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "lines"]).isSuccess)
    var head = Array(lines[0..<50] + lines[55...])
    let remote = Remote()
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T", path: "a.txt", side: .old, line: 53, isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: [
          .init(
            id: "C", author: "you", body: (0..<6).map { "段落 \($0)" }.joined(separator: "\n\n"),
            createdAt: Date(), isPending: false)
        ])
    ]
    let (diff, _) = try commentedDiff(remote, width: Self.sideWidth) {
      try self.repo.write("a.txt", head.joined(separator: "\n") + "\n")
    }
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T"))
    pumpMain(
      until: {
        guard let left = diff.oldSurface as? MetalTextSurface else { return false }
        return left.rows.block(ofZone: ObjectIdentifier(zone)) != nil
          && diff.comments?.isSettled == true
      }, "前提: 左の面に古い側のスレッドが置かれる")
    let before = try engine(diff.newSurface)
    let reading = LineRow(line: 120)
    before.flush()
    before.scroll(to: before.position(ofLineRow: reading))
    before.flush()
    XCTAssertEqual(before.lineRow(of: before.viewport.top), reading, "前提: スレッドより下の行を読む")

    head[145] = "L"
    try push(head.joined(separator: "\n") + "\n", remote, diff)
    pumpMain(until: { diff.newSurface !== before && diff.carried == nil }, "新しい側の面が作り直される")
    let after = try engine(diff.newSurface)
    after.flush()
    XCTAssertEqual(after.lineRow(of: after.viewport.top), reading)
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

  /// インラインで、新しいコメントの欄を置いた削除行の塊の中（欄より上の削除行）を読んでいる間に push があって面が作り直されて
  /// も、同じ削除行が上端に残る（引き継いだ段を、新しい面で欄の高さを数えた位置に直して置く）。新しい版の本文を読んでから
  /// diff がそれを見せるまでの間も、欄は並びから外れない（一瞬消えない）。
  func testAPushKeepsTheRemovedLineBeingReadAboveADraft() throws {
    let lines = (0..<200).map { "l\($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "lines"]).isSuccess)
    var head = Array(lines[0..<50] + lines[55...])
    let remote = Remote()
    let (diff, before) = try commentedDiff(remote) {
      try self.repo.write("a.txt", head.joined(separator: "\n") + "\n")
    }
    let layer = try XCTUnwrap(diff.comments)
    layer.openDraft(.old, line: 53)
    let draft = try XCTUnwrap(layer.draft(.old, line: 53))
    before.replaceText(of: draft.field, with: "書きかけ")
    pumpMain(until: { draft.surface != nil && layer.isSettled }, "4 本目の削除行の下に欄")
    let reading = LineRow(line: 50, offset: -4)
    before.flush()
    before.scroll(to: before.position(ofLineRow: reading))
    before.flush()
    XCTAssertEqual(before.lineRow(of: before.viewport.top), reading, "前提: 2 本目の削除行「l51」を読む")

    head[150] = "L"
    var vanished = false
    try push(head.joined(separator: "\n") + "\n", remote, diff) {
      guard let surface = diff.newSurface as? MetalTextSurface else { return }
      let placed = surface.rows.contents.contains {
        if case .zone(let id) = $0 { return id == ObjectIdentifier(draft) }
        return false
      }
      if !placed { vanished = true }
    }
    XCTAssertFalse(vanished, "push を読んで diff が新しい版を見せるまでの間も、欄は並びから外れない")
    pumpMain(until: { diff.newSurface !== before && diff.carried == nil }, "面が作り直される")
    let after = try engine(diff.newSurface)
    after.flush()
    XCTAssertEqual(after.lineRow(of: after.viewport.top), reading)
  }
}
