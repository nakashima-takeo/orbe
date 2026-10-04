import XCTest

@testable import Orbe

/// 結び付いた GitHub の項目の値の置き場（`GitHubItemCache`）の、取り直し・足りない分だけの取得・合流・
/// 失敗の据え置き。gh は叩かず、撃たれた取得の答えを手で着地させる。
///
/// 壊れると何が起きるか: 開くたびに前回の値が消えると、⌘⇧X の行が毎回番号だけから描き直しになる。
/// 失敗で値を消すと、オフラインになった途端に分かっていたタイトルや状態が消える。試行を覚えないと、gh の
/// 無い環境で、打鍵のたびに gh を起こし続ける。取得中の項目を重ねて頼むと、同じ問い合わせが積み上がる。
@MainActor
final class GitHubItemCacheTests: OrbeTestCase {
  /// 撃たれた取得の、頼まれた項目と答え口を溜める。
  private final class PendingFetches {
    private(set) var requested: [Set<GitHubItemID>] = []
    private var batches: [([GitHubItemID], GitHubItemsBatch?) -> Void] = []

    var fetch: GitHubItemCache.Fetch {
      { ids, batch in
        self.requested.append(Set(ids))
        self.batches.append(batch)
      }
    }

    func answer(
      _ index: Int, _ ids: [GitHubItemID], _ batch: GitHubItemsBatch?,
      file: StaticString = #filePath, line: UInt = #line
    ) {
      guard batches.indices.contains(index) else {
        return XCTFail("\(index + 1) 本目の取得は撃たれていない", file: file, line: line)
      }
      batches[index](ids, batch)
    }
  }

  private let a = GitHubItemID(repo: "o/n", number: 1)!
  private let b = GitHubItemID(repo: "o/n", number: 2)!
  private let c = GitHubItemID(repo: "x/y", number: 3)!

  private func found(_ title: String) -> GitHubItemAnswer {
    .found(GitHubItemSummary(title: title, state: .open, pullRequest: nil))
  }

  private func batch(_ answers: [GitHubItemID: GitHubItemAnswer], viewer: String? = "me")
    -> GitHubItemsBatch
  {
    GitHubItemsBatch(viewerLogin: viewer, answers: answers)
  }

  func testRefreshAsksForTheItemsAndStoresEachQuerysAnswersAsTheyArrive() {
    let fetches = PendingFetches()
    let cache = GitHubItemCache(fetch: fetches.fetch)

    cache.refresh([a, b])
    XCTAssertEqual(fetches.requested, [[a, b]])

    fetches.answer(0, [a], batch([a: found("A")]))
    XCTAssertEqual(cache.answers, [a: found("A")], "先に届いた回の答えから持つ")
    XCTAssertEqual(cache.viewerLogin, "me")
    fetches.answer(0, [b], batch([b: .missing]))
    XCTAssertEqual(cache.answers, [a: found("A"), b: .missing])
  }

  /// 開き直したときは、前回の答えで先に描き、新しい答えが届いたら置き換える。
  func testRefreshKeepsThePreviousAnswerUntilTheNewOneArrives() {
    let fetches = PendingFetches()
    let cache = GitHubItemCache(answers: [a: found("古い")], viewerLogin: "me", fetch: fetches.fetch)

    cache.refresh([a])
    XCTAssertEqual(cache.answers[a], found("古い"))

    fetches.answer(0, [a], batch([a: found("新しい")]))
    XCTAssertEqual(cache.answers[a], found("新しい"))
  }

  /// gh が無い・未認証・オフラインで失敗した回は、それまでの答えと自分の login を据え置く。
  func testAFailedQueryKeepsWhatWasKnown() {
    let fetches = PendingFetches()
    let cache = GitHubItemCache(answers: [a: found("A")], viewerLogin: "me", fetch: fetches.fetch)

    cache.refresh([a, b])
    fetches.answer(0, [a, b], nil)

    XCTAssertEqual(cache.answers, [a: found("A")])
    XCTAssertEqual(cache.viewerLogin, "me")
  }

  /// `ensure` は答えも試行も無い項目だけを頼む。取れなかった項目は次の `refresh` まで頼み直さない。
  func testEnsureAsksOnlyForUntriedItemsUntilTheNextRefresh() {
    let fetches = PendingFetches()
    let cache = GitHubItemCache(answers: [a: found("A")], fetch: fetches.fetch)

    cache.ensure([a, b])
    XCTAssertEqual(fetches.requested, [[b]], "答えのある項目は頼まない")
    fetches.answer(0, [b], nil)

    cache.ensure([a, b, c])
    XCTAssertEqual(fetches.requested.last, [c], "取れなかった項目は ensure では頼み直さない")
    fetches.answer(1, [c], batch([c: .missing]))

    cache.refresh([a, c])
    XCTAssertEqual(fetches.requested.last, [a, c], "refresh は渡した項目を全部取り直す")
    cache.ensure([b])
    XCTAssertEqual(fetches.requested.last, [b], "refresh の後は、取れなかった項目も ensure が頼み直す")
  }

  /// 取得中の項目は、`refresh` でも `ensure` でも重ねて頼まない。
  func testItemsBeingFetchedAreNotAskedForAgain() {
    let fetches = PendingFetches()
    let cache = GitHubItemCache(fetch: fetches.fetch)

    cache.refresh([a])
    cache.ensure([a])
    cache.refresh([a, b])
    XCTAssertEqual(fetches.requested, [[a], [b]])

    fetches.answer(0, [a], batch([a: found("A")]))
    cache.refresh([a])
    XCTAssertEqual(fetches.requested.last, [a], "答えが届いた後は取り直せる")
  }
}
