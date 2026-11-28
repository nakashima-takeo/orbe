import OrbeEditorCore
import OrbeTestSupport
import XCTest

@testable import Orbe
@testable import OrbeEditorEngine

/// スレッドを diff に置けるかの読み手が、同じ答えを出すこと——未送信のコメントの一覧の置けるか・今の diff に置けない未解決の
/// スレッドの数・ファイルの行のコメント数と、diff の面に実際に載っているスレッドの絵。揃える読みをやめた間・push の後に
/// レビューのやりとりの読みが返るまでの間・揃った後のどれでも、読み手どうしが食い違わない。答えを待つ間は、両端が同じなら前の
/// 答えを保つ。PR の中身とレビューのやりとりは差し替えの構造体が答える。
///
/// 壊れると何が起きるか: 一覧では置けない（押すと GitHub の PR が開く）のに diff にはスレッドの絵が残る・diff にスレッドが出ているのに
/// ファイルの行のコメント数が 0 になる・置けない数が diff に出ていないスレッドを数え漏らす。レビューのやりとりの読みが中身より
/// 先に新しい版を読んだ間や、やめた後に再読込した間に、絵と数が外れては戻り、ちらつく。
extension EditorDiffTests {
  /// ①揃える読みをやめた間 ②やめた後に再読込し、答えを待つ間（やめた間の答えのまま。帯は読み込み中） ③揃った後 ④両端が同じ
  /// まま、レビューのやりとりだけが別の版を読んで揃える読み直しの答えを待つ間（前の答えのまま）、の各時点の答えを見る。
  /// 移り変わる間も、main のキューが回るたびに、読み手どうしの答えが揃っていることを見る。
  func testEveryReaderOfThePlacementAgreesWhileAligningStopsAndResumes() throws {
    let scene = try placementScene()
    let (remote, state, diff) = (scene.remote, scene.state, scene.diff)
    let head = remote.head

    remote.head = String(repeating: "0", count: 40)
    state.reload()
    scene.settle("① 揃える読みをやめる") { state.stoppedAligning }
    XCTAssertEqual(answers(state, diff), .stopped, "① 揃える読みをやめた間はどれも置けない")
    XCTAssertEqual(state.submissionBlock, .stopped, "① 帯は、揃えて読めなかったと告げる")

    remote.head = head
    remote.holdsReviews = true
    state.reload()
    scene.settle("② 前提: 再読込の、レビューのやりとりの答えを留める") { !remote.heldReviews.isEmpty }
    XCTAssertEqual(answers(state, diff), .stopped, "② 再読込して答えを待つ間は、やめた間の答えのまま（揺れない）")
    XCTAssertEqual(state.submissionBlock, .loading, "② 帯は、読み込み中と告げる")
    remote.holdsReviews = false
    releaseReviews(remote)
    scene.settle("③ 揃う") { !state.stoppedAligning && state.review?.headCommit == head }
    XCTAssertEqual(answers(state, diff), .aligned, "③ 揃うと、置けるスレッドが戻る")

    remote.head = String(repeating: "2", count: 40)
    remote.holdsReviews = true
    state.reload()
    scene.settle("④ 前提: 別の版のレビューのやりとりの答えを留める") { !remote.heldReviews.isEmpty }
    releaseReviews(remote)
    scene.settle("④ 別の版を読み、揃える読み直しの答えを待つ") {
      state.review?.headCommit == remote.head && !remote.heldReviews.isEmpty
    }
    XCTAssertEqual(answers(state, diff), .aligned, "④ 両端が同じ間は、前の答えを保ち、絵も数も前のまま")
    remote.head = head
    remote.holdsReviews = false
    releaseReviews(remote)
    scene.settle("④ 揃い直す") { state.review?.headCommit == head && !state.isReadingReview }
    XCTAssertEqual(answers(state, diff), .aligned, "④ 揃い直しても、前の答えのまま")
    XCTAssertEqual(scene.disagreements, [], "移り変わる間も、読み手どうしの答えが揃っている")
  }

  /// ①push の後、レビューのやりとりの読みの答えを待つ間 ②push の後の版で揃った後、の各時点の答えを見る。移り変わる間も、main の
  /// キューが回るたびに、読み手どうしの答えが揃っていることを見る。
  func testEveryReaderOfThePlacementAgreesThroughAPush() throws {
    let scene = try placementScene()
    let (remote, state, diff) = (scene.remote, scene.state, scene.diff)
    try repo.write("a.txt", "one\ntwo\nTHREE\nfour\nfive\n")
    XCTAssertTrue(repo.git(["commit", "-qam", "push"]).isSuccess)
    let pushed = repo.head()
    remote.content = try XCTUnwrap(remote.content).withHead(pushed)
    remote.holdsReviews = true
    state.reload()
    scene.settle("① push の後の両端を見せ、レビューのやりとりの答えを待つ") {
      state.diffEnds?.head == pushed && !remote.heldReviews.isEmpty
        && diff.comments?.placed?.ends.head == pushed
    }
    XCTAssertEqual(
      answers(state, diff),
      Answers(placeable: ["T_new", "T_old"], outdated: 1, counts: [:], shown: []),
      "① 両端が替わったので前の答えは使わず、どれもまだ分からない（一覧は置けるとみなし、数は数えず、絵は置かない）")

    remote.head = pushed
    remote.holdsReviews = false
    releaseReviews(remote)
    scene.settle("② push の後の版で揃い、diff が push の後の両端を見せる") {
      state.review?.headCommit == pushed && diff.comments?.placed?.ends.head == pushed
    }
    XCTAssertEqual(answers(state, diff), .aligned, "② push の後の版で揃う")
    XCTAssertEqual(scene.disagreements, [], "移り変わる間も、読み手どうしの答えが揃っている")
  }

  /// 置き方の読み手を見る場面——新しい側の行（T_new）・古い側の行（T_old）・行を持たない（T_file）の、未送信のコメントを持つ
  /// 未解決のスレッドを、版が揃った diff に置いたところから始める。
  @MainActor private final class PlacementScene {
    let remote: Remote
    let state: PullRequestState
    let diff: EditorDiff
    let tab: TerminalTab
    let disagreement: () -> String?
    /// `settle` が、main のキューが回るたびに見つけた読み手どうしの食い違い。
    private(set) var disagreements: [String] = []

    init(
      remote: Remote, state: PullRequestState, opened: (diff: EditorDiff, tab: TerminalTab),
      disagreement: @escaping () -> String?
    ) {
      self.remote = remote
      self.state = state
      (diff, tab) = opened
      self.disagreement = disagreement
    }

    /// `done` が真になりコメントの層が落ち着くまで main のキューを回し（回るたびに食い違いを記録する）、そのあとさらに一巡、回す。
    func settle(_ message: String, _ done: @escaping () -> Bool) {
      pumpMain(
        until: {
          if let found = self.disagreement() { self.disagreements.append(found) }
          return done() && self.diff.comments?.isSettled == true
        }, message)
      nextTurn()
    }
  }

  private func placementScene() throws -> PlacementScene {
    let remote = Remote()
    remote.threads = [
      placementThread("T_new", line: 3), placementThread("T_old", line: 2, side: .old),
      placementThread("T_file", line: nil),
    ]
    let opened = try commentedTab(remote)
    let pane = opened.tab.group.view.editor
    pane.reviewPopup.onOpenURL = { XCTFail("ブラウザを開かない: \($0)") }
    let state = try XCTUnwrap(pane.pullRequest.state)
    let scene = PlacementScene(remote: remote, state: state, opened: opened) {
      self.disagreement(state, opened.diff)
    }
    scene.settle("前提: スレッドが置かれる") { self.shownThreads(opened.diff) == ["T_new", "T_old"] }
    XCTAssertEqual(answers(state, opened.diff), .aligned, "前提: 版が揃い、置けるスレッドが置かれる")
    return scene
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

    /// 版が揃い、T_new と T_old を置いた。
    static let aligned = Answers(
      placeable: ["T_new", "T_old"], outdated: 1, counts: ["a.txt": 2], shown: ["T_new", "T_old"])
    /// 揃える読みをやめ、どれも置けない。
    static let stopped = Answers(placeable: [], outdated: 3, counts: [:], shown: [])
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
      id: id, path: "a.txt", lines: line.map { .at(side, $0) }, isResolved: false, canReply: true,
      canResolve: true, canUnresolve: false,
      comments: [.init(id: "\(id)-C", author: "me", body: "本文", createdAt: Date(), isPending: true)]
    )
  }
}
