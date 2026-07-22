import AppKit
import Sparkle

/// カスタム `SPUUserDriver`。Sparkle の UI 要求を `UpdateState` へ写像する（標準 Sparkle UI は不使用）。
///
/// フロー（既定・全トグルオン）: サイレント確認 → 自動DL＋検証（Sparkle）→ stage `.installing` で
/// `showUpdateFound` → `.dismiss` 応答（Sparkle の意味論＝終了時に自動適用）＋ `markReady` でトースト一度だけ。
///
/// 「終了時に自動で適用」オフ時は自動 staging 自体を止め（`UpdaterService` が実効
/// `automaticallyDownloadsUpdates` を落とす）、DL・検証後の `showReadyToInstallAndRelaunch` の reply を
/// **保留**する——「今すぐ再起動」だけが `.install` を返す（見本 2c「オフにすると再起動ボタンからのみ」）。
///
/// 言語モード 5・main スレッド規律。SPUUserDriver の全コールバックは main thread から呼ばれる（ヘッダ保証）。
final class UpdateUserDriver: NSObject, SPUUserDriver {
  private let state: UpdateState
  /// `showReadyToInstallAndRelaunch` の reply 保留（終了時自動適用オフのときだけ溜まる）。
  private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?
  /// 「今すぐ再起動」要求済みフラグ。dismiss 済みセッションを `checkForUpdates` で resume した際、
  /// 次の found/ready 応答を `.install` にする（Sparkle の resume 定石）。
  var installRequested = false
  /// DL 済み・staging 前の表示情報（ready 遷移時に `UpdateState.ready` へ確定する）。
  private var pendingReadyInfo: UpdateState.ReadyInfo?

  init(state: UpdateState) {
    self.state = state
  }

  /// 「今すぐ再起動」。保留中の reply があればその場で `.install` を返す（true）。
  /// 無ければ false（呼び出し側が resume 経路＝`installRequested`＋再チェックへ回す）。
  func consumePendingInstallReply() -> Bool {
    guard let reply = pendingInstallReply else { return false }
    pendingInstallReply = nil
    reply(.install)
    return true
  }

  // MARK: - SPUUserDriver

  func show(
    _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    // Info.plist の SUEnableAutomaticChecks で初回プロンプトは抑止済み。万一来ても既定方針（自動確認オン）。
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    state.beginCheck()
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state updateState: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    let info = UpdateState.ReadyInfo(
      version: appcastItem.displayVersionString,
      notes: appcastItem.itemDescription,
      date: appcastItem.date,
      size: appcastItem.contentLength)
    pendingReadyInfo = info
    switch updateState.stage {
    case .installing:
      // 既に staged（自動DL＋終了時適用オンの経路、または resume）。dismiss＝終了時に自動適用。
      state.markReady(info)
      if installRequested {
        installRequested = false
        reply(.install)
      } else {
        reply(.dismiss)
      }
    case .downloaded, .notDownloaded:
      // 背景発見かつ自動DLオフは静観（見本 2c「全オフ=通知ゼロ・完全手動」。手動確認で表へ出る）。
      if updateState.stage == .notDownloaded, !updateState.userInitiated, !state.autoDownload {
        reply(.dismiss)
      } else {
        reply(.install)  // DL・検証へ（進捗は下の download コールバックが刻む）
      }
    @unknown default:
      reply(.dismiss)
    }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    // リリースノートは appcast description（CDATA）へ埋め込む運用のため、この経路は使わない。
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    state.markUpToDate()
    acknowledgement()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    state.fail(message: error.localizedDescription)
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    state.beginDownload()
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    state.setExpectedLength(expectedContentLength)
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    state.receiveData(length: length)
  }

  func showDownloadDidStartExtractingUpdate() {}

  func showExtractionReceivedProgress(_ progress: Double) {}

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    if let info = pendingReadyInfo { state.markReady(info) }
    if installRequested {
      installRequested = false
      reply(.install)
    } else if state.autoInstallOnQuit {
      reply(.dismiss)  // Sparkle の意味論: 終了時に自動適用（トーストと状態カードが案内する）
    } else {
      pendingInstallReply = reply  // 「今すぐ再起動」まで保留（オフ時の完全手動）
    }
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func dismissUpdateInstallation() {
    pendingInstallReply = nil  // セッション破棄で無効化（呼ばずに捨てる）
    state.settleTransientPhase()
  }
}
