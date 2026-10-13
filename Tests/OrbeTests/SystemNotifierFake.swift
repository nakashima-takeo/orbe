import Foundation

@testable import Orbe

/// 通知センターの部品のフェイク。許可の状態を持ち、出した・取り下げた・許可を求めたことを記録する。答えはその場で返す。
/// 隔離ハーネス（`TestIsolation.beginCase`）が既定の部品としてこれを差す。
final class SystemNotifierFake: SystemNotifying {
  enum Authorization { case undetermined, denied, authorized }

  var onOpenAutomation: ((Int) -> Void)?
  var authorization = Authorization.undetermined
  var postSucceeds = true
  private(set) var posted: [SystemNotificationContent] = []
  private(set) var removed: [String] = []
  private(set) var requestCount = 0

  func isAuthorized(completion: @escaping (Bool) -> Void) {
    completion(authorization == .authorized)
  }

  func requestAuthorizationIfUndetermined() {
    if authorization == .undetermined { requestCount += 1 }
  }

  func post(_ content: SystemNotificationContent, completion: @escaping (Bool) -> Void) {
    if postSucceeds { posted.append(content) }
    completion(postSucceeds)
  }

  func remove(identifier: String) { removed.append(identifier) }
}
