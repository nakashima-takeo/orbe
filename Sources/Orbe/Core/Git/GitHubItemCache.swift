import Foundation
import Observation

/// 結び付いた GitHub の項目の値の置き場（@Observable・main のみ・アプリで 1 つ）。値は保存せずメモリにだけ
/// 持ち、次に開いたときは前回の答えで先に描く。取得の失敗（gh が無い・未認証・時間切れ・オフライン）は、
/// それまでの答えを据え置くだけで外に出さない。
///
/// 取りに行く入口は 2 つ。`refresh` は渡した項目を取り直して試行の記録を始め直し、`ensure` は前回の
/// `refresh` 以降にまだ試していない項目だけを取る（答えがあっても、この開いている間に試していなければ取る）。
/// 進行中の取得に含まれる項目は重ねて頼まない（合流）。試行の記録は次の `refresh` まで残すので、取れなかった
/// 項目を `ensure` は叩き直さない（gh の無い環境で、画面の変化のたびに gh を起こさない）。
@Observable final class GitHubItemCache {
  static let shared = GitHubItemCache(fetch: GitHubCLI.shared.items)

  /// 項目の列を問い合わせ、1 回ごとにその回の ID と答え（nil = その回の失敗）をメインで返す取得。
  /// 渡した ID はどれも、いずれかの回でちょうど 1 回返す（gh が無い・失敗したときは、その回を取れなかったとして返す）。
  typealias Fetch = (
    _ ids: [GitHubItemID], _ batch: @escaping ([GitHubItemID], GitHubItemsBatch?) -> Void
  ) -> Void

  /// 項目ごとの答え。キーが無い＝まだ答えを得ていない。
  private(set) var answers: [GitHubItemID: GitHubItemAnswer]
  /// gh で認証しているアカウントの login。
  private(set) var viewerLogin: String?
  private var inFlight: Set<GitHubItemID> = []
  private var tried: Set<GitHubItemID> = []
  @ObservationIgnored private let fetch: Fetch

  init(
    answers: [GitHubItemID: GitHubItemAnswer] = [:], viewerLogin: String? = nil,
    fetch: @escaping Fetch
  ) {
    self.answers = answers
    self.viewerLogin = viewerLogin
    self.fetch = fetch
  }

  /// まだ答えが無い項目について、答えを待っている（まだ試していないか、取得中）か。試して取れなかったなら
  /// false（gh が無い・失敗。次の `refresh` まで取りに行かない）。
  func isAwaitingAnswer(_ id: GitHubItemID) -> Bool {
    answers[id] == nil && (inFlight.contains(id) || !tried.contains(id))
  }

  /// 取り直す。前回の答えは、新しい答えが届くまで残す。
  func refresh(_ ids: Set<GitHubItemID>) {
    tried = inFlight
    request(ids.subtracting(inFlight))
  }

  /// 前回の `refresh` 以降にまだ試していない項目だけを取る。
  func ensure(_ ids: Set<GitHubItemID>) {
    request(ids.filter { !tried.contains($0) && !inFlight.contains($0) })
  }

  private func request(_ ids: Set<GitHubItemID>) {
    guard !ids.isEmpty else { return }
    inFlight.formUnion(ids)
    tried.formUnion(ids)
    fetch(Array(ids)) { [weak self] batchIDs, batch in
      guard let self else { return }
      inFlight.subtract(batchIDs)
      guard let batch else { return }
      if let login = batch.viewerLogin { viewerLogin = login }
      answers.merge(batch.answers) { $1 }
    }
  }
}
