import OrbeTestSupport
import XCTest

@testable import Orbe

/// 一度引けた PR の引き直しの失敗——問い合わせの失敗と「GitHub のどのリポジトリか確かめられない」では PR を保って理由だけを
/// 持ち、gh が無い・未ログイン・GitHub でない・成功の答えで open の PR が無いときは答えを替える。
///
/// 壊れると何が起きるか: fetch や push の後の引き直しが回数制限・不通で失敗するたびに、パネルから PR が消え、PR の中身の
/// 追従も止まる。失敗が直った後も失敗の文が残る。gh を消した・ログアウトした・PR を閉じたのに、古い PR が出続ける。
extension BranchPullRequestTests {
  /// 問い合わせの失敗と確かめられない答えでは、同じ PR を保って見続け、理由を持つ。次に引けたら理由は消える。
  func testAFailedLookUpKeepsThePullRequestAndHoldsTheReason() throws {
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { pullRequest.state?.content != nil }, "前提: PR の中身が届く")
    let state = try XCTUnwrap(pullRequest.state)
    let opened = answers["feat"]

    let failures: [(GitHubBranchPullRequests.Branch, BranchPullRequest.Unavailable)] = [
      (
        .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .failure(.rateLimited)),
        .failed(.rateLimited)
      ),
      (.unavailable(.unverified), .unverified),
    ]
    for (answer, reason) in failures {
      answers["feat"] = answer
      pullRequest.reload()
      pumpMain(until: { pullRequest.lookupFailure == reason }, "\(reason) を理由に持つ")
      XCTAssertEqual(pullRequest.answer, .pullRequest(state), "\(reason): PR を保つ")
      XCTAssertTrue(state.isWatched, "\(reason): PR の状態を見続ける")
    }

    answers["feat"] = opened
    pullRequest.reload()
    pumpMain(until: { pullRequest.lookupFailure == nil }, "引けたら理由は消える")
    XCTAssertEqual(pullRequest.answer, .pullRequest(state))
  }

  /// 引き直しの最中に見ている者が去り、その問い合わせが失敗で答えても、理由を持たない（去った後の答えは出さない）。
  func testAFailureArrivingAfterTheLastWatcherLeftHoldsNoReason() throws {
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { pullRequest.state?.content != nil }, "前提: PR の中身が届く")
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .failure(.rateLimited))
    holdsLookups = true
    pullRequest.reload()
    pumpMain(until: { self.held.count == 1 }, "前提: 引き直しの問い合わせの最中")
    pullRequest.endWatching()
    holdsLookups = false
    releaseLookups()
    XCTAssertNil(pullRequest.lookupFailure)
  }

  /// 引き直しの最中も見ている者が居れば、失敗の答えが届いたその場で理由を持つ（去った後に届いた失敗との対）。
  func testAFailureArrivingWhileWatchedHoldsTheReasonAtOnce() throws {
    let pullRequest = try watchAnOpenPullRequest()
    pumpMain(until: { pullRequest.state?.content != nil }, "前提: PR の中身が届く")
    answers["feat"] = .gitHub(
      GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .failure(.rateLimited))
    holdsLookups = true
    pullRequest.reload()
    pumpMain(until: { self.held.count == 1 }, "前提: 引き直しの問い合わせの最中")
    holdsLookups = false
    releaseLookups()
    XCTAssertEqual(
      pullRequest.lookupFailure, .failed(.rateLimited),
      "失敗を返した直後に理由を持つ。これが待たずに成り立たなくなったら、"
        + "testAFailureArrivingAfterTheLastWatcherLeftHoldsNoReason の確かめる時点も成り立たない")
  }

  /// gh が無い・未ログイン・GitHub でない答えと、成功の答えで open の PR が無いときは、PR を保たずに答えを替え、前の PR を
  /// 見るのをやめる。
  func testAnAnswerThatRulesThePullRequestOutReplacesIt() throws {
    let replacements: [(GitHubBranchPullRequests.Branch, (BranchPullRequest.Answer) -> Bool)] = [
      (.unavailable(.ghMissing), { $0 == .unavailable(.ghMissing) }),
      (.unavailable(.ghUnauthed), { $0 == .unavailable(.ghUnauthed) }),
      (.unavailable(.notGitHub), { $0 == .unavailable(.notGitHub) }),
      (
        .gitHub(GitHubBranchRef(repo: me, branch: "feat"), pullRequests: .success([])),
        { if case .noPullRequest = $0 { true } else { false } }
      ),
    ]
    let pullRequest = try watchAnOpenPullRequest()
    let opened = answers["feat"]
    for (answer, replaced) in replacements {
      answers["feat"] = opened
      pullRequest.reload()
      pumpMain(until: { pullRequest.state?.content != nil }, "前提: PR が出る")
      let state = try XCTUnwrap(pullRequest.state)

      answers["feat"] = answer
      pullRequest.reload()
      pumpMain(until: { replaced(pullRequest.answer) }, "\(answer) で答えを替える")
      XCTAssertNil(pullRequest.lookupFailure)
      XCTAssertFalse(state.isWatched, "前の PR を見るのをやめる")
    }
  }
}
