import AppKit
import os
import simd

/// スクロールの出来事 1 つ（main が `NSEvent` から写した値）。量は `scrollingDelta` のまま（正は本文が下・右へ動く向き）。
struct ScrollInput: Sendable {
  enum Phase: Sendable {
    case none, mayBegin, began, changed, ended, cancelled
  }

  var timestamp: Double
  var delta: SIMD2<Double>
  /// トラックパッドなど、画素単位の量を持つ出来事か（マウスのホイールは行単位で false）。
  var precise: Bool
  var phase: Phase
  var momentum: Phase

  init(
    timestamp: Double, delta: SIMD2<Double>, precise: Bool, phase: Phase = .none,
    momentum: Phase = .none
  ) {
    self.timestamp = timestamp
    self.delta = delta
    self.precise = precise
    self.phase = phase
    self.momentum = momentum
  }

  @MainActor
  init(_ event: NSEvent) {
    self.init(
      timestamp: event.timestamp,
      delta: SIMD2(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY)),
      precise: event.hasPreciseScrollingDeltas, phase: Phase(event.phase),
      momentum: Phase(event.momentumPhase))
  }
}

extension ScrollInput.Phase {
  init(_ phase: NSEvent.Phase) {
    if phase.contains(.mayBegin) {
      self = .mayBegin
    } else if phase.contains(.began) {
      self = .began
    } else if phase.contains(.changed) {
      self = .changed
    } else if phase.contains(.ended) {
      self = .ended
    } else if phase.contains(.cancelled) {
      self = .cancelled
    } else {
      self = .none
    }
  }
}

/// スクロールの規則（値型の純粋な状態機械）。位置は本文の左上からのずれ（pt）。
///
/// - 指の出来事（トラックパッド）の量は 1 倍でその場で位置に足す。OS の momentum の出来事も同じ経路を通り、補間・予測・
///   自前の慣性は持たない。
/// - 動かす軸は、120ms で減衰する縦横の量の累積の大きい方だけ（主でない軸の量は捨てる）。
/// - 弾性が有効なら、端を越えた量は 1/20 に縮めて見せる。指を離したとき端を越えていれば、そこから端へ戻る。OS の
///   momentum が端を越えたら、その時点で戻り始め、残りの momentum は次に指が触れるまで捨てる（WebKit・AppKit の形）。
///   戻りは端からのずれ `x0` と戻り始めの速さ `v`（指を離したときは 0）から `x(τ) = (x0 + 0.31·v·τ)·e^(−τ/0.08)`
///   （AppKit と同じ式）。戻りの途中に指が触れたらそこで止まる。無効なら端で止める。
/// - マウスのホイールは 1 目盛り（量 1）を 10pt として、その場で当てる（NSScrollView の行送りと同じ）。
struct ScrollPhysics: Sendable {
  /// 範囲を決める値。縦は最終行が最上段に来るまで、横は見たことのある最も長い行の右端から 5 桁先まで。
  struct Limits: Equatable, Sendable {
    var lineCount = 1
    var lineHeight: Double = 1
    /// 本文の見えている大きさ（行番号の列と上端の余白を除く）。
    var viewport = SIMD2<Double>(0, 0)
    /// 見たことのある最も長い行の幅（組版した行から伸びるだけ）。
    var longestLine: Double = 0
    /// 1 桁の幅。
    var cell: Double = 7

    var maximum: SIMD2<Double> {
      SIMD2(
        max(0, longestLine + ScrollPhysics.trailingColumns * cell - viewport.x),
        max(0, Double(lineCount - 1) * lineHeight))
    }
  }

  static let stiffness = 20.0
  static let returnTime = 0.08
  /// 戻りの式の速さの項の係数。
  static let returnVelocity = 0.31
  static let axisDecay = 0.12
  static let wheelStep = 10.0
  static let trailingColumns = 5.0
  /// 戻りを端に揃えて終える近さ（pt）。
  private static let settleDistance = 0.1

  private enum Mode: Sendable {
    case idle
    /// 指が触れている（または OS の momentum が続いている）。`raw` は弾性を掛ける前の位置。
    case tracking
    /// 端へ戻っている。`from` は戻り始めの見えている位置、`velocity` はその時の速さ（pt/秒）、`start` はその時刻。
    case returning(from: SIMD2<Double>, velocity: SIMD2<Double>, start: Double)
  }

  var limits = Limits()
  let elastic: Bool
  private var mode = Mode.idle
  /// idle のときの位置、tracking のときの弾性を掛ける前の位置。
  private var raw = SIMD2<Double>(0, 0)
  private var axis = SIMD2<Double>(0, 0)
  private var lastEventTime: Double?
  /// 最後に当てた出来事から見た動く速さ（pt/秒）。
  private var velocity = SIMD2<Double>(0, 0)
  /// momentum が端を越えたか、端の外で指を離した。次に指が触れるまで momentum の出来事を捨てる。
  private var ignoresMomentum = false

  init(elastic: Bool) {
    self.elastic = elastic
  }

  var maximum: SIMD2<Double> { limits.maximum }

  /// 描画スレッドだけが進める動き（端への戻り）の途中か。
  var isReturning: Bool {
    if case .returning = mode { return true }
    return false
  }

  /// 指が触れているか、端へ戻っている途中か。
  var isActive: Bool {
    if case .idle = mode { return false }
    return true
  }

  /// 時刻 `t` に見せる位置。
  func shown(at t: Double) -> SIMD2<Double> {
    switch mode {
    case .idle:
      return raw
    case .tracking:
      return SIMD2(rubber(raw.x, axis: 0), rubber(raw.y, axis: 1))
    case .returning(let from, let velocity, let start):
      let tau = max(0, t - start)
      var p = from
      for a in 0..<2 {
        guard let edge = edge(of: from[a], axis: a) else { continue }
        p[a] =
          edge + (from[a] - edge + Self.returnVelocity * velocity[a] * tau)
          * exp(-tau / Self.returnTime)
      }
      return p
    }
  }

  /// 戻りが済んでいれば端に揃えて止める。
  mutating func settle(at t: Double) {
    guard case .returning(let from, _, let start) = mode else { return }
    let tau = t - start
    guard tau > Self.returnTime else { return }
    let p = shown(at: t)
    let done = (0..<2).allSatisfy { a in
      edge(of: from[a], axis: a).map { abs(p[a] - $0) < Self.settleDistance } ?? true
    }
    if done {
      raw = clamp(p)
      mode = .idle
    }
  }

  /// 出来事を当てる。見えている位置が変わりうるなら true。
  @discardableResult
  mutating func apply(_ input: ScrollInput) -> Bool {
    let t = input.timestamp
    if input.momentum != .none {
      guard !ignoresMomentum else { return false }
      switch input.momentum {
      case .began, .changed:
        if case .tracking = mode {} else { startTracking(at: t) }
        guard drag(input) else { return false }
        if elastic, edge(of: raw.x, axis: 0) != nil || edge(of: raw.y, axis: 1) != nil {
          startReturning(at: t, velocity: velocity)
        }
        return true
      case .ended, .cancelled:
        return release(at: t)
      case .none, .mayBegin:
        return false
      }
    }
    guard input.precise else {
      place(shown(at: t) - input.delta * Self.wheelStep)
      return true
    }
    switch input.phase {
    case .mayBegin:
      ignoresMomentum = false
      guard isReturning else { return false }
      startTracking(at: t)
      return true
    case .began:
      ignoresMomentum = false
      startTracking(at: t)
      return drag(input)
    case .changed:
      if case .tracking = mode {} else { startTracking(at: t) }
      return drag(input)
    case .ended, .cancelled:
      return release(at: t)
    case .none:
      place(shown(at: t) - input.delta)
      return true
    }
  }

  /// その場で位置を置く（main の操作・ホイール）。範囲に収め、戻りを打ち切る。
  mutating func place(_ p: SIMD2<Double>) {
    raw = clamp(p)
    mode = .idle
  }

  /// 範囲が変わった。止まっていれば範囲に収める。
  mutating func setLimits(_ limits: Limits) {
    self.limits = limits
    if case .idle = mode { raw = clamp(raw) }
  }

  private mutating func startTracking(at t: Double) {
    let p = shown(at: t)
    raw = SIMD2(unrubber(p.x, axis: 0), unrubber(p.y, axis: 1))
    axis = .zero
    mode = .tracking
  }

  private mutating func drag(_ input: ScrollInput) -> Bool {
    var d = input.delta
    let elapsed = lastEventTime.map { input.timestamp - $0 }
    if let elapsed { axis *= exp(-max(0, elapsed) / Self.axisDecay) }
    lastEventTime = input.timestamp
    axis += SIMD2(abs(d.x), abs(d.y))
    if axis.y >= axis.x { d.x = 0 } else { d.y = 0 }
    if let elapsed, elapsed > 0 { velocity = -d / elapsed }
    guard d != .zero else { return false }
    raw -= d
    if maximum.x <= 0 { raw.x = 0 }
    if !elastic { raw = clamp(raw) }
    return true
  }

  /// 指を離した（momentum が終わった）。端を越えていれば、指の速さを持ち越さずに戻り始め、続く momentum を捨てる。
  private mutating func release(at t: Double) -> Bool {
    guard case .tracking = mode else { return false }
    let p = shown(at: t)
    if edge(of: p.x, axis: 0) != nil || edge(of: p.y, axis: 1) != nil {
      startReturning(at: t, velocity: .zero)
    } else {
      raw = p
      mode = .idle
    }
    return true
  }

  /// 今見えている位置から端へ戻り始める。速さは端の外へ向かう分だけ持ち越す。
  private mutating func startReturning(at t: Double, velocity v: SIMD2<Double>) {
    let p = shown(at: t)
    var outward = SIMD2<Double>(0, 0)
    for a in 0..<2 {
      guard let e = edge(of: p[a], axis: a), (p[a] - e) * v[a] > 0 else { continue }
      outward[a] = v[a]
    }
    mode = .returning(from: p, velocity: outward, start: t)
    ignoresMomentum = true
  }

  private func clamp(_ p: SIMD2<Double>) -> SIMD2<Double> {
    simd_clamp(p, .zero, simd_max(maximum, .zero))
  }

  /// 端を越えていればその端。
  private func edge(of x: Double, axis a: Int) -> Double? {
    if x < 0 { return 0 }
    if x > maximum[a] { return maximum[a] }
    return nil
  }

  private func rubber(_ x: Double, axis a: Int) -> Double {
    guard let e = edge(of: x, axis: a) else { return x }
    return elastic ? e + (x - e) / Self.stiffness : e
  }

  private func unrubber(_ x: Double, axis a: Int) -> Double {
    guard let e = edge(of: x, axis: a) else { return x }
    return elastic ? e + (x - e) * Self.stiffness : e
  }
}

/// スクロールの状態の箱。main が出来事を書き、描画スレッドがコマの時刻で位置を読む。鍵の中では値の読み書きだけをする。
final class ScrollBox: Sendable {
  /// 描画スレッドがコマの時刻で読んだもの。
  struct Frame: Sendable {
    var position: SIMD2<Double>
    /// 描画スレッドだけが進める動き（戻り）の途中か。
    var returning: Bool
    /// このコマで初めて入った指の出来事の時刻。
    var events: [Double]
    var gesture: Int
    var revision: Int
  }

  private struct State {
    var physics: ScrollPhysics
    var revision = 0
    var gesture = 0
    var pendingEvents: [Double] = []
  }

  private let state: OSAllocatedUnfairLock<State>

  init(elastic: Bool) {
    state = OSAllocatedUnfairLock(initialState: State(physics: ScrollPhysics(elastic: elastic)))
  }

  /// 出来事を当てる。見えている位置が変わりうるなら true。
  func apply(_ input: ScrollInput) -> Bool {
    state.withLock { s in
      if input.phase == .began { s.gesture += 1 }
      guard s.physics.apply(input) else { return false }
      s.revision += 1
      if input.precise, input.phase != .mayBegin { s.pendingEvents.append(input.timestamp) }
      return true
    }
  }

  func place(_ p: SIMD2<Double>) {
    state.withLock { s in
      s.physics.place(p)
      s.revision += 1
    }
  }

  func updateLimits(_ body: @Sendable (inout ScrollPhysics.Limits) -> Void) {
    state.withLock { s in
      var limits = s.physics.limits
      body(&limits)
      guard limits != s.physics.limits else { return }
      s.physics.setLimits(limits)
      s.revision += 1
    }
  }

  /// 見たことのある最も長い行を伸ばす（縮めない）。
  func noteLine(width: Double) {
    state.withLock { s in
      guard width > s.physics.limits.longestLine else { return }
      var limits = s.physics.limits
      limits.longestLine = width
      s.physics.setLimits(limits)
      s.revision += 1
    }
  }

  /// 描画スレッドがコマの時刻で読む。このコマで初めて入った出来事を引き取る。
  func frame(at t: Double) -> Frame {
    state.withLock { s in
      s.physics.settle(at: t)
      let events = s.pendingEvents
      s.pendingEvents.removeAll(keepingCapacity: true)
      return Frame(
        position: s.physics.shown(at: t), returning: s.physics.isReturning, events: events,
        gesture: s.gesture, revision: s.revision)
    }
  }

  /// 出来事を引き取らずに、今の位置を読む（main の問い合わせ・撮影）。
  func peek(at t: Double) -> (position: SIMD2<Double>, limits: ScrollPhysics.Limits) {
    state.withLock { s in (s.physics.shown(at: t), s.physics.limits) }
  }

  /// 描くものが変わったかを、出来事を引き取らずに見る。
  var revision: Int { state.withLock { $0.revision } }

}
