import Foundation
import Observation

/// アプリ内アップデートの UI 状態モデル（UI の唯一の情報源・Sparkle 非依存）。
/// トースト（AppShell）・変更内容シート・設定パレットの「アップデート」セクションの 3 面がこれだけを読む。
/// Sparkle との接続は `UpdaterService`/`UpdateUserDriver` が担い、コールバック（`on*`）で双方向に橋渡す。
/// Sparkle 非依存のため、テスト・gallery/flow fixture は実 updater なしで全状態を注入できる。
@Observable final class UpdateState {
  /// Sparkle のセッションで何が起きたか。状態カードはこの 6 ケースを 7 通りに見せる——
  /// idle は「このセッションでまだ何も起きていない」で、確認の可否（`CheckAvailability`）によって
  /// 「まだ確認していない」と「このビルドでは確認しない」の 2 通りに分かれる。
  enum Phase: Equatable {
    case idle
    case checking
    case downloading(received: UInt64, total: UInt64)
    case upToDate
    case failed(message: String)
    case readyToRestart
  }

  /// 「今すぐ確認」の実行可否と、実行できないときの理由。可否だけの Bool では
  /// 「updater が動いていない」と「セッションが進行中」が同じ false に潰れ、UI が
  /// 走ってもいない確認を名乗ってしまうため、理由まで持つ。
  enum CheckAvailability: Equatable {
    /// 今すぐ確認を走らせられる。
    case available
    /// Sparkle のセッションが進行中（自分の確認・DL・背景の定期確認・staged の resume）。
    /// 待てば `available` へ戻る。
    case busy
    /// updater が動いていない（起動ゲートを通らなかったビルド）。確認は走らないままになる。
    case unavailable

    /// updater の起動状態と Sparkle の受付可否から決める（Sparkle 型を持ち込まない Bool 2 つ）。
    static func resolve(started: Bool, updaterCanCheck: Bool) -> CheckAvailability {
      guard started else { return .unavailable }
      return updaterCanCheck ? .available : .busy
    }
  }

  /// 適用待ちの更新の表示情報（変更内容シート・トースト・状態カードが読む）。
  struct ReadyInfo: Equatable {
    var version: String  // 表示バージョン（"0.2.0"。"v" 前置は表示側）
    var notes: String?  // appcast description（Markdown。§変更内容シートが描画）
    var date: Date?
    var size: UInt64  // バイト数（0 = 不明）
  }

  private(set) var phase: Phase = .idle
  private(set) var ready: ReadyInfo?
  /// DL 中に表示する版（found 時点で判る）。`ready` と別なのは、DL 中断時に `settleTransientPhase` が
  /// `.idle` へ畳めるようにするため——`ready` を DL 前に埋めると中断が readyToRestart へ化ける。
  private(set) var downloadVersion: String?
  private(set) var lastCheck: Date?
  /// トースト可視。readyToRestart への遷移時に **1 バージョンにつき一度だけ** 立つ（見本 2a の設計注記）。
  private(set) var toastVisible = false
  private var toastShownVersion: String?
  /// 「今すぐ確認」の実行可否（`UpdaterService` が写す）。fixture は既定 `.available` のまま
  /// 全状態を注入できる。
  private(set) var checkAvailability: CheckAvailability = .available
  /// 「今すぐ確認」を実行してよいか（導線のゲート）。理由まで要る表示側は `checkAvailability` を読む。
  var canCheckNow: Bool { checkAvailability == .available }

  /// 現在のバージョン（`CFBundleShortVersionString`。fixture は任意注入）。
  let currentVersion: String

  // トグル 3 種（既定は全オン）。自動確認/自動DL は UpdaterService が Sparkle の永続値と同期し、
  // 終了時自動適用は Orbe 側 UserDefaults に永続する。didSet で backend へ流す（同値代入は流さない）。
  var autoCheck = true {
    didSet { if autoCheck != oldValue { onAutoCheckChange(autoCheck) } }
  }
  var autoDownload = true {
    didSet { if autoDownload != oldValue { onAutoDownloadChange(autoDownload) } }
  }
  var autoInstallOnQuit = true {
    didSet { if autoInstallOnQuit != oldValue { onAutoInstallChange(autoInstallOnQuit) } }
  }

  // MARK: - 導線コールバック（UpdaterService / WindowController が配線する）
  var onAutoCheckChange: (Bool) -> Void = { _ in }
  var onAutoDownloadChange: (Bool) -> Void = { _ in }
  var onAutoInstallChange: (Bool) -> Void = { _ in }
  /// 「今すぐ確認」（設定・App メニューの「更新を確認…」・失敗カードの「再試行」が共用する単一導線）。
  var onCheckNow: () -> Void = {}
  /// 「今すぐ再起動」/「再起動して更新」（トースト・状態カード・シートが共用）。
  var onRestartNow: () -> Void = {}
  /// 「変更内容」（トースト・状態カード → シート提示。WindowController が配線）。
  var onShowChanges: () -> Void = {}
  /// シートの「閉じる」/Esc/scrim（WindowController が配線）。
  var onCloseChanges: () -> Void = {}

  /// 変更内容シートの focus トリガ（overlay 遷移で first responder を確定させる。他 overlay と同型）。
  var changesFocusToken = 0
  func focusChanges() { changesFocusToken &+= 1 }

  init(currentVersion: String) {
    self.currentVersion = currentVersion
  }

  // MARK: - 遷移（UpdateUserDriver のコールバックが駆動する）

  func beginCheck() { phase = .checking }

  func setCheckAvailability(_ availability: CheckAvailability) {
    checkAvailability = availability
  }

  func beginDownload(version: String? = nil) {
    downloadVersion = version
    phase = .downloading(received: 0, total: 0)
  }

  func setExpectedLength(_ total: UInt64) {
    if case .downloading(let received, _) = phase {
      phase = .downloading(received: received, total: total)
    } else {
      phase = .downloading(received: 0, total: total)
    }
  }

  func receiveData(length: UInt64) {
    guard case .downloading(let received, let total) = phase else { return }
    let next = received + length
    phase = .downloading(received: total > 0 ? min(next, total) : next, total: total)
  }

  func markUpToDate(at date: Date = Date()) {
    phase = .upToDate
    lastCheck = date
  }

  func fail(message: String, at date: Date = Date()) {
    phase = .failed(message: message)
    lastCheck = date
  }

  /// 再起動待ちへ。トーストは同一バージョンにつき一度だけ立てる（再確認・resume で再表示しない）。
  func markReady(_ info: ReadyInfo, at date: Date = Date()) {
    ready = info
    phase = .readyToRestart
    lastCheck = date
    if toastShownVersion != info.version {
      toastShownVersion = info.version
      toastVisible = true
    }
  }

  func dismissToast() { toastVisible = false }

  /// セッション終了（Sparkle の dismissUpdateInstallation）。進行中の見かけ（確認中・DL中）だけを畳む。
  /// 確定状態（最新・失敗・適用待ち）は残す——設定の状態カードが「真実の置き場」（見本 2c）。
  func settleTransientPhase() {
    switch phase {
    case .checking:
      phase = .idle
    case .downloading:
      phase = ready != nil ? .readyToRestart : .idle
    case .idle, .upToDate, .failed, .readyToRestart:
      break
    }
  }

  /// 初期表示用。update サイクルを開始したときだけ Sparkle の永続値から入れる
  /// （確認が走るビルドだけが最終確認時刻を持つ）。
  func seedLastCheck(_ date: Date?) {
    if lastCheck == nil { lastCheck = date }
  }
}
