import AppKit
import Sparkle

/// `SPUUpdater` の所有者。状態モデル（`UpdateState`）を生成・所有し、起動ゲート・トグルの永続化・
/// 「今すぐ確認/今すぐ再起動」の導線を束ねる。UI（Layout 層）は `UpdateState` だけを読む——
/// Sparkle 型はこのディレクトリの外へ出さない。
///
/// **サイレント自動DL経路の UI 通知は SPUUpdaterDelegate が担う**: Sparkle のバックグラウンド自動DLは
/// user driver を一切呼ばず（SPUAutomaticUpdateDriver は UI 無しで staging まで完了する）、staged に
/// なった瞬間 `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` だけが通知される。
/// ここで readyToRestart＋トーストへ写像し、YES を返して即時適用ハンドラを預かる（「今すぐ再起動」が
/// UI 対話なしで即インストール＆再起動できる。終了時の自動適用はどのみち Sparkle が保証する）。
///
/// 起動ゲート:
/// - `.app` 以外（テスト・素の `swift build` バイナリ）は Info.plist に `SUFeedURL` が無く常に不活性。
/// - dev ビルド（`ORBE_RELEASE` 未定義）は defaults/起動引数の `SUFeedURL` 上書きがあるときだけ開始する
///   （dev/sandbox インスタンスが GitHub へ確認に行かない。localhost appcast でのテストは可能）。
/// - release ビルドは常に開始。
///
/// 言語モード 5・main スレッド規律（プロジェクト方針: libghostty 同様、明示ディスパッチで扱う）。
/// SPUUpdater の API は main thread 前提で、呼び出し元（WindowController/AppDelegate）は常に main。
final class UpdaterService: NSObject {
  let state: UpdateState
  let driver: UpdateUserDriver
  private var updater: SPUUpdater!  // delegate=self のため super.init 後に生成（以降 不変）
  private(set) var started = false
  /// サイレント staged 更新の即時適用ハンドラ（willInstallUpdateOnQuit で預かる）。
  /// 終了確認でユーザーが終了を取りやめた場合に再実行できるよう、呼んだ後も保持する（Sparkle 2.3+）。
  private var immediateInstallHandler: (() -> Void)?

  /// Orbe 側トグルの永続キー（Sparkle が持たない「終了時自動適用」と、実効値と分離した「自動DL」の生値）。
  private static let autoInstallOnQuitKey = "OrbeUpdateAutoInstallOnQuit"
  private static let autoDownloadKey = "OrbeUpdateAutoDownload"

  override init() {
    let state = UpdateState(
      currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "0")
    self.state = state
    driver = UpdateUserDriver(state: state)
    super.init()
    updater = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)

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
    #if !ORBE_RELEASE
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

  /// 「今すぐ再起動」。押下は必ずどれかに着地する。優先順:
  /// ① 終了要求の再送（終了確認をキャンセルしたセッションが我々の終了を待っている）
  /// ② サイレント staged の即時適用ハンドラ（UI 対話なしで再起動）
  /// ③ 保留中の ready reply へ `.install`（終了時自動適用オフの手動経路）
  /// ④ 適用要求を立てる。確認できるなら dismiss 済みセッションを resume し、できないなら進行中の
  ///    セッションが staged 更新へ行き着いた時点で driver / delegate が `.install` を返す。
  ///
  /// ① が最優先なのは、再送ハンドラが立つのは生きたセッションが終了を待つ間だけで、そこで ②③④ に
  /// 回すと同じ更新へ二重の適用要求を出すため。
  func installAndRelaunch() {
    if driver.retryTermination() { return }
    if let immediateInstallHandler {
      immediateInstallHandler()
      return
    }
    guard started else { return }  // updater 不活性なら phase が readyToRestart にならず到達しない
    if driver.consumePendingInstallReply() { return }
    driver.installRequested = true
    if updater.canCheckForUpdates { updater.checkForUpdates() }
  }
}

extension UpdaterService: SPUUpdaterDelegate {
  /// バックグラウンド自動DLが staging を終えた（サイレント経路で UI に通知が来る唯一の瞬間）。
  /// readyToRestart＋トーストへ写像し、YES で即時適用ハンドラを預かる。YES はこの更新が pending の間
  /// 後続の update サイクルも止める（staged 済みに対する無意味な再チェックを塞ぐ）。
  /// 終了時の自動適用は返値に依らず Sparkle が行う。
  ///
  /// サイレント経路は user driver を通らない＝`dismissUpdateInstallation` が来ないため、ここが
  /// `installRequested`（適用要求）の終端になる。立っていれば要求を消費して即時適用へ繋ぐ
  /// （ハンドラはデリゲートの戻り後に呼ぶ）。
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    state.markReady(UpdateState.ReadyInfo(item))
    self.immediateInstallHandler = immediateInstallHandler
    if driver.installRequested {
      driver.installRequested = false
      DispatchQueue.main.async { immediateInstallHandler() }
    }
    return true
  }
}
