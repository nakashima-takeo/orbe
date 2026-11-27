import OrbeTestSupport
import XCTest

@testable import Orbe

/// PR ごとの状態が持つレビューへの書き込みを、書き込み・中身とレビューのやりとりの読み直し・それぞれの答え（出した順と関係なく
/// 届く）・見ている者の出入り・PR への push が入り乱れる順序で、種を決めた乱数により実行する。どの順序でも、書き込みの規則と、
/// 先頭のコミットを揃える規則（pull-request.md の「レビューのやりとり」）が保たれる。種の半分は、GitHub の答えが一貫していて
/// 読みが失敗しない場合で、そのときは読みが出尽くすたびに中身とレビューのやりとりの先頭が揃っている。書き込みはスレッドへの
/// ものだけで、レビューの送信の規則は diff の両端（本物の git）が要るので `PullRequestStateTests+Review` の決まった手順が守る。
///
/// 壊れると何が起きるか: 書き込みの結果が返らないままになり、そのスレッドへの返信が、アプリを再起動するまでできなくなる。
/// 書き込みの応答が届くより前に問い合わせた読みの応答を取り込む結果、書いたコメントが消えて見えたり、失敗の文が残ったりする。
/// 2 回押した返信が 2 回送られる。push の後に先頭が食い違ったまま読むのをやめ、diff にスレッドを置けず、新しいスレッドも
/// 書けなくなる。GitHub への問い合わせが止まらない。
/// 失敗した種と手順はメッセージに出る（同じ種で回せば同じ手順になる）。
///
/// 小さい段も、答えが一貫している種と一貫していない種（奇数と偶数）を同じ数だけ実行する。
extension PullRequestStateTests {
  private static let reviewOrderSeeds = Array(UInt64(1)...400)

  func testInterleavedWritesAndRereadsKeepTheWriteRules() throws {
    try playReviewWrites(seeds: Self.reviewOrderSeeds.prefix(40), steps: 150)
  }

  func testInterleavedWritesAndRereadsKeepTheWriteRulesAtFullScale() throws {
    try Fuzz.skipFullScaleIfExcluded()
    try playReviewWrites(seeds: Self.reviewOrderSeeds, steps: 150)
  }

  /// 種ごとに `steps` 手を実行する。最初に規則が破れた種で止める。
  private func playReviewWrites(seeds: some Sequence<UInt64>, steps: Int) throws {
    for seed in seeds {
      gitHub = PullRequestFakeGitHub()
      key = PullRequestState.Key(
        commonDir: "/tmp/\(UUID().uuidString)",
        id: try XCTUnwrap(GitHubItemID(repo: "o/r", number: 7)))
      let state = PullRequestState.shared(for: key, source: gitHub.source)
      state.beginWatching()
      addTeardownBlock { @MainActor in state.endWatching() }
      gitHub.content = .success(content(head: "h0"))
      state.reload()
      gitHub.answersAtOnce = false
      gitHub.answersReviewAtOnce = false

      let run = ReviewWriteRun(
        state: state, gitHub: gitHub, seed: seed, consistent: seed % 2 == 1,
        content: { self.content(head: $0) })
      run.play(steps: steps)
      run.drain()
      if let violation = run.violation {
        XCTFail("種 \(seed): \(violation)\n手順: \(run.log.joined(separator: " → "))")
        return
      }
    }
  }
}

/// 1 つの種の手順を実行し、規則が破れたら最初の 1 つを `violation` に残す。
@MainActor
private final class ReviewWriteRun {
  struct Accepted {
    let write: GitHubReviewWrite
    /// 受け付けた時点に状態が持っていたレビューのやりとりの先頭のコミット（利用者が見ていたもの）。
    let reviewedCommit: String
    /// 届いた書き込みの応答の何番目がこの書き込みの応答か。
    var answeredAt: Int?
    var answer: GitHubFailure?
    var results = 0
  }

  private let state: PullRequestState
  private let gitHub: PullRequestFakeGitHub
  private let content: (String) -> GitHubPullRequestContent
  /// GitHub の答えが一貫していて（読んだ時点の今の先頭を返す）、読みが失敗しない。
  private let consistent: Bool
  private var random: SplitMix
  private var accepted: [Accepted] = []
  private var sent = 0
  /// 届いた書き込みの応答の数。
  private var writeAnswers = 0
  /// 走っているレビューのやりとりの読みを出した時点の `writeAnswers`。
  private var readIssuedAt: Int?
  private var reads: Int
  private var contentReads: Int
  private var watching = true
  /// GitHub 上の PR の先頭のコミットと、その 1 つ前（一貫していない答えが返す）。
  private var head = "h0"
  private var previousHead: String?
  private var pushes = 0
  /// 次に送る書き込みが名指しすべき未送信のレビュー（最後に取り込んだ読みか、その後の書き込みの応答で分かったもの）。
  private var pendingReview: String?
  /// 今の操作で届いた読みを出した時点の `writeAnswers`（読みの応答を返す操作の間だけ）。
  private var answeringReadIssuedAt: Int?
  private var tag = 0
  private(set) var log: [String] = []
  private(set) var violation: String?

  init(
    state: PullRequestState, gitHub: PullRequestFakeGitHub, seed: UInt64, consistent: Bool,
    content: @escaping (String) -> GitHubPullRequestContent
  ) {
    self.state = state
    self.gitHub = gitHub
    self.content = content
    self.consistent = consistent
    random = SplitMix(seed: seed)
    reads = gitHub.reviewReads
    contentReads = gitHub.contentReads
  }

  func play(steps: Int) {
    for _ in 0..<steps where violation == nil {
      switch random.next(below: 13) {
      case 0..<2: write()
      case 2..<4:
        log.append("reload")
        state.reload()
      case 4..<6: answerRead(failing: odd(), inconsistent: odd())
      case 6..<8: answerContent(failing: odd(), inconsistent: odd())
      case 8..<10: answerWrite()
      case 10: toggleWatching()
      default: push()
      }
      check()
    }
  }

  /// 答えが一貫していない種のとき、4 回に 1 回真を返す。
  private func odd() -> Bool { !consistent && random.next(below: 4) == 0 }

  /// 見ている者を戻し、走っている読みと書き込みに、応答が尽きるまで一貫した成功を返す（問い合わせが止まらなければ違反）。
  /// その後に読み直しを頼んで同じように答える。受け付けた書き込みは、どれも 1 回だけ結果を返し、中身とレビューのやりとりは
  /// GitHub の今の先頭で揃う。
  func drain() {
    if !watching { toggleWatching() }
    check()
    answerAll()
    log.append("reload")
    state.reload()
    check()
    answerAll()
    guard violation == nil else { return }
    if let index = accepted.firstIndex(where: { $0.results != 1 }) {
      violation = "受け付けた書き込み \(index) が、応答が尽きても結果を返さない"
    } else if state.content?.headCommit != head || state.review?.headCommit != head {
      violation =
        "中身の先頭 \(state.content?.headCommit ?? "無し") とレビューのやりとりの先頭 "
        + "\(state.review?.headCommit ?? "無し") が、GitHub の先頭 \(head) で揃わない"
    }
  }

  private func answerAll() {
    for _ in 0..<200 where violation == nil {
      if readIssuedAt != nil {
        answerRead(failing: false, inconsistent: false)
      } else if !gitHub.contentRequests.isEmpty {
        answerContent(failing: false, inconsistent: false)
      } else if !gitHub.reviewWrites.isEmpty {
        answerWrite(failing: false)
      } else {
        return
      }
      check()
    }
    if violation == nil { violation = "GitHub の答えが変わらないのに、問い合わせが止まらない" }
  }

  // MARK: - 操作

  private func write() {
    let seen = state.review?.headCommit ?? ""
    let writes: [GitHubReviewWrite] = [
      .reply(thread: "T1", body: "x", resolve: false), .setResolved(thread: "T1", true),
      .reply(thread: "T2", body: "x", resolve: true),
      .addThread(
        path: "a", side: .new, line: 1, commit: random.next(below: 2) == 0 ? seen : head, body: "x"),
    ]
    let write = writes[random.next(below: writes.count)]
    let expected: Bool
    if case .addThread(_, _, _, let commit, _) = write {
      expected = commit == seen
    } else {
      let target = Self.target(of: write)
      expected = !unfinished.contains { Self.target(of: $0.write) == target }
    }
    let index = accepted.count
    let taken = state.writeReview(write) { [weak self] in self?.finish(index, $0.failure) }
    log.append("write(\(Self.target(of: write) ?? "new"))=\(taken)")
    guard taken == expected else {
      violation = taken ? "受け付けてはいけない書き込みを受け付けた" : "受け付けるべき書き込みを拒否した"
      return
    }
    if taken { accepted.append(Accepted(write: write, reviewedCommit: seen)) }
  }

  /// 答えを返す時点の GitHub の先頭（一貫していない答えは 1 つ前）。
  private func answeredHead(_ inconsistent: Bool) -> String {
    inconsistent ? previousHead ?? head : head
  }

  private func answerRead(failing: Bool, inconsistent: Bool) {
    guard let issuedAt = readIssuedAt else { return }
    tag += 1
    let pending = random.next(below: 2) == 0 ? "P\(tag)" : nil
    // スレッドの id で読みの答えを 1 つずつ見分ける（書き込みはスレッドの有無を見ない）。
    let read = GitHubPullRequestReview(
      viewerIsAuthor: false, headCommit: answeredHead(inconsistent),
      pendingReview: pending.map { .init(id: $0, commentCount: 1) },
      threads: [
        .init(
          id: "r\(tag)", path: "a", side: .new, line: 1, isResolved: false, canReply: true,
          canResolve: true, canUnresolve: false, comments: [])
      ])
    gitHub.review = failing ? .failure(.unreachable) : .success(read)
    log.append("answerRead(\(failing ? "失敗" : read.headCommit))")
    let before = (state.review, state.reviewFailure, state.contentFailure)
    let current = issuedAt == writeAnswers
    readIssuedAt = nil
    answeringReadIssuedAt = issuedAt
    gitHub.answerReview()
    answeringReadIssuedAt = nil
    if state.contentFailure != before.2 {
      violation = "レビューのやりとりの読みが、中身の失敗を変えた"
    } else if !current {
      if state.review != before.0 || state.reviewFailure != before.1 {
        violation = "書き込みの応答より前に出した読みを取り込んだ"
      }
    } else if failing {
      if state.review != before.0 || state.reviewFailure != .unreachable {
        violation = "読み直しの失敗で、前に読めたものを残して失敗を持つ、にならない"
      }
    } else {
      pendingReview = pending
      if state.review != read || state.reviewFailure != nil {
        violation = "書き込みの応答の後に出した読みを取り込んで失敗を消す、にならない"
      }
    }
  }

  private func answerContent(failing: Bool, inconsistent: Bool) {
    guard !gitHub.contentRequests.isEmpty else { return }
    let read = content(answeredHead(inconsistent))
    gitHub.content = failing ? .failure(.unreachable) : .success(read)
    log.append("answerContent(\(failing ? "失敗" : read.headCommit))")
    let before = state.content
    gitHub.answerContent()
    if failing, state.content != before || state.contentFailure != .unreachable {
      violation = "中身の読みが失敗したのに、前に読めた中身を残したまま失敗を持っていない"
    } else if !failing, state.content?.headCommit != read.headCommit || state.contentFailure != nil
    {
      violation = "中身が読めたのに、取り込まれていない、または前の失敗が消えていない"
    }
  }

  private func answerWrite(failing: Bool? = nil) {
    guard let index = accepted.firstIndex(where: { $0.answeredAt == nil }),
      !gitHub.reviewWrites.isEmpty
    else { return }
    var failure: GitHubFailure?
    if failing ?? (random.next(below: 2) == 0) {
      failure = random.next(below: 2) == 0 ? .timedOut : .reason("x")
    }
    let after: String?? =
      switch random.next(below: 3) {
      case 0: .none
      case 1: .some(nil)
      default: .some("W\(index)")
      }
    writeAnswers += 1
    accepted[index].answeredAt = writeAnswers
    accepted[index].answer = failure
    pendingReview = after ?? gitHub.reviewWrites[0].pendingReview
    log.append("answerWrite(\(failure.map { "\($0)" } ?? "成功"))")
    gitHub.finishReviewWrite(pendingReview: after, failure: failure)
    if !watching, accepted[index].results == 0 {
      violation = "見ている者がいないのに、書き込み \(index) が応答の後も完了しない"
    }
  }

  private func toggleWatching() {
    if watching { state.endWatching() } else { state.beginWatching() }
    watching.toggle()
    log.append(watching ? "beginWatching" : "endWatching")
  }

  /// GitHub 上の PR に push が入る（Orbe はまだ知らない）。
  private func push() {
    pushes += 1
    previousHead = head
    head = "h\(pushes)"
    log.append("push(\(head))")
  }

  // MARK: - 規則

  private var unfinished: [Accepted] { accepted.filter { $0.results == 0 } }

  /// 書き込み `index` の結果は、応答の後に出した読み直しが届いてから（見ている者がいなければ応答の後すぐ）、受け付けた順に 1 回だけ、
  /// 応答の失敗の種類として返る。
  private func finish(_ index: Int, _ failure: GitHubFailure?) {
    guard violation == nil else { return }
    let first = accepted.firstIndex { $0.results == 0 }
    accepted[index].results += 1
    if accepted[index].results > 1 {
      violation = "書き込み \(index) の結果を 2 回返した"
    } else if first != index {
      violation = "書き込み \(index) の結果を、受け付けた順より先に返した"
    } else if let answeredAt = accepted[index].answeredAt {
      if watching, (answeringReadIssuedAt ?? -1) < answeredAt {
        violation = "書き込み \(index) の結果を、応答の後の読み直しが届く前に返した"
      } else if failure != accepted[index].answer {
        violation = "書き込み \(index) の結果が、応答の失敗の種類と違う"
      }
    } else {
      violation = "書き込み \(index) の結果を、応答が届く前に返した"
    }
  }

  /// 操作の後の状態。読みは見ている者がいる間だけ出て、中身とレビューのやりとりはそれぞれ 1 本ずつ。答えが一貫している種では、
  /// 読みが出尽くしたら先頭が揃っている。書き込みは 1 本ずつ受け付けた順に送られ、未送信のレビューと、受け付けた時点の先頭の
  /// コミットを正しく名指しする。走っている対象は、結果を返していない書き込みの対象。
  private func check() {
    guard violation == nil else { return }
    violation = checkReads() ?? checkAligned() ?? checkSending() ?? checkTargets()
  }

  private func checkReads() -> String? {
    let issued = gitHub.reviewReads - reads
    let issuedContent = gitHub.contentReads - contentReads
    reads = gitHub.reviewReads
    contentReads = gitHub.contentReads
    guard issued > 0 || issuedContent > 0 else { return nil }
    guard watching else { return "見ている者がいないのに問い合わせた" }
    guard gitHub.contentRequests.count <= 1 else { return "中身の読みを 2 本同時に出した" }
    guard issued > 0 else { return nil }
    guard issued == 1, readIssuedAt == nil else { return "レビューのやりとりの読みを 2 本同時に出した" }
    readIssuedAt = writeAnswers
    return nil
  }

  private func checkAligned() -> String? {
    guard consistent, watching, readIssuedAt == nil, gitHub.contentRequests.isEmpty,
      state.content?.headCommit != state.review?.headCommit
    else { return nil }
    return
      "中身の先頭 \(state.content?.headCommit ?? "無し") とレビューのやりとりの先頭 "
      + "\(state.review?.headCommit ?? "無し") が食い違ったまま、読むのをやめた"
  }

  private func checkSending() -> String? {
    guard let sending = gitHub.reviewWrites.first else { return nil }
    guard gitHub.reviewWrites.count == 1 else { return "書き込みを 2 本同時に送った" }
    guard let index = accepted.firstIndex(where: { $0.results == 0 }),
      sending.write == accepted[index].write
    else { return "受け付けた順に送っていない" }
    guard index == sent else { return nil }
    sent += 1
    guard sending.pendingReview == pendingReview else {
      return "未送信のレビューを \(pendingReview ?? "無し") でなく \(sending.pendingReview ?? "無し") と名指しした"
    }
    guard sending.reviewedCommit == accepted[index].reviewedCommit else {
      return "受け付けた時点の先頭 \(accepted[index].reviewedCommit) でなく \(sending.reviewedCommit) を添えた"
    }
    return nil
  }

  private func checkTargets() -> String? {
    for target in ["T1", "T2"] {
      let busy = unfinished.contains { Self.target(of: $0.write) == target }
      let shown = state.isWritingReview(.thread(target))
      if shown != busy { return "\(target) が走っているかの状態が \(shown) で、\(busy) でない" }
    }
    return nil
  }

  private static func target(of write: GitHubReviewWrite) -> String? {
    switch write {
    case .addThread: nil
    case .reply(let thread, _, _), .setResolved(let thread, _): thread
    case .submit: "submit"
    }
  }
}
