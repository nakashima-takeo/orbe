import AppKit
import Sparkle

/// `SPUUpdater` の所有者。状態モデル（`UpdateState`）を生成・所有し、起動ゲート・トグルの永続化・
/// 「今すぐ確認/今すぐ再起動」の導線を束ねる。UI（Layout 層）は `UpdateState` だけを読む——
/// Sparkle 型はこのディレクトリの外へ出さない。
///
/// 起動ゲート:
/// - `.app` 以外（テスト・素の `swift build` バイナリ）は Info.plist に `SUFeedURL` が無く常に不活性。
/// - dev ビルド（`ORBE_DEV`）は defaults/起動引数の `SUFeedURL` 上書きがあるときだけ開始する
///   （dev/sandbox インスタンスが GitHub へ確認に行かない。localhost appcast でのテストは可能）。
/// - release ビルドは常に開始。
///
/// 言語モード 5・main スレッド規律（プロジェクト方針: libghostty 同様、明示ディスパッチで扱う）。
/// SPUUpdater の API は main thread 前提で、呼び出し元（WindowController/AppDelegate）は常に main。
final class UpdaterService {
  let state: UpdateState
  private let driver: UpdateUserDriver
  private let updater: SPUUpdater
  private(set) var started = false

  /// Orbe 側トグルの永続キー（Sparkle が持たない「終了時自動適用」と、実効値と分離した「自動DL」の生値）。
  private static let autoInstallOnQuitKey = "OrbeUpdateAutoInstallOnQuit"
  private static let autoDownloadKey = "OrbeUpdateAutoDownload"

  init() {
    let state = UpdateState(
      currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "0")
    self.state = state
    driver = UpdateUserDriver(state: state)
    updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)

    // トグル初期値: 自動確認は Sparkle の永続値（SUEnableAutomaticChecks で既定オン）、
    // 自動DL/終了時適用は Orbe 側 defaults（未設定は既定オン）。
    let defaults = UserDefaults.standard
    state.autoCheck = updater.automaticallyChecksForUpdates
    state.autoDownload = defaults.object(forKey: Self.autoDownloadKey) as? Bool ?? true
    state.autoInstallOnQuit = defaults.object(forKey: Self.autoInstallOnQuitKey) as? Bool ?? true
    state.seedLastCheck(updater.lastUpdateCheckDate)
    syncAutomaticDownloads()

    state.onAutoCheckChange = { [weak self] on in
      self?.updater.automaticallyChecksForUpdates = on
    }
    state.onAutoDownloadChange = { [weak self] on in
      UserDefaults.standard.set(on, forKey: Self.autoDownloadKey)
      self?.syncAutomaticDownloads()
    }
    state.onAutoInstallChange = { [weak self] on in
      UserDefaults.standard.set(on, forKey: Self.autoInstallOnQuitKey)
      self?.syncAutomaticDownloads()
    }
    state.onCheckNow = { [weak self] in self?.checkForUpdates() }
    state.onRestartNow = { [weak self] in self?.installAndRelaunch() }
  }

  /// Sparkle の自動DLは「DL＋staging（＝終了時に必ず適用）」まで一体。終了時自動適用オフのときは
  /// staging 自体を止め、DL は発見時の driver 応答（`.install`）で行い ready の reply を保留する。
  private func syncAutomaticDownloads() {
    updater.automaticallyDownloadsUpdates = state.autoDownload && state.autoInstallOnQuit
  }

  /// 起動ゲートを通れば update サイクルを開始する（ゲート仕様は型コメント）。
  func startIfPermitted() {
    guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
    #if ORBE_DEV
      guard UserDefaults.standard.string(forKey: "SUFeedURL") != nil else { return }
    #endif
    do {
      try updater.start()
      started = true
    } catch {
      state.fail(message: error.localizedDescription)
    }
  }

  /// 「今すぐ確認」（設定・メニュー・再試行の単一導線）。
  func checkForUpdates() {
    guard started, updater.canCheckForUpdates else { return }
    updater.checkForUpdates()
  }

  /// 「今すぐ再起動」。reply 保留中ならその場で `.install`、dismiss 済みなら resume（再チェック）で
  /// stage `.installing` に入り直し、driver が `.install` を返す。
  func installAndRelaunch() {
    guard started else { return }
    if driver.consumePendingInstallReply() { return }
    driver.installRequested = true
    updater.checkForUpdates()
  }
}
