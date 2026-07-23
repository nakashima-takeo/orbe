import AppKit
import ApplicationServices

/// ⌘ 素タップ×2 の判定（pure 状態機械。`CmdDoubleTapTests` が仕様を固定する）。
///
/// - 素タップ = 「修飾なし → ⌘ のみ → 修飾なし」の遷移で、押下↔解放の間に keyDown・mouseDown・
///   他修飾ビットが挟まらないこと（⌘C・⌘Tab 等の速い連打で誤発火しない）。
/// - 発火 = 素タップ 2 回。間隔は 1 回目の解放 → 2 回目の解放で測り、上限は
///   `maxReleaseInterval`（~300ms 指定の解釈・定数 1 箇所）。**2 回目の解放で発火**する。
///   ⌘ の長押し自体は素タップ性を壊さない（間隔は解放同士で測る）。
/// - 発火後・不成立後は状態をリセットする。他修飾が見えたら全修飾の解放まで再開しない。
struct CmdDoubleTapDetector {
  /// 1 回目の解放 → 2 回目の解放の許容間隔（秒）。
  static let maxReleaseInterval: TimeInterval = 0.35

  /// 修飾状態の分類（AppKit 非依存でテスト可能にする入力語彙）。
  enum Modifiers {
    case none  // 有意な修飾なし
    case commandOnly  // ⌘ のみ
    case other  // ⌘ 以外の修飾を含む（⌘ 併用も含む）
  }

  private enum Phase {
    case idle
    case firstDown  // 1 回目の ⌘ 押下中
    case awaitingSecond(firstReleaseAt: TimeInterval)  // 1 回目解放済み・2 回目待ち
    case secondDown(firstReleaseAt: TimeInterval)  // 2 回目の ⌘ 押下中
    case poisoned  // 他修飾が見えた。全修飾の解放（.none）まで何も始めない
  }
  private var phase: Phase = .idle

  /// flagsChanged の観測。発火条件が成立したら true（呼び出し側がトグル等を実行する）。
  mutating func flagsChanged(_ modifiers: Modifiers, at t: TimeInterval) -> Bool {
    switch (phase, modifiers) {
    case (_, .other):
      phase = .poisoned
    case (.poisoned, .none):
      phase = .idle
    case (.poisoned, .commandOnly):
      break  // 解放前に ⌘ が残った/加わった。全解放までは開始しない
    case (.idle, .commandOnly):
      phase = .firstDown
    case (.idle, .none):
      break
    case (.firstDown, .none):
      phase = .awaitingSecond(firstReleaseAt: t)
    case (.firstDown, .commandOnly):
      break  // 同値の連続通知は無視
    case (.awaitingSecond(let t1), .commandOnly):
      phase = .secondDown(firstReleaseAt: t1)
    case (.awaitingSecond, .none):
      break
    case (.secondDown(let t1), .none):
      if t - t1 <= Self.maxReleaseInterval {
        phase = .idle
        return true
      }
      // 遅すぎた解放は「新しい 1 回目の解放」として次のタップを待つ（3 連打でも自然に成立）。
      phase = .awaitingSecond(firstReleaseAt: t)
    case (.secondDown, .commandOnly):
      break
    }
    return false
  }

  /// keyDown の観測。押下↔解放・タップ間のどこに挟まっても不成立（リセット）。
  /// ⌘ が押下中（修飾が残っている）なら全解放待ちへ。
  mutating func keyDown() { interrupt() }

  /// mouseDown の観測。keyDown と同じ扱い。
  mutating func mouseDown() { interrupt() }

  private mutating func interrupt() {
    switch phase {
    case .firstDown, .secondDown:
      phase = .poisoned  // ⌘ 押下中の割り込み（⌘C 等）。⌘ 解放を新たな開始にしない
    case .awaitingSecond:
      phase = .idle
    case .idle, .poisoned:
      break
    }
  }

  /// NSEvent の修飾フラグを判定語彙へ写す。capsLock・fn 等の非意図フラグは無視し、
  /// ⌘⇧⌥⌃ だけを有意な修飾として見る。
  static func classify(_ flags: NSEvent.ModifierFlags) -> Modifiers {
    let significant = flags.intersection([.command, .shift, .option, .control])
    if significant.isEmpty { return .none }
    return significant == .command ? .commandOnly : .other
  }
}

/// ⌘⌘ の NSEvent monitor 管理。local（Orbe 前面時・権限不要）と global（背面時・要権限）の
/// 2 面で使い、detector の状態はインスタンスごとに独立する（local は自アプリ・global は
/// 他アプリのイベントのみを受けるため、二重発火は構造的に起きない）。
final class CmdDoubleTapMonitor {
  enum Scope { case local, global }

  private var detector = CmdDoubleTapDetector()
  private var monitors: [Any] = []
  private let onFire: () -> Void

  /// global 監視（keyDown 含む）が届く権限があるか。Accessibility か Input Monitoring の
  /// どちらかで届く（同じ TCC ゲート）。付与/剥奪の反映は呼び出し側が activation 契機で再評価する。
  static var globalMonitoringPermitted: Bool {
    AXIsProcessTrusted() || CGPreflightListenEventAccess()
  }

  init(scope: Scope, onFire: @escaping () -> Void) {
    self.onFire = onFire
    let flagsMask: NSEvent.EventTypeMask = .flagsChanged
    let interruptMask: NSEvent.EventTypeMask = [
      .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    switch scope {
    case .local:
      // 観測のみ（イベントはそのまま返し、アプリの通常処理を妨げない）。
      if let m = NSEvent.addLocalMonitorForEvents(
        matching: flagsMask,
        handler: { [weak self] in
          self?.observeFlags($0)
          return $0
        })
      {
        monitors.append(m)
      }
      if let m = NSEvent.addLocalMonitorForEvents(
        matching: interruptMask,
        handler: { [weak self] in
          self?.detector.keyDown()
          return $0
        })
      {
        monitors.append(m)
      }
    case .global:
      if let m = NSEvent.addGlobalMonitorForEvents(
        matching: flagsMask,
        handler: { [weak self] in
          self?.observeFlags($0)
        })
      {
        monitors.append(m)
      }
      if let m = NSEvent.addGlobalMonitorForEvents(
        matching: interruptMask,
        handler: { [weak self] _ in
          self?.detector.keyDown()
        })
      {
        monitors.append(m)
      }
    }
  }

  deinit {
    for m in monitors { NSEvent.removeMonitor(m) }
  }

  private func observeFlags(_ event: NSEvent) {
    if detector.flagsChanged(
      CmdDoubleTapDetector.classify(event.modifierFlags), at: event.timestamp)
    {
      onFire()
    }
  }
}
