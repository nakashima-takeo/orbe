import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// レビューのポップアップの未送信のコメントの行から、その場所へ移る——ポップアップが閉じ、PR の一覧でそのファイルの行を選び、
/// そのファイルの PR の diff が本体に出て焦点が本文へ移る。スレッドを置いたら、その行と押したコメントが見える位置に来て、
/// 畳んだスレッドが開く。見せる頼みは、利用者が diff を操作したら捨てる。PR の中身とレビューのやりとりは差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 未送信のコメントの行を押しても、別のファイルの diff のままになる。diff の先頭（最初の変更区間）に出て、
/// コメントの行を探し直すことになる。解決済みで畳んだスレッドが畳まれたままで、コメントが見えない。同じファイルの diff を
/// 見ている間に押しても、その行へ動かない。押した後の打鍵が本文に入らない。長いスレッドの下の方の押したコメントが画面の外に
/// 残る。読んでいる最中・返信を打っている最中に、後から置かれたスレッドへ画面が飛ぶ。
extension EditorDiffTests {
  /// ほかのファイルの diff を見ている間に、行 150 にある解決済みで畳んだスレッドについて、その未送信のコメントの行を押すと、ポップアップが
  /// 閉じ、PR の一覧でそのファイルの行を選び、そのファイルの diff が出て焦点が本文へ移り、行 150 が見え、スレッドが開く。
  /// 続けて同じファイルの、既に置いてある畳んだスレッド（行 80）のコメントの行を押すと、行 80 へ動き、そのスレッドが開く。
  func testPressingAPendingCommentRevealsItsLineAndOpensItsThread() throws {
    var lines = (1...200).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    remote.threads = [
      pendingThread("T_far", line: 150, resolved: true),
      pendingThread("T_mid", line: 80, resolved: true),
    ]
    let opened = try commentedTab(remote) {
      lines[2] = "THREE"
      try self.repo.write("a.txt", lines.joined(separator: "\n") + "\n")
      try self.repo.write("b.txt", "b\n")
      XCTAssertTrue(self.repo.git(["add", "b.txt"]).isSuccess)
    }
    let pane = opened.tab.group.view.editor
    let state = try XCTUnwrap(pane.pullRequest.state)
    _ = try open(state, path: "b.txt", into: opened.tab)
    XCTAssertEqual(pane.diff?.id.path, "b.txt", "前提: ほかのファイルの diff を見ている")
    let review = pane.reviewPopup
    review.onOpenURL = { XCTFail("置ける行ではブラウザを開かない: \($0)") }
    pumpMain(until: { review.canOpen }, "前提: レビューを開ける")
    // 一覧から開く（閉じると焦点は一覧へ戻る。その上で、行から移ると焦点が本文へ移ることを見る）。
    let list = pane.pullRequestList.list
    pumpMain(until: { list.window != nil }, "前提: PR の一覧が窓に載る")
    pane.window?.makeFirstResponder(list)
    review.toggle()
    XCTAssertTrue(review.isOpen, "前提: ポップアップが開く")

    review.press(try XCTUnwrap(state.pendingComments.first { $0.thread == "T_far" }))
    XCTAssertFalse(review.isOpen, "ポップアップが閉じる")
    XCTAssertEqual(pane.pullRequest.selection, .file("a.txt"), "PR の一覧でそのファイルの行を選ぶ")
    let diff = try XCTUnwrap(pane.diff)
    XCTAssertEqual(diff.id.path, "a.txt", "そのファイルの diff が出る")
    pumpMain(until: { pane.window?.firstResponder === pane.focusTarget }, "焦点は本文へ移る")
    pumpMain(until: { diff.placement == .placed && diff.newSurface != nil }, "位置を決める")
    let surface = try engine(diff.newSurface)
    pumpMain(until: { self.shows(surface, line: 149) }, "行 150 が見える")
    XCTAssertEqual(diff.comments?.zone(thread: "T_far")?.isCollapsed, false, "畳んだスレッドが開く")

    pumpMain(
      until: { diff.comments?.zone(thread: "T_mid")?.isCollapsed == true },
      "前提: 行 80 の畳んだスレッドを置いてある")
    review.press(try XCTUnwrap(state.pendingComments.first { $0.thread == "T_mid" }))
    XCTAssertTrue(pane.diff === diff, "前提: 同じ diff のまま")
    XCTAssertTrue(shows(surface, line: 79), "置いてあるスレッドなら、押したその場で行 80 へ動く")
    XCTAssertEqual(diff.comments?.zone(thread: "T_mid")?.isCollapsed, false, "置いてある畳んだスレッドが開く")
  }

  /// 古い側の行のコメントの行を押すと、古い版の行の位置へ移る。古い版の行 11〜110 の 100 行を新しい 50 行に置き換えた PR で、
  /// 後ろの文脈の行（古い版の行 150 は新しい版の行 100）は、インラインで新しい版の行 100 が、並列で左の面の行 150 が見える。
  /// 置き換えた行（古い版の行 60）は、インラインで差し込んだ削除行の下のスレッドが、並列で左の面の行 60 が見える。
  func testPressingAnOldSidePendingCommentRevealsItsOldLine() throws {
    let lines = (1...300).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    remote.threads = [
      pendingThread("T_context", line: 150, side: .old),
      pendingThread("T_replaced", line: 60, side: .old),
    ]
    let opened = try commentedTab(remote) {
      let replaced = lines[..<10] + (1...50).map { "new \($0)" } + lines[110...]
      try self.repo.write("a.txt", replaced.joined(separator: "\n") + "\n")
    }
    let pane = opened.tab.group.view.editor
    let state = try XCTUnwrap(pane.pullRequest.state)
    let diff = opened.diff
    pane.reviewPopup.onOpenURL = { XCTFail("置ける行ではブラウザを開かない: \($0)") }
    pumpMain(until: { diff.placement == .placed }, "前提: 位置を決める")
    let press = { (thread: String) in
      pane.reviewPopup.press(try XCTUnwrap(state.pendingComments.first { $0.thread == thread }))
    }

    try press("T_context")
    XCTAssertTrue(pane.diff === diff, "前提: 同じ diff のまま")
    let inline = try engine(diff.newSurface)
    pumpMain(until: { self.shows(inline, line: 99) }, "インラインで新しい版の行 100 が見える")
    pumpMain(until: { diff.comments?.zone(thread: "T_replaced") != nil }, "前提: スレッドが置かれる")
    try press("T_replaced")
    let zone = try XCTUnwrap(diff.comments?.zone(thread: "T_replaced"))
    XCTAssertTrue(
      shows(inline, zone: zone), "置いてあるスレッドなら押したその場で、差し込んだ削除行（古い版の行 60）の下のスレッドが見える")

    resize(try XCTUnwrap(pane.window), width: Self.sideWidth)
    pumpMain(until: { diff.oldSurface != nil }, "前提: 並列")
    let left = try engine(diff.oldSurface)
    for (thread, line) in [("T_replaced", 59), ("T_context", 149)] {
      try engine(diff.newSurface).scroll(toFirstLine: 0)
      XCTAssertFalse(shows(left, line: line), "前提: 左の面の行 \(line + 1) は見えていない")
      try press(thread)
      XCTAssertTrue(shows(left, line: line), "並列で左の面の行 \(line + 1) が見える")
    }
  }

  /// 見えている高さより長いスレッドの、最後の未送信のコメントの行を押すと、スレッドの本文を組み終えた後に、押したコメントが
  /// 見える位置に来る——新しく開く diff でも、同じ diff を見ている間でも。
  func testPressingTheLastCommentOfALongThreadRevealsThatComment() throws {
    var lines = (1...200).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    let body = (1...4).map { "段落 \($0)" }.joined(separator: "\n\n")
    remote.threads = [
      GitHubPullRequestReview.Thread(
        id: "T_long", path: "a.txt", lines: .at(.new, 100), isResolved: false, canReply: true,
        canResolve: true, canUnresolve: false,
        comments: (1...30).map {
          .init(
            id: "C\($0)", author: "you", body: body,
            createdAt: Date(timeIntervalSince1970: Double($0)),
            isPending: $0 == 30)
        })
    ]
    let opened = try commentedTab(remote) {
      lines[2] = "THREE"
      try self.repo.write("a.txt", lines.joined(separator: "\n") + "\n")
      try self.repo.write("b.txt", "b\n")
      XCTAssertTrue(self.repo.git(["add", "b.txt"]).isSuccess)
    }
    let pane = opened.tab.group.view.editor
    let state = try XCTUnwrap(pane.pullRequest.state)
    pane.reviewPopup.onOpenURL = { XCTFail("置ける行ではブラウザを開かない: \($0)") }
    _ = try open(state, path: "b.txt", into: opened.tab)
    let pending = try XCTUnwrap(state.pendingComments.first)
    XCTAssertEqual(pending.id, "C30", "前提: 押すのは最後のコメント")

    pane.reviewPopup.press(pending)
    let diff = try XCTUnwrap(pane.diff)
    XCTAssertEqual(diff.id.path, "a.txt", "前提: そのファイルの diff が出る")
    pumpMain(until: { diff.placement == .placed && diff.newSurface != nil }, "前提: 位置を決める")
    let surface = try engine(diff.newSurface)
    pumpMain(until: { self.showsComment(surface, diff, "C30") }, "新しく開いた diff で、押したコメントが見える")

    surface.scroll(toFirstLine: 0)
    XCTAssertFalse(showsComment(surface, diff, "C30"), "前提: 押したコメントは見えていない")
    pane.reviewPopup.press(pending)
    XCTAssertTrue(pane.diff === diff, "前提: 同じ diff のまま")
    XCTAssertTrue(showsComment(surface, diff, "C30"), "同じ diff なら、押したその場で押したコメントが見える")
  }

  /// 未送信のコメントの行を押した後、そのスレッドがまだ置かれていない間（スレッドを読んだ版と diff の版を揃える読みの答えを
  /// 待つ間）に、利用者が diff をスクロールするか、押下・打鍵するか、面が処理する ⌘ 付きのキーを押したら、後からそのスレッドが置かれても
  /// 画面を動かさない。操作が無ければ、置かれたときにその行が見える位置へ動く。
  func testAUserOperationBeforeTheThreadIsPlacedCancelsTheReveal() throws {
    let lines = (1...200).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    let opened = try commentedTab(remote) {
      var changed = lines
      changed[2] = "THREE"
      try self.repo.write("a.txt", changed.joined(separator: "\n") + "\n")
    }
    let diff = opened.diff
    let pane = opened.tab.group.view.editor
    pane.reviewPopup.onOpenURL = { XCTFail("ブラウザを開かない: \($0)") }
    let state = try XCTUnwrap(pane.pullRequest.state)
    pumpMain(until: { diff.placement == .placed }, "前提: 位置を決める")
    let surface = try engine(diff.newSurface)
    let head = remote.head
    let stale = String(repeating: "0", count: 40)
    let release = {
      let answers = remote.heldReviews
      remote.heldReviews = []
      for answer in answers { answer() }
    }
    for (index, (name, operate)) in try userOperations(on: surface).enumerated() {
      let id = "T\(index)"
      let line = 100 + index * 20
      // スレッドをずれた版で読ませ、揃える読み直しの答えを留める（置けるかが「まだ分からない」間、層は置かずに待つ）。
      remote.head = stale
      remote.threads.append(pendingThread(id, line: line))
      remote.holdsReviews = true
      state.reload()
      pumpMain(until: { !remote.heldReviews.isEmpty }, "\(name): 前提: 読みの答えを留める")
      release()
      pumpMain(
        until: { state.review?.headCommit == stale && !remote.heldReviews.isEmpty },
        "\(name): 前提: ずれた版を読み、揃える読み直しの答えを留める")
      XCTAssertNil(diff.comments?.zone(thread: id), "\(name): 前提: まだ置かれていない")
      surface.scroll(toFirstLine: 0)
      pane.reviewPopup.press(try XCTUnwrap(state.pendingComments.first { $0.thread == id }))
      try operate()

      remote.head = head
      remote.holdsReviews = false
      release()
      pumpMain(
        until: { diff.comments?.zone(thread: id).map { !$0.isTypesetting } ?? false },
        "\(name): 前提: 版が揃ってスレッドが置かれ、本文を組み終える")
      nextTurn()
      if index == 0 {
        XCTAssertTrue(shows(surface, line: line - 1), "\(name): 置かれたスレッドの行が見える")
      } else {
        XCTAssertFalse(shows(surface, line: line - 1), "\(name): 置かれたスレッドへ画面を動かさない")
      }
    }
  }

  /// 未送信のコメントの行を押した後、push の後の版で揃える前（スレッドがまだ置かれていない間）に、レビューへの書き込みが終わり、
  /// その読み直しが push の前の版を読んでも、頼みを捨てない（その答えを中身の版と見比べるまでの一瞬を、揃える読みをやめたと
  /// 見ない）。揃ってスレッドが置かれたら、その行が見える位置へ動く。
  func testAWriteFinishingBeforeTheHeadsAreComparedKeepsTheReveal() throws {
    var lines = (1...200).map { "line \($0)" }
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "long"]).isSuccess)
    let remote = Remote()
    remote.threads = [pendingThread("T", line: 150)]
    lines[2] = "THREE"
    let opened = try commentedTab(remote) {
      try self.repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    }
    let diff = opened.diff
    let pane = opened.tab.group.view.editor
    pane.reviewPopup.onOpenURL = { XCTFail("ブラウザを開かない: \($0)") }
    let state = try XCTUnwrap(pane.pullRequest.state)
    pumpMain(until: { diff.comments?.shownThreads["T"] != nil }, "前提: スレッドが置かれる")
    let release = {
      let answers = remote.heldReviews
      remote.heldReviews = []
      for answer in answers { answer() }
    }

    // push を読み、レビューのやりとりの答えを留める（diff は push の後の両端を見せ、スレッドはまだ分からないので置かない）。
    lines[3] = "FOUR"
    try repo.write("a.txt", lines.joined(separator: "\n") + "\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    let pushed = repo.head()
    remote.content = try XCTUnwrap(remote.content).withHead(pushed)
    remote.holdsReviews = true
    state.reload()
    pumpMain(
      until: {
        diff.comments?.placed?.ends.head == pushed && !remote.heldReviews.isEmpty
          && diff.comments?.isSettled == true
      }, "前提: push の後の両端を見せ、レビューのやりとりの答えを留める")
    XCTAssertNil(diff.comments?.shownThreads["T"], "前提: スレッドはまだ置かれていない")
    let surface = try engine(diff.newSurface)
    surface.scroll(toFirstLine: 0)
    pane.reviewPopup.press(try XCTUnwrap(state.pendingComments.first { $0.thread == "T" }))

    // 書き込みの前に出した読みの答えは使われず、書き込みの後の読み直しを留める。その答えは push の前の版を読む。
    var written = false
    XCTAssertTrue(
      state.writeReview(.setResolved(thread: "T", true)) { _ in written = true }, "前提: 書き込みを受け付ける")
    release()
    pumpMain(until: { remote.heldReviews.count == 1 }, "前提: 書き込みの後の読み直しの答えを留める")
    release()
    pumpMain(
      until: { written && !remote.heldReviews.isEmpty && diff.comments?.isSettled == true },
      "前提: 書き込みが終わり、揃える読み直しの答えを留める")
    XCTAssertNotNil(diff.comments?.revealRequest, "書き込みが終わっても、頼みは残る")

    remote.head = pushed
    remote.holdsReviews = false
    release()
    pumpMain(
      until: { diff.comments?.zone(thread: "T").map { !$0.isTypesetting } ?? false },
      "前提: 版が揃ってスレッドが置かれ、本文を組み終える")
    nextTurn()
    XCTAssertTrue(shows(try engine(diff.newSurface), line: 149), "置かれたスレッドの行が見える")
  }

  /// 利用者の操作——無し・面のスクロール・面の押下・面への打鍵・面が処理する ⌘ 付きのキー（複数カーソルを下に足す）。
  private func userOperations(on surface: MetalTextSurface) throws -> [(String, () throws -> Void)]
  {
    let window = try XCTUnwrap(surface.view.window)
    let view = surface.view
    let down = String(UnicodeScalar(NSEvent.SpecialKey.downArrow.rawValue)!)
    return [
      ("操作なし", {}),
      (
        "スクロール",
        {
          let event = try XCTUnwrap(
            CGEvent(
              scrollWheelEvent2Source: SyntheticInput.source, units: .line, wheelCount: 1,
              wheel1: -1, wheel2: 0, wheel3: 0))
          view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }
      ),
      (
        "押下",
        {
          let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.minY + 20), to: nil)
          view.mouseDown(with: .mouse(.leftMouseDown, at: point, in: window))
          view.mouseUp(with: .mouse(.leftMouseUp, at: point, in: window))
        }
      ),
      (
        "打鍵",
        {
          window.makeFirstResponder(view)
          self.deliverKeyDown(.key(down, []), to: window)
        }
      ),
      (
        "⌘ 付きのキー",
        {
          window.makeFirstResponder(view)
          XCTAssertTrue(
            view.performKeyEquivalent(with: .key(down, [.command, .option])), "前提: 面が処理する")
        }
      ),
    ]
  }

  /// 面 `surface` に、diff `diff` のスレッドの中のコメント `comment` の全体が見えているか。
  private func showsComment(_ surface: MetalTextSurface, _ diff: EditorDiff, _ comment: String)
    -> Bool
  {
    guard let zone = diff.comments?.zone(thread: "T_long"), !zone.isTypesetting,
      let span = zone.commentSpans[comment]
    else { return false }
    surface.flush()
    guard let block = surface.rows.block(ofZone: ObjectIdentifier(zone)) else { return false }
    let lineHeight = surface.rows.lineHeight
    let (first, visible) = surface.viewportLines
    let top = surface.rows.top(ofBlock: block) + span.lowerBound
    let bottom = surface.rows.top(ofBlock: block) + span.upperBound
    return top >= Double(first) * lineHeight - 0.5
      && bottom <= Double(first + visible) * lineHeight + 0.5
  }

  /// 面 `surface` に、絵の差し込み `zone` の上端が見えているか。
  private func shows(_ surface: MetalTextSurface, zone: PrCommentZone) -> Bool {
    surface.flush()
    guard let block = surface.rows.block(ofZone: ObjectIdentifier(zone)) else { return false }
    let (first, visible) = surface.viewportLines
    let unit = surface.rows.unit(ofBlock: block)
    return unit >= Double(first) && unit < Double(first + visible)
  }

  /// 面 `surface` に、文書の行 `line`（0 始まり）が見えているか。
  private func shows(_ surface: MetalTextSurface, line: Int) -> Bool {
    surface.flush()
    let (first, visible) = surface.viewportLines
    let unit = surface.rows.unit(ofLine: line)
    return unit >= Double(first) && unit < Double(first + visible)
  }

  /// a.txt の側 `side` の行 `line` の、未送信のコメント 1 件のスレッド。
  private func pendingThread(
    _ id: String, line: Int, side: GitHubDiffSide = .new, resolved: Bool = false
  ) -> GitHubPullRequestReview.Thread {
    GitHubPullRequestReview.Thread(
      id: id, path: "a.txt", lines: .at(side, line), isResolved: resolved, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "\(id)-C", author: "me", body: "本文", createdAt: Date(), isPending: true)]
    )
  }
}
