import Foundation
import Observation

/// gh で認証している自分の login（@Observable・main のみ・アプリで 1 つ）。GitHub への問い合わせが答えに
/// 載せて返すたびに書き、画面は「自分」の判定（レビュー・担当・作成者）をここから引く。メモリにだけ持つ。
@Observable final class GitHubViewer {
  static let shared = GitHubViewer()

  /// nil = まだ答えを得ていない。
  private(set) var login: String?

  init(login: String? = nil) {
    self.login = login
  }

  func record(_ login: String) {
    if self.login != login { self.login = login }
  }

}
