import AppKit
import os
import simd

/// スクロールの状態の箱。main が出来事を書き、描画スレッドがコマの時刻で位置を読む。鍵の中では値の読み書きだけをする。
///
/// 面の出す 1 か所が置く位置と範囲には、描く材料の箱の版を添える。描画スレッドは、読んだ材料の版がそれに追いつくまで前の
/// 位置を描く——スクロールだけが先に動いたコマ（新しい位置に古い本文）を出さない。指の出来事は版を添えずにその場で当てる。
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
    /// 最も長い行を測り直す（この版以降の写しを描いたコマの幅で置き直す）。
    var remeasureFrom: Int?
    /// 取引が置く前に見せていた位置と、それを見せ続ける材料の版の上限。
    var held: Held?
  }

  private struct Held {
    var position: SIMD2<Double>
    var until: Int
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

  /// その場で位置を置く。`material` を添えれば、描画スレッドはその版の材料を読むまで前の位置を描く。
  func place(_ p: SIMD2<Double>, heldUntil material: Int? = nil) {
    state.withLock { s in
      Self.hold(&s, until: material)
      s.physics.place(p)
      s.revision += 1
    }
  }

  func updateLimits(_ update: LimitsUpdate, heldUntil material: Int? = nil) {
    state.withLock { s in
      var limits = s.physics.limits
      update.apply(to: &limits)
      guard limits != s.physics.limits else { return }
      Self.hold(&s, until: material)
      s.physics.setLimits(limits)
      s.revision += 1
    }
  }

  private static func hold(_ s: inout State, until material: Int?) {
    guard let material else { return }
    let position = s.held?.position ?? s.physics.shown(at: CACurrentMediaTime())
    s.held = Held(position: position, until: max(s.held?.until ?? material, material))
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
  /// 置き直し（範囲に収める）、そうでなければ伸ばすだけ。範囲が変わったら true。
  func measured(longestLine width: Double, version: Int?) -> Bool {
    state.withLock { s in
      var limits = s.physics.limits
      if let from = s.remeasureFrom, let version, version >= from {
        limits.longestLine = width
        s.remeasureFrom = nil
      } else if width > limits.longestLine {
        limits.longestLine = width
      }
      guard limits != s.physics.limits else { return false }
      s.physics.setLimits(limits)
      s.revision += 1
      return true
    }
  }

  /// 描画スレッドがコマの時刻で読む。`material` はこのコマで描く材料の版。このコマで初めて入った出来事を引き取る。
  func frame(at t: Double, material: Int) -> Frame {
    state.withLock { s in
      s.physics.settle(at: t)
      let events = s.pendingEvents
      s.pendingEvents.removeAll(keepingCapacity: true)
      var position = s.physics.shown(at: t)
      if let held = s.held {
        if material >= held.until { s.held = nil } else { position = held.position }
      }
      return Frame(
        position: position, returning: s.physics.isReturning, events: events,
        gesture: s.gesture, revision: s.revision)
    }
  }

  /// 出来事を引き取らずに、今の位置を読む（撮影）。
  func peek(at t: Double) -> (position: SIMD2<Double>, limits: ScrollPhysics.Limits) {
    state.withLock { s in (s.physics.shown(at: t), s.physics.limits) }
  }

  /// まだ置いていない範囲 `update` と位置 `place` を当てたときに見せる位置と範囲（箱は書き換えない。main の読み取り）。
  func peek(at t: Double, limits update: LimitsUpdate?, place: SIMD2<Double>?) -> (
    position: SIMD2<Double>, limits: ScrollPhysics.Limits
  ) {
    state.withLock { s in
      var physics = s.physics
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
