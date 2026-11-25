import Foundation
import WebKit

/// `WKWebsiteDataStore` の唯一の生成口。
/// 隔離環境（`StateDir.isIsolated`）では `.default()` や `forIdentifier:` を評価せず
/// 非永続ストアを返し、`~/Library/WebKit/` への書き込みを防ぐ。
enum BrowserDataStore {
  @MainActor
  static func make(
    isolated: Bool = StateDir.isIsolated, identifier: UUID? = nil
  ) -> WKWebsiteDataStore {
    if isolated {
      return .nonPersistent()
    }
    if let identifier {
      return WKWebsiteDataStore(forIdentifier: identifier)
    }
    return .default()
  }
}
