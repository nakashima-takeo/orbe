import AppKit

/// ⌥ だけの長押しの判定（純粋な状態機械。`OptionHoldTests` が仕様を固定する）。
///
/// - ⌥ だけになってから `delay` の間、ほかのキー・マウスの押下が無く、期限の時点でポインタが ⌥ だけになった位置から
///   `pointerTolerance` 以内にあり、修飾の実状態が ⌥ だけで、マウスのボタンが押されておらず、窓が許せば成立する。
/// - 成立中は `checkInterval` ごとに修飾の実状態で確かめ、⌥ だけでなくなれば終わる。キーの押下・⌥ 以外の修飾でも終わる。
///   成立中のマウスの押下とポインタの動きでは終わらない。
/// - 見送った押下（待ちの間の割り込み・⌥ 以外の修飾・ボタンを押したままの ⌥）と打ち切った押下は、修飾を全部離すまで次を
///   始めない。
struct OptionHoldDetector {
  /// ⌥ だけになってから成立までの間合い（秒）。
  static let delay: TimeInterval = 0.2
  /// 待ちの間に許すポインタの動き（pt）。
  static let pointerTolerance: CGFloat = 4
  /// 成立中に修飾の実状態を確かめる間隔（秒）。
  static let checkInterval: TimeInterval = 0.1

  enum Modifiers {
    case none
    case optionOnly
    /// ⌥ 以外の修飾を含む。
    case other
  }

  private enum Phase {
    case idle
    case waiting(since: TimeInterval, pointer: CGPoint)
    case holding
    /// 修飾を全部離すまで何も始めない。
    case skipped
  }
  private var phase: Phase = .idle

  var isHolding: Bool {
    if case .holding = phase { true } else { false }
  }

  /// 待ちに入った時刻。待っていなければ nil。
  var waitingSince: TimeInterval? {
    if case .waiting(let since, _) = phase { since } else { nil }
  }

  /// 修飾の変化（flagsChanged）。
  mutating func modifiersChanged(
    _ modifiers: Modifiers, mouseButtonDown: Bool, pointer: CGPoint, at time: TimeInterval
  ) {
    switch (phase, modifiers) {
    case (.idle, .optionOnly):
      phase = mouseButtonDown ? .skipped : .waiting(since: time, pointer: pointer)
    case (_, .none):
      phase = .idle
    case (_, .other):
      phase = .skipped
    case (_, .optionOnly):
      break
    }
  }

  /// キーの押下。
  mutating func keyDown() {
    interrupt()
  }

  /// 待ち・成立を打ち切る（エディターで見せるタブが替わった）。修飾を全部離すまで次を始めない。
  mutating func interrupt() {
    switch phase {
    case .waiting, .holding: phase = .skipped
    case .idle, .skipped: break
    }
  }

  /// マウスのボタンの押下。成立中は無視する。
  mutating func mouseDown() {
    if case .waiting = phase { phase = .skipped }
  }

  /// 期限。待ちに入って `delay` が過ぎていなければ何もしない。
  mutating func expire(
    at time: TimeInterval, modifiers: Modifiers, mouseButtonDown: Bool, pointer: CGPoint,
    windowAllows: Bool
  ) {
    guard case .waiting(let since, let origin) = phase, time - since >= Self.delay else { return }
    let still = hypot(pointer.x - origin.x, pointer.y - origin.y) <= Self.pointerTolerance
    phase =
      modifiers == .optionOnly && !mouseButtonDown && still && windowAllows ? .holding : .skipped
  }

  /// 成立中の確かめ。
  mutating func check(_ modifiers: Modifiers) {
    guard case .holding = phase else { return }
    switch modifiers {
    case .none: phase = .idle
    case .other: phase = .skipped
    case .optionOnly: break
    }
  }

  /// 打ち切り（窓が前面でなくなった）。
  mutating func cancel() {
    phase = .idle
  }

  /// 修飾の状態を判定の語彙へ写す。⌘⇧⌥⌃ だけを見る（capsLock・fn は見ない）。左右の ⌥ は区別しない。
  static func classify(_ flags: NSEvent.ModifierFlags) -> Modifiers {
    let significant = flags.intersection([.command, .shift, .option, .control])
    if significant.isEmpty { return .none }
    return significant == .option ? .optionOnly : .other
  }
}

/// ⌥ だけの長押しのイベントの観測と時間の管理。主窓宛ての flagsChanged・keyDown・マウスの押下を local monitor で観測し
/// （消費しない）、期限と成立中の確かめはタイマーで行う。成立・終わりのたびに `onChange` を同期して呼ぶ——keyDown で終わる
/// ときは、キーが配送される前に呼ばれる。
final class OptionHoldMonitor {
  /// OS が返す今の入力の状態。テストは差し替える。
  struct Probe {
    var modifiers: () -> NSEvent.ModifierFlags
    var mouseButtonDown: () -> Bool
    /// ポインタの位置（スクリーン座標）。
    var pointer: () -> CGPoint

    static let system = Probe(
      modifiers: { NSEvent.modifierFlags }, mouseButtonDown: { NSEvent.pressedMouseButtons != 0 },
      pointer: { NSEvent.mouseLocation })
  }

  var probe = Probe.system
  private var detector = OptionHoldDetector()
  var isHolding: Bool { detector.isHolding }

  /// 期限の時点で窓が成立を許すか（前面の窓・オーバーレイが出ていない・エディターを見せている）。
  var windowAllows: () -> Bool = { false }
  var onChange: () -> Void = {}

  private weak var window: NSWindow?
  private var monitors: [Any] = []
  private var deadline: Timer?
  private var deadlineFor: TimeInterval?
  private var checker: Timer?

  init(window: NSWindow) {
    self.window = window
    let mask: NSEvent.EventTypeMask = [
      .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: mask,
      handler: { [weak self] event in
        self?.observe(event)
        return event
      })
    {
      monitors.append(monitor)
    }
  }

  deinit {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    deadline?.invalidate()
    checker?.invalidate()
  }

  /// 打ち切る（窓が前面でなくなった）。
  func cancel() {
    update { $0.cancel() }
  }

  /// 待ち・成立を打ち切り、修飾を全部離すまで次を始めない（エディターで見せるタブが替わった）。`onChange` は呼ばない——
  /// 見せるタブを替えた窓が、続けて今の状態を描く。
  func interrupt() {
    detector.interrupt()
    syncTimers()
  }

  private func observe(_ event: NSEvent) {
    guard let window, event.window === window else { return }
    switch event.type {
    case .flagsChanged:
      let modifiers = OptionHoldDetector.classify(event.modifierFlags)
      let (buttonDown, pointer) = (probe.mouseButtonDown(), probe.pointer())
      update {
        $0.modifiersChanged(
          modifiers, mouseButtonDown: buttonDown, pointer: pointer, at: event.timestamp)
      }
    case .keyDown:
      update { $0.keyDown() }
    default:
      update { $0.mouseDown() }
    }
  }

  private func update(_ change: (inout OptionHoldDetector) -> Void) {
    let wasHolding = detector.isHolding
    change(&detector)
    syncTimers()
    if detector.isHolding != wasHolding { onChange() }
  }

  /// 待ちなら期限のタイマーを、成立中なら確かめのタイマーを設定する。メニューや窓のドラッグの間も進むよう common モードで回す。
  private func syncTimers() {
    let since = detector.waitingSince
    if since != deadlineFor {
      deadline?.invalidate()
      deadline = nil
      deadlineFor = since
      if since != nil {
        deadline = schedule(after: OptionHoldDetector.delay, repeats: false) { [weak self] in
          self?.expire()
        }
      }
    }
    if detector.isHolding, checker == nil {
      checker = schedule(after: OptionHoldDetector.checkInterval, repeats: true) { [weak self] in
        self?.check()
      }
    } else if !detector.isHolding {
      checker?.invalidate()
      checker = nil
    }
  }

  private func schedule(after interval: TimeInterval, repeats: Bool, _ fire: @escaping () -> Void)
    -> Timer
  {
    let timer = Timer(timeInterval: interval, repeats: repeats) { _ in fire() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func expire() {
    let modifiers = OptionHoldDetector.classify(probe.modifiers())
    let (buttonDown, pointer) = (probe.mouseButtonDown(), probe.pointer())
    let allows = windowAllows()
    let now = ProcessInfo.processInfo.systemUptime
    update {
      $0.expire(
        at: now, modifiers: modifiers, mouseButtonDown: buttonDown, pointer: pointer,
        windowAllows: allows)
    }
  }

  private func check() {
    let modifiers = OptionHoldDetector.classify(probe.modifiers())
    update { $0.check(modifiers) }
  }
}
