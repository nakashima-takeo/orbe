import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// スレッドを diff に置けるかの読み手が、同じ答えを出すこと——未送信のコメントの一覧の置けるか・今の diff に置けない未解決の
/// スレッドの数・ファイルの行のコメント数と、diff の面に実際に載っているスレッドの絵。揃える読みをやめた間・push の後に
/// レビューのやりとりの読みが返るまでの間・揃った後のどれでも、読み手どうしが食い違わない。PR の中身とレビューのやりとりは
/// 差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 一覧では置けない（押すと GitHub の PR が開く）のに diff にはスレッドの絵が残る・diff にスレッドが出ているのに
/// ファイルの行のコメント数が 0 になる・置けない数が diff に出ていないスレッドを数え漏らす。
extension EditorDiffTests {
  /// 新しい側の行（T_new）・古い側の行（T_old）・行を持たない（T_file）の、未送信のコメントを持つ未解決のスレッドで、
  /// ①揃える読みをやめた間 ②push の後、レビューのやりとりの読みの答えを待つ間 ③揃った後、の各時点の答えを見る。移り変わる
  /// 間も、main のキューが回るたびに、読み手どうしの答えが揃っていることを見る。
  func testEveryReaderOfThePlacementAgreesThroughStoppedReadsAndAPush() throws {
    let remote = Remote()
    remote.threads = [
      placementThread("T_new", line: 3), placementThread("T_old", line: 2, side: .old),
      placementThread("T_file", line: nil),
    ]
    let opened = try commentedTab(remote)
    let pane = opened.tab.group.view.editor
    pane.reviewPopup.onOpenURL = { XCTFail("ブラウザを開かない: \($0)") }
    let state = try XCTUnwrap(pane.pullRequest.state)
    let diff = opened.diff
    var disagreements: [String] = []
    let settle = { (message: String, done: @escaping () -> Bool) in
      pumpMain(
        until: {
          if let found = self.disagreement(state, diff) { disagreements.append(found) }
          return done() && diff.comments?.isSettled == true
        }, message)
      nextTurn()
    }
    settle("前提: スレッドが置かれる") { self.shownThreads(diff) == ["T_new", "T_old"] }
    let head = remote.head

    remote.head = String(repeating: "0", count: 40)
    state.reload()
    settle("① 揃える読みをやめる") { state.stoppedAligning }
    XCTAssertEqual(
      answers(state, diff),
      Answers(placeable: [], outdated: 3, counts: [:], shown: []), "① 揃える読みをやめた間はどれも置けない")

    remote.head = head
    state.reload()
    settle("③ 揃う") { !state.stoppedAligning && state.review?.headCommit == head }
    let aligned = Answers(
      placeable: ["T_new", "T_old"], outdated: 1, counts: ["a.txt": 2], shown: ["T_new", "T_old"])
    XCTAssertEqual(answers(state, diff), aligned, "③ 揃うと、置けるスレッドが戻る")

    try repo.write("a.txt", "one\ntwo\nTHREE\nfour\nfive\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    let pushed = repo.head()
    remote.content = try XCTUnwrap(remote.content).withHead(pushed)
    remote.holdsReviews = true
    state.reload()
    settle("② push の後の両端を見せ、レビューのやりとりの答えを待つ") {
      state.diffEnds?.head == pushed && !remote.heldReviews.isEmpty
        && diff.comments?.placed?.ends.head == pushed
    }
    XCTAssertEqual(
      answers(state, diff),
      Answers(placeable: ["T_new", "T_old"], outdated: 1, counts: [:], shown: []),
      "② 両端が替わったので前の答えは使わず、どれもまだ分からない（一覧は置けるとみなし、数は数えず、絵は置かない）")

    remote.head = pushed
    remote.holdsReviews = false
    releaseReviews(remote)
    settle("③ push の後の版で揃い、diff が push の後の両端を見せる") {
      state.review?.headCommit == pushed && diff.comments?.placed?.ends.head == pushed
    }
    XCTAssertEqual(answers(state, diff), aligned, "③ push の後の版で揃う")
    XCTAssertEqual(disagreements, [], "移り変わる間も、読み手どうしの答えが揃っている")
  }

  /// 留めたレビューのやりとりの読みの答えを返す（答えは、返す時点の `head` と `threads` で作る）。
  private func releaseReviews(_ remote: Remote) {
    let answers = remote.heldReviews
    remote.heldReviews = []
    for answer in answers { answer() }
  }

  /// 置き方の読み手の答え——一覧で置けるスレッド・置けない数・ファイルのコメント数・面に載っているスレッド。
  private struct Answers: Equatable {
    let placeable: Set<String>
    let outdated: Int
    let counts: [String: Int]
    let shown: Set<String>
  }

  private func answers(_ state: PullRequestState, _ diff: EditorDiff) -> Answers {
    Answers(
      placeable: Set(state.pendingComments.filter(\.isPlaceable).map(\.thread)),
      outdated: state.outdatedThreadCount, counts: state.placements.commentCounts,
      shown: shownThreads(diff))
  }

  /// diff の今の新しい側の面（push を読むと作り直される）の並びに、絵が載っているスレッド。
  private func shownThreads(_ diff: EditorDiff) -> Set<String> {
    guard let surface = diff.newSurface as? MetalTextSurface else { return [] }
    surface.flush()
    return Set(
      (state(of: diff)?.review?.threads ?? []).map(\.id).filter { id in
        diff.comments?.zone(thread: id).flatMap { surface.rows.block(ofZone: ObjectIdentifier($0)) }
          != nil
      })
  }

  private func state(of diff: EditorDiff) -> PullRequestState? { diff.comments?.state }

  /// 読み手どうしの食い違い（無ければ nil）——面に載っているスレッドが一覧で置けないとされている、またはファイルのコメント数が面に
  /// 載っているスレッドのコメントの数と違う。diff が PR の今の両端に追いつくまで（push の後に両端を求め直し、新しい両端の本文を
  /// 読む間）は、一覧と数は PR の今の両端で、面は見せている前の両端で答えるので、比べない。両端を求められないと決まった後は、
  /// 追いつく先が無いので比べる。
  private func disagreement(_ state: PullRequestState, _ diff: EditorDiff) -> String? {
    if let ends = state.diffEnds {
      guard diff.comments?.placed?.ends == ends else { return nil }
    } else if case .failed = state.bounds {
    } else {
      return nil
    }
    let shown = shownThreads(diff)
    let unplaceable = Set(state.pendingComments.filter { !$0.isPlaceable }.map(\.thread))
    var counts: [String: Int] = [:]
    for thread in state.review?.threads ?? [] where shown.contains(thread.id) {
      counts[thread.path, default: 0] += thread.comments.count
    }
    guard shown.isDisjoint(with: unplaceable), counts == state.placements.commentCounts else {
      return "面 \(shown.sorted())・置けない \(unplaceable.sorted())・数 \(state.placements.commentCounts)"
    }
    return nil
  }

  /// a.txt の側 `side` の行 `line` の、未送信のコメント 1 件を持つ未解決のスレッド。
  private func placementThread(_ id: String, line: Int?, side: GitHubDiffSide = .new)
    -> GitHubPullRequestReview.Thread
  {
    GitHubPullRequestReview.Thread(
      id: id, path: "a.txt", side: side, line: line, isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "\(id)-C", author: "me", body: "本文", createdAt: Date(), isPending: true)]
    )
  }
}

extension GitHubPullRequestContent {
  /// 先頭のコミットだけを `head` に替えた中身（PR への push）。
  fileprivate func withHead(_ head: String) -> GitHubPullRequestContent {
    GitHubPullRequestContent(
      nodeID: nodeID, number: number, title: title, url: url, isDraft: isDraft, state: state,
      body: body, author: author, baseRefName: baseRefName, headRefName: headRefName,
      baseCommit: baseCommit, headCommit: head, commitCount: commitCount + 1, commits: commits,
      files: files)
  }
}
