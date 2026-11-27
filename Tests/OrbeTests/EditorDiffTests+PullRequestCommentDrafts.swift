import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// PR の diff のコメントの書きかけは、PR ごとの状態が持ち、その PR の diff ならどれにも出て、diff を閉じても残る。
///
/// 壊れると何が起きるか: diff を閉じる・別の連のタブで開き直すと、打っていた返信や新しいコメントが消える。同じファイルを
/// 2 か所で開くと、片方の書きかけがもう片方に出ない。片方から送ったコメントを、もう片方から送り直せて、同じコメントが 2 つ付く。
/// 送った直後に diff を閉じると、通った返信が書きかけに残り、開き直して送ると同じ返信が 2 つ付く。GitHub から消えたスレッドへの
/// 返信の書きかけが、開き直した diff で見えなくなる。
extension EditorDiffTests {
  /// 新しい側の行 3 に付いた、返信できるスレッド T。
  private var replyable: GitHubPullRequestReview.Thread {
    GitHubPullRequestReview.Thread(
      id: "T", path: "a.txt", side: .new, line: 3, isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "C", author: "you", body: "本文", createdAt: Date(), isPending: false)])
  }

  /// diff `diff` の新しい側の面に、絵の差し込み（`PrCommentZone`）`zones` が全部置かれるまで待つ。
  private func waitPlaced(
    _ diff: EditorDiff, _ zones: [PrCommentZone], _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    pumpMain(
      until: {
        guard let surface = diff.newSurface as? MetalTextSurface else { return false }
        return zones.allSatisfy { surface.rows.block(ofZone: ObjectIdentifier($0)) != nil }
      }, message, file: file, line: line)
  }

  /// 返信と新しいコメントの書きかけは、diff を閉じて同じファイルを開き直すと、同じスレッドの返信欄と、同じ行の欄に出る。
  /// 「取り消す」で閉じた欄の書きかけは出ない。
  func testDraftsSurviveClosingTheDiff() throws {
    let remote = Remote()
    remote.threads = [replyable]
    let (diff, tab) = try commentedTab(remote)
    let layer = try XCTUnwrap(diff.comments)
    let surface = try engine(diff.newSurface)
    let reply = try XCTUnwrap(layer.zone(thread: "T"))
    waitPlaced(diff, [reply], "スレッドが置かれる")
    surface.replaceText(of: reply.field, with: "返信の書きかけ")
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    surface.replaceText(of: try XCTUnwrap(layer.draft(.new, line: 1)).field, with: "コメントの書きかけ")
    layer.surface(surface, didMarkFrom: .document(0), to: .document(0))
    let cancelled = try XCTUnwrap(layer.draft(.new, line: 0))
    surface.replaceText(of: cancelled.field, with: "取り消す書きかけ")
    cancelled.zone(.pressed(PrCommentControl.cancel))

    tab.group.editor.closeDiff(on: .pullRequest)
    let (reopened, _) = try open(layer.state, into: tab)
    let next = try XCTUnwrap(reopened.comments)
    XCTAssertFalse(next === layer, "前提: 開き直した diff は別の層を持つ")
    let nextReply = try XCTUnwrap(next.zone(thread: "T"))
    let comment = try XCTUnwrap(next.draft(.new, line: 1))
    waitPlaced(reopened, [nextReply, comment], "返信欄と新しいコメントの欄が置かれる")
    XCTAssertEqual(nextReply.text, "返信の書きかけ")
    XCTAssertEqual(comment.text, "コメントの書きかけ")
    XCTAssertNil(next.draft(.new, line: 0), "取り消した欄は出ない")
  }

  /// 同じ PR の同じファイルの diff を 2 か所（別の連のタブ）で開くと、片方で打った返信と新しいコメントの書きかけは、後から
  /// 開いた diff にも出る。開いている diff の片方で打ち直すと、もう片方の欄も同じ本文になる。
  func testADraftShowsInEveryDiffOfTheSameFile() throws {
    let remote = Remote()
    remote.threads = [replyable]
    let (first, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(first.comments)
    let mine = try XCTUnwrap(layer.zone(thread: "T"))
    waitPlaced(first, [mine], "スレッドが置かれる")
    surface.replaceText(of: mine.field, with: "一つ目で打った返信")
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    let draft = try XCTUnwrap(layer.draft(.new, line: 1))
    surface.replaceText(of: draft.field, with: "一つ目で打ったコメント")

    let (second, _) = try open(layer.state)
    let other = try XCTUnwrap(second.comments)
    let otherReply = try XCTUnwrap(other.zone(thread: "T"))
    let otherDraft = try XCTUnwrap(other.draft(.new, line: 1))
    waitPlaced(second, [otherReply, otherDraft], "後から開いた diff に返信欄と新しいコメントの欄が置かれる")
    XCTAssertEqual(otherReply.text, "一つ目で打った返信")
    XCTAssertEqual(otherDraft.text, "一つ目で打ったコメント")

    let otherSurface = try engine(second.newSurface)
    otherSurface.replaceText(of: otherReply.field, with: "二つ目で直した返信")
    otherSurface.replaceText(of: otherDraft.field, with: "二つ目で直したコメント")
    XCTAssertEqual(mine.text, "二つ目で直した返信")
    XCTAssertEqual(draft.text, "二つ目で直したコメント")
  }

  /// 同じ PR の同じファイルを 2 か所で開いているとき、片方から送った返信と新しいコメントは、書き込みの最中にもう片方から
  /// 押しても送られない。通ると、両方の diff で返信欄が空になり、新しいコメントの欄が閉じる。
  func testADraftSentFromOneDiffIsSentOnceAndLeavesEveryDiff() throws {
    let remote = Remote()
    remote.threads = [replyable]
    let (first, surface) = try commentedDiff(remote)
    let layer = try XCTUnwrap(first.comments)
    let mine = try XCTUnwrap(layer.zone(thread: "T"))
    waitPlaced(first, [mine], "スレッドが置かれる")
    surface.replaceText(of: mine.field, with: "返信")
    layer.surface(surface, didMarkFrom: .document(1), to: .document(1))
    let draft = try XCTUnwrap(layer.draft(.new, line: 1))
    surface.replaceText(of: draft.field, with: "コメント")
    let (second, _) = try open(layer.state)
    let other = try XCTUnwrap(second.comments)
    let otherReply = try XCTUnwrap(other.zone(thread: "T"))
    let otherDraft = try XCTUnwrap(other.draft(.new, line: 1))
    waitPlaced(second, [otherReply, otherDraft], "前提: もう片方にも書きかけが出る")

    remote.holds = true
    mine.zone(.pressed(PrCommentControl.add))
    otherReply.zone(.pressed(PrCommentControl.add))
    draft.zone(.pressed(PrCommentControl.add))
    otherDraft.zone(.pressed(PrCommentControl.add))
    remote.holds = false
    pumpMain(
      until: {
        while !remote.held.isEmpty { remote.held.removeFirst()() }
        return mine.text.isEmpty && otherReply.text.isEmpty
          && layer.draft(.new, line: 1) == nil && other.draft(.new, line: 1) == nil
      }, "通れば両方の返信欄が空になり、両方の新しいコメントの欄が閉じる")
    XCTAssertEqual(
      remote.writes,
      [
        .reply(thread: "T", body: "返信", resolve: false),
        .addThread(path: "a.txt", side: .new, line: 2, commit: remote.head, body: "コメント"),
      ])
  }

  /// 返信を送った直後、結果が届く前にその diff を閉じても、通れば書きかけは消え、開き直した diff の返信欄は空（送り直して
  /// 同じ返信を 2 つ付けない）。
  func testAReplySentJustBeforeTheDiffClosesIsGoneOnceItGoesThrough() throws {
    let remote = Remote()
    remote.threads = [replyable]
    remote.holds = true
    weak var closed: PrCommentLayer?
    let (state, tab) = try { () throws -> (PullRequestState, TerminalTab) in
      let (diff, tab) = try commentedTab(remote)
      let layer = try XCTUnwrap(diff.comments)
      closed = layer
      let zone = try XCTUnwrap(layer.zone(thread: "T"))
      waitPlaced(diff, [zone], "スレッドが置かれる")
      try engine(diff.newSurface).replaceText(of: zone.field, with: "一度だけ")
      zone.zone(.pressed(PrCommentControl.add))
      tab.group.editor.closeDiff(on: .pullRequest)
      return (layer.state, tab)
    }()
    XCTAssertNil(closed, "前提: 閉じた diff の層は残っていない")

    remote.holds = false
    while !remote.held.isEmpty { remote.held.removeFirst()() }
    pumpMain(until: { !state.isWritingReview(.thread("T")) }, "返信が通る")
    let (reopened, _) = try open(state, into: tab)
    let zone = try XCTUnwrap(reopened.comments?.zone(thread: "T"))
    waitPlaced(reopened, [zone], "スレッドが置かれる")
    XCTAssertEqual(zone.text, "")
    XCTAssertEqual(remote.writes, [.reply(thread: "T", body: "一度だけ", resolve: false)])
  }

  /// GitHub から消えたスレッドへの返信の書きかけは、開き直した diff でも、消える前にスレッドを置いていた行の下に、削除された旨と
  /// 一緒に出る。
  func testAReplyDraftToADeletedThreadReappearsInTheReopenedDiff() throws {
    let remote = Remote()
    remote.threads = [replyable]
    let (diff, tab) = try commentedTab(remote)
    let layer = try XCTUnwrap(diff.comments)
    let surface = try engine(diff.newSurface)
    let zone = try XCTUnwrap(layer.zone(thread: "T"))
    waitPlaced(diff, [zone], "スレッドが置かれる")
    let block = surface.rows.block(ofZone: ObjectIdentifier(zone))
    surface.replaceText(of: zone.field, with: "返信の書きかけ")
    remote.threads = []
    layer.state.reload()
    pumpMain(until: { zone.notice == .deleted }, "前提: 消えたスレッドの書きかけが残る")

    tab.group.editor.closeDiff(on: .pullRequest)
    let (reopened, _) = try open(layer.state, into: tab)
    let next = try XCTUnwrap(reopened.comments?.zone(thread: "T"))
    waitPlaced(reopened, [next], "消えたスレッドの返信欄が置かれる")
    XCTAssertEqual(next.text, "返信の書きかけ")
    XCTAssertEqual(next.notice, .deleted)
    XCTAssertEqual(
      try engine(reopened.newSurface).rows.block(ofZone: ObjectIdentifier(next)), block,
      "消える前にスレッドを置いていた行の下")
  }
}
