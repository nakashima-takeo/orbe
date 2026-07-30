import AppKit
import Sparkle

/// `SPUUpdater` の所有者。状態モデル（`UpdateState`）を生成・所有し、起動ゲート・トグルの永続化・
/// 「今すぐ確認/今すぐ再起動」の導線を束ねる。UI（Layout 層）は `UpdateState` だけを読む——
/// Sparkle 型はこのディレクトリの外へ出さない。
///
/// **サイレント経路（背景の定期確認・自動DL）の UI 通知は SPUUpdaterDelegate が担う**: この経路は
/// user driver を一切呼ばないため（更新が無ければ Sparkle は not-found を UI に見せず、
/// SPUAutomaticUpdateDriver は UI 無しで staging まで完了する）、通知を受けるのは delegate だけ——
/// 更新が無かったときは `updaterDidNotFindUpdate(_:error:)` が upToDate＋最終確認時刻へ、staged に
/// なったときは `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` が readyToRestart＋
/// トーストへ写像する。後者は YES を返して即時適用ハンドラを預かる（「今すぐ再起動」が UI 対話なしで
/// 即インストール＆再起動できる。終了時の自動適用はどのみち Sparkle が保証する）。
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
  /// `canCheckForUpdates` を `UpdateState.checkAvailability` へ写す KVO（生存期間はこの service）。
  private var canCheckObservation: NSKeyValueObservation?
  /// 押された「今すぐ再起動」のうち、その瞬間はどの経路も取れなかったもの。着地できる状態に
  /// なった瞬間（＝セッションが空いた / サイレント staged の即時適用ハンドラが届いた）に
  /// `drainPendingRestart` が自分で撃ち直す——フラグを置いて誰かが拾うのを待たない。
  /// 触るのは `installAndRelaunch` と `drainPendingRestart` だけ。
  var pendingRestart = false

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

    canCheckObservation = updater.observe(
      \.canCheckForUpdates, options: [.initial, .new]
    ) { [weak self] _, _ in
      DispatchQueue.main.async { self?.updaterAvailabilityDidChange() }
    }
  }

  /// `canCheckForUpdates` の変化の受け口（KVO から main で呼ばれる）。実行可否をライブに写し、
  /// セッションが空いた瞬間に預かっていた「今すぐ再起動」を消化する。
  /// 通知値ではなく現在値を読み直す（起動前後の通知が入れ違っても古い値で固まらない）。
  func updaterAvailabilityDidChange() {
    syncCanCheckNow()
    drainPendingRestart()
  }

  /// Sparkle が今コマンドを受け付けられるか。UI への写像も「今すぐ再起動」の着地判定も
  /// この 1 つの規則を読む（都度読み直すので mirror の遅れに引きずられない）。
  private var currentAvailability: UpdateState.CheckAvailability {
    .resolve(started: started, updaterCanCheck: updater.canCheckForUpdates)
  }

  /// 実行可否を状態モデルへ写す。「updater が動いていない」と「セッション進行中」は別物として
  /// 写す——前者は待っても確認が走らないので、UI に「確認中」を名乗らせない。
  private func syncCanCheckNow() {
    state.setCheckAvailability(currentAvailability)
  }

  /// 保留していた「今すぐ再起動」を撃ち直す。`installAndRelaunch` が優先順を再評価するので、
  /// まだ着地できなければそのまま再び保留に戻る（次の機会に再入する）。
  private func drainPendingRestart() {
    guard pendingRestart else { return }
    pendingRestart = false
    installAndRelaunch()
  }

  /// Sparkle の自動DLは「DL＋staging（＝終了時に必ず適用）」まで一体。終了時自動適用オフのときは
  /// staging 自体を止め、DL は発見時の driver 応答（`.install`）で行い ready の reply を保留する。
  private func syncAutomaticDownloads() {
    updater.automaticallyDownloadsUpdates = state.autoDownload && state.autoInstallOnQuit
  }

  /// 起動ゲートを通れば update サイクルを開始する（ゲート仕様は型コメント）。
  /// ゲートを通らなかった場合も可否を写す——不活性なビルドが「確認できる」ように見えたままにしない。
  func startIfPermitted() {
    defer { syncCanCheckNow() }
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

  /// 「今すぐ確認」（設定・メニュー・再試行の単一導線）。UI が読む可否と同じ規則で弾く。
  func checkForUpdates() {
    guard currentAvailability == .available else { return }
    updater.checkForUpdates()
  }

  /// 「今すぐ再起動」。着地先を `RestartLanding` が一意に決め、押下は必ずそのどれかに着地する。
  ///
  /// `resumeCheck` の `installRequested` は `checkForUpdates()` の直前に立てて同じ turn でセッションを
  /// 起こす。そのセッションは user-initiated＝abort が必ず `dismissUpdateInstallation` を通る
  /// （`SPUUserInitiatedUpdateDriver` は `showErrorToUser:YES` で abort する）ため、消費されるか
  /// 破棄されるかのどちらかで必ずセッション内に決着する＝要求がセッション境界を越えて残らない。
  func installAndRelaunch() {
    let landing = RestartLanding.resolve(
      hasRetryTermination: driver.hasRetryTermination,
      hasImmediateInstall: immediateInstallHandler != nil,
      hasPendingInstallReply: driver.hasPendingInstallReply,
      availability: currentAvailability)
    switch landing {
    case .retryTermination:
      driver.retryTermination()
    case .immediateInstall:
      immediateInstallHandler?()
    case .pendingInstallReply:
      driver.consumePendingInstallReply()
    case .resumeCheck:
      driver.installRequested = true
      updater.checkForUpdates()
    case .hold:
      pendingRestart = true
    case .inactive:
      break  // updater 不活性なら phase が readyToRestart にならず到達しない
    }
  }
}

extension UpdaterService {
  /// 「今すぐ再起動」の着地先。押下時点で取れる経路を優先順に 1 つ選ぶ——押下が落ちる先を
  /// 網羅列挙することで「どこにも着地しない」経路が存在しないことを型で示す。
  ///
  /// 再送ハンドラを最優先にするのは、それが立つのは生きたセッションが我々の終了を待つ間だけで、
  /// そこで他へ回すと同じ更新へ二重の適用要求を出すため。
  enum RestartLanding: Equatable {
    /// 終了確認をキャンセルしたセッションへ終了要求を送り直す。
    case retryTermination
    /// サイレント staged の即時適用ハンドラを呼ぶ（UI 対話なしで再起動）。
    case immediateInstall
    /// 保留中の ready reply へ `.install` を返す（終了時自動適用オフの手動経路）。
    case pendingInstallReply
    /// dismiss 済みセッションを resume して適用させる（自分でセッションを起こす）。
    case resumeCheck
    /// セッション進行中でどれも取れない。押下を預かり、空いた瞬間に自分で撃ち直す。
    case hold
    /// updater が動いていない（この状態では再起動ボタン自体が出ない）。
    case inactive

    static func resolve(
      hasRetryTermination: Bool, hasImmediateInstall: Bool, hasPendingInstallReply: Bool,
      availability: UpdateState.CheckAvailability
    ) -> RestartLanding {
      if hasRetryTermination { return .retryTermination }
      if hasImmediateInstall { return .immediateInstall }
      switch availability {
      case .unavailable: return .inactive
      case .available: return hasPendingInstallReply ? .pendingInstallReply : .resumeCheck
      // 進行中は新しいセッションを起こせない。保留 reply があればそこへ、無ければ預かる——
      // 「セッションが staged 更新へ行き着いたら誰かが拾う」式のフラグを残さない。
      case .busy: return hasPendingInstallReply ? .pendingInstallReply : .hold
      }
    }
  }
}

extension UpdaterService: SPUUpdaterDelegate {
  /// 確認が終わり、適用できる更新が無かった。upToDate＋最終確認時刻へ写像する。
  ///
  /// Sparkle は全ドライバ（背景の定期確認・自動DL・ユーザー主導・probing）の not-found をここへ通知する
  /// ので、この 1 本でサイレント経路の「確認した」が状態モデルへ届く。ユーザー主導の「今すぐ確認」では
  /// user driver の `showUpdateNotFoundWithError`（確認したことを acknowledge する側）も同じ写像を行う
  /// が、`markUpToDate` は冪等（phase と最終確認時刻の再代入）なので二重に走って構わない。
  ///
  /// 2 版あるうち `error:` 付きを実装するのは、Sparkle が両方実装されていればこちらを優先して呼ぶため
  /// （引数なし版はこれを実装しないクライアント向けのフォールバック）。理由（`SPUNoUpdateFoundReasonKey`）
  /// は読まない——状態カードは「確認した／更新は無かった」の 1 通りしか表さない。
  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    state.markUpToDate()
  }

  /// バックグラウンド自動DLが staging を終えた（サイレント経路で更新が見つかったときの通知）。
  /// readyToRestart＋トーストへ写像し、YES で即時適用ハンドラを預かる。YES はこの更新が pending の間
  /// 後続の update サイクルも止める（staged 済みに対する無意味な再チェックを塞ぐ）。
  /// 終了時の自動適用は返値に依らず Sparkle が行う。
  ///
  /// YES を返すとサイレント経路のセッションは生きたまま残る（Sparkle はここで abort しない）ため、
  /// `canCheckForUpdates` は真へ戻らない＝ KVO 側の消化が来ない。保留していた「今すぐ再起動」が
  /// 着地できるのはこの瞬間だけなので、ここでも消化する（ハンドラはデリゲートの戻り後に呼ぶ）。
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    state.markReady(UpdateState.ReadyInfo(item))
    self.immediateInstallHandler = immediateInstallHandler
    DispatchQueue.main.async { [weak self] in self?.drainPendingRestart() }
    return true
  }
}
