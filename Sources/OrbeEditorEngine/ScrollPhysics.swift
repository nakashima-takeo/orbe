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
/// - 端の外へ向かう量は、端を越えた分だけ 1/20 に縮めて当てる。端へ向かう量は縮めない（伸ばした後に戻す指はそのまま
///   効く。AppKit・WebKit と同じ）。指を離したとき端を越えていれば、そこから端へ戻る。OS の momentum が端を
///   越えたら、その時点で戻り始め、残りの momentum は次に指が触れるまで捨てる（WebKit・AppKit の形）。戻りは端からの
///   ずれ `x0` と戻り始めの速さ `v`（指を離したときは 0）から `x(τ) = (x0 + 0.31·v·τ)·e^(−τ/0.08)`（AppKit と同じ
///   式）。戻りの途中に指が触れたらそこで止まり、新しく指で動かせばその位置から動く。
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

    /// 位置 `position` で先頭に見えている行（`lineCount` 行の文書の行）と、その行が上へ隠れている割合（0…1）。端を越えて
    /// 見せている分は端で数える（俯瞰と見えている範囲は端の位置を表す）。
    func firstVisible(at position: SIMD2<Double>, lineCount: Int) -> (row: Int, hidden: Double) {
      let y = min(max(0, position.y), maximum.y)
      let row = min(Int((y / lineHeight).rounded(.down)), max(0, lineCount - 1))
      return (row, min(max((y - Double(row) * lineHeight) / lineHeight, 0), 1))
    }

    /// 位置 `position` で先頭に見えている行（小数。行 + 隠れている割合）と見えている行数——俯瞰の式の入力。
    func viewportLines(at position: SIMD2<Double>, lineCount: Int) -> (
      first: CGFloat, visible: CGFloat
    ) {
      let (row, hidden) = firstVisible(at: position, lineCount: lineCount)
      return (CGFloat(Double(row) + hidden), CGFloat(viewport.y / lineHeight))
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
    /// 指が触れている（または OS の momentum が続いている）。
    case tracking
    /// 端へ戻っている。`from` は戻り始めの見えている位置、`velocity` はその時の速さ（pt/秒）、`start` はその時刻。
    case returning(from: SIMD2<Double>, velocity: SIMD2<Double>, start: Double)
  }

  var limits = Limits()
  private var mode = Mode.idle
  /// idle・tracking のときの見えている位置。
  private var position = SIMD2<Double>(0, 0)
  private var axis = SIMD2<Double>(0, 0)
  private var lastEventTime: Double?
  /// 最後に当てた出来事から見た動く速さ（pt/秒）。
  private var velocity = SIMD2<Double>(0, 0)
  /// momentum が端を越えたか、端の外で指を離した。次に指が触れるまで momentum の出来事を捨てる。
  private var ignoresMomentum = false

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
    case .idle, .tracking:
      return position
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
      position = clamp(p)
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
        if edge(of: position.x, axis: 0) != nil || edge(of: position.y, axis: 1) != nil {
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
    position = clamp(p)
    mode = .idle
  }

  /// 範囲が変わった。止まっていれば範囲に収める。
  mutating func setLimits(_ limits: Limits) {
    self.limits = limits
    if case .idle = mode { position = clamp(position) }
  }

  private mutating func startTracking(at t: Double) {
    position = shown(at: t)
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
    for a in 0..<2 { position[a] = moved(position[a], by: -d[a], axis: a) }
    if maximum.x <= 0 { position.x = 0 }
    return true
  }

  /// 指を離した（momentum が終わった）。端を越えていれば、指の速さを持ち越さずに戻り始め、続く momentum を捨てる。
  private mutating func release(at t: Double) -> Bool {
    guard case .tracking = mode else { return false }
    let p = shown(at: t)
    if edge(of: p.x, axis: 0) != nil || edge(of: p.y, axis: 1) != nil {
      startReturning(at: t, velocity: .zero)
    } else {
      position = p
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

  /// 軸 `a` の位置 `x` を `step` だけ動かした位置。端の外へ出ていく分だけ 1/20 に縮める。
  private func moved(_ x: Double, by step: Double, axis a: Int) -> Double {
    let y = x + step
    guard let e = edge(of: y, axis: a), (y - e) * step > 0 else { return y }
    let from = (x - e) * step > 0 ? x : e
    return from + (y - from) / Self.stiffness
  }
}
