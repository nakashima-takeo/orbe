import AppKit
import os
import simd

/// スクロールの状態の箱。main が出来事を書き、描画スレッドがコマの時刻で位置を読む。鍵の中では値の読み書きだけをする。
///
/// 面の出す 1 か所が置く位置と範囲には、描く材料の箱の版を添える。箱は、版 V を置く直前に見せていた位置と範囲を「V より
/// 前の材料に組む位置」として版ごとに残し、描画スレッドは引き取った材料の版に組む位置を描く——材料を引き取ってから位置を
/// 読むまでに次の版が置かれても、引き取った版の位置で描く（新しい本文に古い位置・古い本文に新しい位置のコマを出さない）。
/// 指の出来事は版を添えずにその場で当てる（いちばん新しい版の材料に組む位置が動く）。
final class ScrollBox: Sendable {
  /// 描画スレッドがコマの時刻で読んだもの。
  struct Frame: Sendable {
    var position: SIMD2<Double>
    /// その位置の範囲（見せ続けている前の位置には、そのときの範囲）。
    var limits: ScrollPhysics.Limits
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
    /// 最も長い行を測り直す（この版以降の写しを描いたコマの幅で置き直す）。
    var remeasureFrom: Int?
    /// 最も長い行をまだ一度も測っていない。
    var unmeasured = true
    /// 横の範囲の基準を取り直した測定の回数。
    var baselines = 0
    /// 材料の版ごとに組む位置（版の昇順。描画スレッドがまだ引き取っていない版の分だけ）。
    var pairs: [Pair] = []
  }

  /// 版 `version` を置く直前に見せていた位置と範囲——`version` より前の材料に組む。
  private struct Pair {
    var position: SIMD2<Double>
    var limits: ScrollPhysics.Limits
    var version: Int
  }

  private let state: OSAllocatedUnfairLock<State>

  init() {
    state = OSAllocatedUnfairLock(initialState: State(physics: ScrollPhysics()))
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

  /// その場で位置を置く。`material` を添えれば、それより前の版の材料のコマは置く前の位置を描く。
  func place(_ p: SIMD2<Double>, forMaterial material: Int? = nil) {
    state.withLock { s in
      Self.pair(&s, before: material)
      s.physics.place(p)
      s.revision += 1
    }
  }

  /// 縦の位置を `dy` だけずらす（縦の並びが見えている所より上で変わった。→ `ScrollPhysics.shift`）。`material` を添えれば、
  /// それより前の版の材料のコマはずらす前の位置を描く。
  func shift(by dy: Double, forMaterial material: Int) {
    state.withLock { s in
      Self.pair(&s, before: material)
      s.physics.shift(by: dy)
      s.revision += 1
    }
  }

  func updateLimits(_ update: LimitsUpdate, forMaterial material: Int? = nil) {
    state.withLock { s in
      var limits = s.physics.limits
      update.apply(to: &limits)
      guard limits != s.physics.limits else { return }
      Self.pair(&s, before: material)
      s.physics.setLimits(limits)
      s.revision += 1
    }
  }

  /// 版 `material` を置く直前の位置と範囲を、その版より前の材料に組む位置として残す（同じ版で範囲と位置を続けて置けば、
  /// 最初に置く前のものだけ）。
  private static func pair(_ s: inout State, before material: Int?) {
    guard let material, s.pairs.last?.version != material else { return }
    s.pairs.append(
      Pair(
        position: s.physics.shown(at: CACurrentMediaTime()), limits: s.physics.limits,
        version: material))
  }

  /// 描画スレッドが版 `material` の材料を引き取った。それ以前の版に組む位置はもう要らない（後のコマはこれより新しい材料を
  /// 引き取る）。
  func taken(material: Int) {
    state.withLock { s in s.pairs.removeAll { $0.version <= material } }
  }

  /// 描画スレッドが、取引の頼んだ区間を組んだ行の x（`x`）が横に見えるところまで最小限動かす。`lineWidth` はその行の幅
  /// で、範囲を伸ばす（縮めない）。位置か範囲が変わったら true。
  func reveal(_ x: ClosedRange<Double>, lineWidth: Double) -> Bool {
    state.withLock { s in
      var limits = s.physics.limits
      if lineWidth > limits.longestLine { limits.longestLine = lineWidth }
      let widened = limits != s.physics.limits
      if widened { s.physics.setLimits(limits) }
      let area = limits.viewport.x
      var p = s.physics.shown(at: CACurrentMediaTime())
      let before = p.x
      if x.lowerBound < p.x || x.upperBound - x.lowerBound > area {
        p.x = x.lowerBound
      } else if x.upperBound > p.x + area {
        p.x = x.upperBound - area
      }
      let moved = p.x != before
      if moved { s.physics.place(p) }
      guard widened || moved else { return false }
      s.revision += 1
      return true
    }
  }

  /// 本文を丸ごと置き換えた。最も長い行を、版 `version` 以降の写しを描いたコマで測り直す（それまで横の位置は保つ）。
  func remeasure(from version: Int) {
    state.withLock { $0.remeasureFrom = version }
  }

  /// 描画スレッドが、版 `version` の写しを描いたコマで組んだ行の最も長い幅を知らせる。測り直しを待っていればその幅に
  /// 置き直し（範囲に収める）、そうでなければ伸ばすだけ。範囲が変わったら true。初めての測定と測り直しで範囲が変われば、
  /// 基準の取り直しとして数える（`baselines`）。
  func measured(longestLine width: Double, version: Int?) -> Bool {
    state.withLock { s in
      var limits = s.physics.limits
      var baseline = s.unmeasured
      s.unmeasured = false
      if let from = s.remeasureFrom, let version, version >= from {
        limits.longestLine = width
        s.remeasureFrom = nil
        baseline = true
      } else if width > limits.longestLine {
        limits.longestLine = width
      }
      guard limits != s.physics.limits else { return false }
      s.physics.setLimits(limits)
      s.revision += 1
      if baseline { s.baselines += 1 }
      return true
    }
  }

  /// 横の範囲の基準を取り直した測定（測る前から初めて測った・本文を丸ごと置き換えて測り直した）の回数。増えたコマの横の
  /// 範囲の変化は、操作によるスクロールの状態の変化ではない（つまみを出さない）。
  var baselines: Int { state.withLock { $0.baselines } }

  /// 描画スレッドがコマの時刻で読む。`material` はこのコマで描く材料の版。このコマで初めて入った出来事を引き取る。
  func frame(at t: Double, material: Int) -> Frame {
    state.withLock { s in
      s.physics.settle(at: t)
      let events = s.pendingEvents
      s.pendingEvents.removeAll(keepingCapacity: true)
      s.pairs.removeAll { $0.version <= material }
      var position = s.physics.shown(at: t)
      var limits = s.physics.limits
      if let pair = s.pairs.first {
        position = pair.position
        limits = pair.limits
      }
      return Frame(
        position: position, limits: limits, returning: s.physics.isReturning, events: events,
        gesture: s.gesture, revision: s.revision)
    }
  }

  /// 出来事を引き取らずに、今の位置を読む（撮影）。
  func peek(at t: Double) -> (position: SIMD2<Double>, limits: ScrollPhysics.Limits) {
    state.withLock { s in (s.physics.shown(at: t), s.physics.limits) }
  }

  /// まだ当てていないずらし `shift`・範囲 `update`・位置 `place` を当てたときに見せる位置と範囲（箱は書き換えない。main の
  /// 読み取り）。
  func peek(at t: Double, shift: Double, limits update: LimitsUpdate?, place: SIMD2<Double>?) -> (
    position: SIMD2<Double>, limits: ScrollPhysics.Limits
  ) {
    state.withLock { s in
      var physics = s.physics
      if shift != 0 { physics.shift(by: shift) }
      if let update {
        var limits = physics.limits
        update.apply(to: &limits)
        if limits != physics.limits { physics.setLimits(limits) }
      }
      if let place { physics.place(place) }
      return (physics.shown(at: t), physics.limits)
    }
  }

  /// 描くものが変わったかを、出来事を引き取らずに見る。
  var revision: Int { state.withLock { $0.revision } }

}
