import XCTest

@testable import Orbe

/// PR ごとの状態が持つレビューへの書き込みを、書き込み・読み直し・それぞれの応答・見ている者の出入り・PR への push が入り乱れる
/// 順序で、種を決めた乱数により実行する。どの順序でも、書き込みの規則（pull-request.md の「レビューのやりとり」）が保たれる。
/// PR の中身とレビューのやりとりが読んだ先頭のコミットを揃える読み直しは、際限なく続くことはなく、手順を終えて読み直しを
/// 頼めば、両方が GitHub の今の先頭で揃う。食い違いで読み直すこと自体は `PullRequestStateTests+Review` が守る。
///
/// 壊れると何が起きるか: 書き込みの結果が返らないままになり、そのスレッドへの返信やレビューの送信が、アプリを再起動するまで
/// できなくなる。書き込みの応答が届くより前に問い合わせた読みの応答を取り込み、書いたコメントが消えて見える・失敗の文が
/// 残る。2 回押した送信が 2 回送られる。承認が、利用者の見ていないコミットに付く。push の後、GitHub への問い合わせが止まらない。
/// 失敗した種と手順はメッセージに出る（同じ種で回せば同じ手順になる）。
extension PullRequestStateTests {
  func testInterleavedWritesAndRereadsKeepTheWriteRules() throws {
    for seed: UInt64 in 1...40 {
      gitHub = PullRequestFakeGitHub()
      key = PullRequestState.Key(
        commonDir: "/tmp/\(UUID().uuidString)",
        id: try XCTUnwrap(GitHubItemID(repo: "o/r", number: 7)))
      let state = PullRequestState.shared(for: key, source: gitHub.source)
      state.beginWatching()
      addTeardownBlock { @MainActor in state.endWatching() }
      gitHub.content = .success(content(head: "h0"))
      state.reload()
      gitHub.answersReviewAtOnce = false

      let run = ReviewWriteRun(
        state: state, gitHub: gitHub, seed: seed, content: { self.content(head: $0) })
      run.play(steps: 80)
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
  private var random: SplitMix
  private var accepted: [Accepted] = []
  private var sent = 0
  /// 届いた書き込みの応答の数。
  private var writeAnswers = 0
  /// 走っている読みを出した時点の `writeAnswers`。
  private var readIssuedAt: Int?
  private var reads: Int
  private var contentReads: Int
  private var watching = true
  /// GitHub 上の PR の先頭のコミットと、その 1 つ前（答えの遅れた読みが返す）。
  private var head = "h0"
  private var previousHead: String?
  private var pushes = 0
  /// 次に送る書き込みが名指しすべき保留中のレビュー（最後に取り込んだ読みか、その後の書き込みの応答で分かったもの）。
  private var pendingReview: String?
  /// 今の操作で届いた読みを出した時点の `writeAnswers`（読みの応答を返す操作の間だけ）。
  private var answeringReadIssuedAt: Int?
  private var tag = 0
  private(set) var log: [String] = []
  private(set) var violation: String?

  init(
    state: PullRequestState, gitHub: PullRequestFakeGitHub, seed: UInt64,
    content: @escaping (String) -> GitHubPullRequestContent
  ) {
    self.state = state
    self.gitHub = gitHub
    self.content = content
    random = SplitMix(seed: seed)
    reads = gitHub.reviewReads
    contentReads = gitHub.contentReads
  }

  func play(steps: Int) {
    for _ in 0..<steps where violation == nil {
      switch random.next(below: 12) {
      case 0..<3: write()
      case 3:
        log.append("reload")
        state.reload()
      case 4..<7:
        answerRead(failing: random.next(below: 4) == 0, lagging: random.next(below: 4) == 0)
      case 7..<10: answerWrite()
      case 10: toggleWatching()
      default: push()
      }
      check()
    }
  }

  /// 見ている者を戻して読み直しを頼み、走っている読みと書き込みに、応答が尽きるまで遅れの無い成功を返す。受け付けた書き込みは、
  /// どれも 1 回だけ結果を返し、中身とレビューのやりとりは GitHub の今の先頭で揃う。
  func drain() {
    if !watching { toggleWatching() }
    state.reload()
    check()
    for _ in 0..<200 where violation == nil {
      if readIssuedAt != nil {
        answerRead(failing: false, lagging: false)
      } else if !gitHub.reviewWrites.isEmpty {
        answerWrite(failing: false)
      } else {
        break
      }
      check()
    }
    guard violation == nil else { return }
    if let index = accepted.firstIndex(where: { $0.results != 1 }) {
      violation = "受け付けた書き込み \(index) が、応答が尽きても結果を返さない"
    } else if state.content?.headCommit != head || state.review?.headCommit != head {
      violation =
        "中身の先頭 \(state.content?.headCommit ?? "無し") とレビューのやりとりの先頭 "
        + "\(state.review?.headCommit ?? "無し") が、GitHub の先頭 \(head) で揃わない"
    }
  }

  // MARK: - 操作

  private func write() {
    let seen = state.review?.headCommit ?? ""
    let writes: [GitHubReviewWrite] = [
      .reply(thread: "T1", body: "x", resolve: false), .setResolved(thread: "T1", true),
      .reply(thread: "T2", body: "x", resolve: true), .submit(.approve, body: ""),
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
    let taken = state.writeReview(write) { [weak self] in self?.finish(index, $0) }
    log.append("write(\(Self.target(of: write) ?? "new"))=\(taken)")
    guard taken == expected else {
      violation = taken ? "受け付けてはいけない書き込みを受け付けた" : "受け付けるべき書き込みを拒否した"
      return
    }
    if taken { accepted.append(Accepted(write: write, reviewedCommit: seen)) }
  }

  private func answerRead(failing: Bool, lagging: Bool) {
    guard let issuedAt = readIssuedAt else { return }
    tag += 1
    let pending = random.next(below: 2) == 0 ? "P\(tag)" : nil
    let read = GitHubPullRequestReview(
      viewer: "r\(tag)", viewerIsAuthor: false,
      headCommit: lagging ? previousHead ?? head : head,
      pendingReview: pending.map { .init(id: $0, commentCount: 1) }, threads: [])
    gitHub.review = failing ? .failure(.unreachable) : .success(read)
    log.append("answerRead(\(failing ? "失敗" : lagging ? "遅れ" : "成功"))")
    let before = (state.review, state.reviewFailure)
    let current = issuedAt == writeAnswers
    readIssuedAt = nil
    answeringReadIssuedAt = issuedAt
    gitHub.answerReview()
    answeringReadIssuedAt = nil
    if !current {
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
    gitHub.content = .success(content(head))
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

  /// 操作の後の状態。読みは見ている者がいる間だけ出て、レビューのやりとりの読みは 1 本ずつで、1 回の操作で問い合わせが続かない。
  /// 書き込みは 1 本ずつ受け付けた順に送られ、保留中のレビューと、受け付けた時点の先頭のコミットを正しく名指しする。走っている
  /// 対象は、結果を返していない書き込みの対象。レビューのやりとりの読みの失敗は、中身の失敗に入らない。
  private func check() {
    guard violation == nil else { return }
    violation =
      checkReads() ?? checkSending() ?? checkTargets()
      ?? (state.failure == nil ? nil : "レビューのやりとりの読みの失敗が、中身の失敗に入った")
  }

  private func checkReads() -> String? {
    let issued = gitHub.reviewReads - reads
    let issuedContent = gitHub.contentReads - contentReads
    reads = gitHub.reviewReads
    contentReads = gitHub.contentReads
    guard issued > 0 || issuedContent > 0 else { return nil }
    guard watching else { return "見ている者がいないのに問い合わせた" }
    guard issuedContent <= 3 else { return "中身の問い合わせが止まらない（1 回の操作で \(issuedContent) 回）" }
    guard issued > 0 else { return nil }
    guard issued == 1, readIssuedAt == nil else { return "レビューのやりとりの読みを 2 本同時に出した" }
    readIssuedAt = writeAnswers
    return nil
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
      return "保留中のレビューを \(pendingReview ?? "無し") でなく \(sending.pendingReview ?? "無し") と名指しした"
    }
    guard sending.reviewedCommit == accepted[index].reviewedCommit else {
      return "受け付けた時点の先頭 \(accepted[index].reviewedCommit) でなく \(sending.reviewedCommit) を添えた"
    }
    return nil
  }

  private func checkTargets() -> String? {
    for target in ["T1", "T2", "submit"] {
      let busy = unfinished.contains { Self.target(of: $0.write) == target }
      let shown = state.isWritingReview(target == "submit" ? .submission : .thread(target))
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
