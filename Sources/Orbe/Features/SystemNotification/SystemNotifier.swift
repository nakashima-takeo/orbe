import Foundation

/// 知らせを通知センターへ出す形。識別子が同じ通知は、通知センターで前のものを差し替える。
struct SystemNotificationContent: Equatable {
  let identifier: String
  let title: String
  let body: String
  /// 押されたときに開く自動化。
  let automationId: Int
}

/// macOS の通知センター。許可は覚えず、問うたびに OS へ尋ねる——背面の間にシステム設定で切られても外さないため。
/// 答え（completion）と押された通知（`onOpenAutomation`）は main で届く。
protocol SystemNotifying: AnyObject {
  /// 押された通知が持つ自動化。
  var onOpenAutomation: ((Int) -> Void)? { get set }
  /// 許可済み・仮の許可なら true。未確認・拒否なら false。
  func isAuthorized(completion: @escaping (Bool) -> Void)
  /// 未確認のときだけ OS に許可を求める。答えは待たない——許可されたかは次に知らせるときの `isAuthorized` で分かる。
  func requestAuthorizationIfUndetermined()
  /// 無音で出す。出せたかを返す。
  func post(_ content: SystemNotificationContent, completion: @escaping (Bool) -> Void)
  func remove(identifier: String)
}

/// 通知センターの部品の生成点。テストの隔離ハーネスがここを差し替える。
enum SystemNotifierOutput {
  nonisolated(unsafe) static var makeOverride: (() -> SystemNotifying)?

  /// 本物はアプリのバンドルとして動いているときだけ作る——UNUserNotificationCenter はアプリのバンドルの無いプロセス
  /// （`swift run`・テスト）で触れると例外で落ちる。テストの実行体（xctest）も埋め込みの Info.plist で bundle id を持つので、
  /// bundle id ではなく種類（APPL）で見分ける。
  static func make() -> SystemNotifying {
    if let makeOverride { return makeOverride() }
    guard Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
    else { return UnavailableSystemNotifier() }
    return UserNotificationCenter()
  }
}

/// 通知センターを使えない起動。いつも許可が無いので、知らせはピルへ回る。
final class UnavailableSystemNotifier: SystemNotifying {
  var onOpenAutomation: ((Int) -> Void)?

  func isAuthorized(completion: @escaping (Bool) -> Void) { completion(false) }
  func requestAuthorizationIfUndetermined() {}
  func post(_ content: SystemNotificationContent, completion: @escaping (Bool) -> Void) {
    completion(false)
  }
  func remove(identifier: String) {}
}
