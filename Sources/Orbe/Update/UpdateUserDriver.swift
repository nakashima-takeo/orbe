import AppKit
import Sparkle

extension UpdateState.ReadyInfo {
  /// appcast item → 表示情報（driver の found/ready 経路と UpdaterService のサイレント staged 経路が共有）。
  init(_ item: SUAppcastItem) {
    self.init(
      version: item.displayVersionString, notes: item.itemDescription, date: item.date,
      size: item.contentLength)
  }
}

/// カスタム `SPUUserDriver`。Sparkle の UI 要求を `UpdateState` へ写像する（標準 Sparkle UI は不使用）。
///
/// **バックグラウンドの自動DL（既定・全トグルオン）はこの driver を通らない**——Sparkle の
/// SPUAutomaticUpdateDriver は UI 無しで staging まで完了し、`UpdaterService` の
/// `willInstallUpdateOnQuit`（SPUUpdaterDelegate）だけが通知を受けて readyToRestart へ写像する。
/// この driver に stage `.installing` の `showUpdateFound` が来るのは **staged 済み更新の resume**
/// （staged のまま再起動した後の確認・「今すぐ再起動」の再チェック経路）で、`.dismiss` 応答
/// （Sparkle の意味論＝終了時に自動適用）＋ `markReady` で状態カードとトーストに乗せる。
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
  /// `UpdaterService` が resume を起こす直前にだけ立てるため、有効なのは自分で起こしたその
  /// セッションの中だけ——消費されるか `dismissUpdateInstallation` で破棄されるかで必ず決着する。
  var installRequested = false
  /// DL 済み・staging 前の表示情報（ready 遷移時に `UpdateState.ready` へ確定する）。
  private var pendingReadyInfo: UpdateState.ReadyInfo?
  /// アプリが終了要求に応じなかったとき Sparkle が渡す再送ハンドラ。何度でも呼べる（SPUUserDriver.h）
  /// ので呼んだ後も保持し、セッション終了（`dismissUpdateInstallation`）でだけ破棄する。
  private var retryTerminationHandler: (() -> Void)?

  init(state: UpdateState) {
    self.state = state
  }

  /// 保留中の ready reply があるか（`consumePendingInstallReply` の可否を副作用なしで問う）。
  var hasPendingInstallReply: Bool { pendingInstallReply != nil }

  /// 終了要求を待っているセッションがあるか（`retryTermination` の可否を副作用なしで問う）。
  var hasRetryTermination: Bool { retryTerminationHandler != nil }

  /// 保留中の ready reply へ `.install` を返す（終了時自動適用オフの手動経路）。
  func consumePendingInstallReply() {
    guard let reply = pendingInstallReply else { return }
    pendingInstallReply = nil
    reply(.install)
  }

  /// 終了要求を待っているセッションへ終了要求を送り直す。
  func retryTermination() {
    retryTerminationHandler?()
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
    let info = UpdateState.ReadyInfo(appcastItem)
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
    state.beginDownload(version: pendingReadyInfo?.version)  // found 時の版を DL カードへ渡す
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

  /// インストーラが終了要求を出した。アプリが未終了（＝終了確認をキャンセルした）なら再送ハンドラを
  /// 預かり、「今すぐ再起動」の押し直しで終了要求を送り直せるようにする。
  /// 既に終了済み（`applicationTerminated == true`）のときは呼んではならない（SPUUserDriver.h）ため保持しない。
  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    retryTerminationHandler = applicationTerminated ? nil : retryTerminatingApplication
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func dismissUpdateInstallation() {
    pendingInstallReply = nil  // セッション破棄で無効化（呼ばずに捨てる）
    retryTerminationHandler = nil  // 終了要求の再送先もこのセッション限り
    installRequested = false  // resume 要求もセッション終了で破棄（消費されず残ると次サイクルを無操作 install させる）
    state.settleTransientPhase()
  }
}
