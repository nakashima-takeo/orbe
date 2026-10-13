import Foundation
import UserNotifications

/// UNUserNotificationCenter の本物。作られたときに自分を delegate に据える——窓は起動の完了より前に作られるので、止まって
/// いる間に押された通知で起動したときも、押されたことを受け取れる。
final class UserNotificationCenter: NSObject, SystemNotifying, UNUserNotificationCenterDelegate {
  var onOpenAutomation: ((Int) -> Void)?
  private let center = UNUserNotificationCenter.current()
  private static let automationKey = "automationId"

  override init() {
    super.init()
    center.delegate = self
  }

  func isAuthorized(completion: @escaping (Bool) -> Void) {
    center.getNotificationSettings { settings in
      let authorized = [.authorized, .provisional].contains(settings.authorizationStatus)
      DispatchQueue.main.async { completion(authorized) }
    }
  }

  func requestAuthorizationIfUndetermined() {
    center.getNotificationSettings { [center] settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      center.requestAuthorization(options: [.alert]) { _, _ in }
    }
  }

  func post(_ content: SystemNotificationContent, completion: @escaping (Bool) -> Void) {
    let notification = UNMutableNotificationContent()
    notification.title = content.title
    notification.body = content.body
    notification.userInfo = [Self.automationKey: content.automationId]
    let request = UNNotificationRequest(
      identifier: content.identifier, content: notification, trigger: nil)
    center.add(request) { error in
      DispatchQueue.main.async { completion(error == nil) }
    }
  }

  func remove(identifier: String) {
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
  }

  /// 前面でも出す。OS の既定では前面のアプリの通知は出ないが、見ている回の知らせはそもそも組まれない。
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo[Self.automationKey] as? Int
    DispatchQueue.main.async { [weak self] in
      if let id { self?.onOpenAutomation?(id) }
      completionHandler()
    }
  }
}
