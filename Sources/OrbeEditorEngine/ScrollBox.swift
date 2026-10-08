import AppKit
import os
import simd

/// スクロールの状態の箱（面 1 つの口）。main が出来事を書き、描画スレッドがコマの時刻で位置を読む。鍵の中では値の読み書き
/// だけをする。
///
/// 面の出す 1 か所が置く位置と範囲には、描く材料の箱の版を添える。箱は、版 V を置く直前に見せていた位置と範囲を「V より
/// 前の材料に組む位置」として版ごとに残し、描画スレッドは引き取った材料の版に組む位置を描く——材料を引き取ってから位置を
/// 読むまでに次の版が置かれても、引き取った版の位置で描く（新しい本文に古い位置・古い本文に新しい位置のコマを出さない）。
/// 指の出来事は版を添えずにその場で当てる（いちばん新しい版の材料に組む位置が動く）。
///
/// スクロールを共にする面（→ `share`）は、物理（位置・端の戻り・軸の判定）を 1 つの状態として共有し、範囲は面ごとの寄与の
/// 大きい方になる。面ごとに残すのは、範囲の寄与（見えている大きさ・最も長い行・縦の端）・材料の版に組む位置・出来事の
/// 引き取り・最も長い行の測り直し。結んだ面は、刻みごとの位置を刻みの予定時刻を鍵に最初に読んだ面が封じ、同じ刻みの
/// もう一方の面は同じ位置を描く——封じた後に届いた出来事は次の刻みに出る（後で描く面は、描いた位置の版が今の版に届いて
/// いないことを知り、次の刻みで描き直す）。main か描画スレッドが位置か範囲を置き直せば、封じた値は古くなる（次に読んだ
/// 面が封じ直す）。
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

  /// 出す 1 か所が 1 回で置くもの（→ `commit`）。
  struct Commit {
    /// この出し方で書く材料の版（材料を書かないなら nil）。位置か範囲が変われば、この版より前の材料に組む位置として前の
    /// 位置を残す。
    var material: Int?
    var remeasure: Int?
    var shift: Double = 0
    var limits: LimitsUpdate?
    var position: SIMD2<Double>?
  }

  private let link: OSAllocatedUnfairLock<Link>

  /// 共有の状態と、その中の自分の番号。
  private struct Link: Sendable {
    var core: ScrollCore
    var member: Int
  }

  /// `surface` は面の通し番号（共にする相手を起こすのに使う）。
  init(surface: Int = 0) {
    link = OSAllocatedUnfairLock(initialState: Link(core: ScrollCore(surface: surface), member: 0))
  }

  private func with<T: Sendable>(_ body: @Sendable (inout ScrollState, Int) -> T) -> T {
    let link = link.withLock { $0 }
    return link.core.state.withLock { body(&$0, link.member) }
  }

  // MARK: - 共にする

  /// `other` とスクロールの状態を共にする。物理はこの箱のものを引き継ぎ、範囲の寄与と材料の版に組む位置は面ごとに残す。
  /// 閉じた面の寄与は持ち越さない（閉じた相手と共にしていた面も結び直せる）。
  func share(with other: ScrollBox) {
    let mine = link.withLock { $0 }
    let theirs = other.link.withLock { $0 }
    let core = ScrollCore(
      joining: mine.core.state.withLock { $0 }, theirs.core.state.withLock { $0 })
    link.withLock { $0 = Link(core: core, member: 0) }
    other.link.withLock { $0 = Link(core: core, member: 1) }
  }

  /// 面が閉じた。範囲の寄与を外し（残った面の位置は残った範囲に収める）、共にする相手を起こさなくする。
  func leave() {
    with { s, m in
      s.members[m].active = false
      s.syncLimits()
      s.moved()
    }
  }

  /// 共にしている相手の面の通し番号。
  var partners: [Int] {
    with { s, m in
      s.members.indices.filter { $0 != m && s.members[$0].active }.map { s.members[$0].id }
    }
  }

  /// 共にする相手と同じ鍵の中で、出す 1 か所の置くものを 1 回で置く（→ `commit`）。どの箱も同じ状態を共にしていること。
  static func commit(_ items: [(box: ScrollBox, commit: Commit)]) {
    guard let first = items.first else { return }
    let core = first.box.link.withLock { $0.core }
    let members = items.map { item in
      let link = item.box.link.withLock { $0 }
      precondition(link.core === core, "一緒に出す箱は、同じスクロールの状態を共にしている")
      return link.member
    }
    let entries = Array(zip(members, items.map(\.commit)))
    core.state.withLock { $0.commit(entries) }
  }

  /// 出す 1 か所の置くものを置く（共にする相手と一緒に出すなら `ScrollBox.commit(_:)`）。
  func commit(_ commit: Commit) {
    Self.commit([(self, commit)])
  }

  // MARK: - main

  /// 出来事を当てる。見えている位置が変わりうるなら true。
  func apply(_ input: ScrollInput) -> Bool {
    with { s, m in
      if input.phase == .began { s.gesture += 1 }
      guard s.physics.apply(input) else { return false }
      s.revision += 1
      if input.precise, input.phase != .mayBegin {
        s.members[m].pendingEvents.append(input.timestamp)
      }
      return true
    }
  }

  /// 本文を丸ごと置き換えた。最も長い行を、版 `version` 以降の写しを描いたコマで測り直す（それまで横の位置は保つ）。
  func remeasure(from version: Int) {
    with { s, m in s.members[m].remeasureFrom = version }
  }

  /// まだ当てていないずらし `shift`・範囲 `update`・位置 `place` を当てたときに見せる位置と範囲（箱は書き換えない。main の
  /// 読み取り）。
  func peek(at t: Double, shift: Double, limits update: LimitsUpdate?, place: SIMD2<Double>?) -> (
    position: SIMD2<Double>, limits: ScrollPhysics.Limits
  ) {
    with { s, m in
      var copy = s
      if shift != 0 { copy.physics.shift(by: shift) }
      if let update {
        var limits = copy.members[m].limits
        update.apply(to: &limits)
        if limits != copy.members[m].limits {
          copy.members[m].limits = limits
          copy.syncLimits()
        }
      }
      if let place { copy.physics.place(place) }
      return (copy.physics.shown(at: t), copy.view(m))
    }
  }

  // MARK: - 描画スレッド

  /// 描画スレッドが版 `material` の材料を引き取った。それ以前の版に組む位置はもう要らない（後のコマはこれより新しい材料を
  /// 引き取る）。
  func taken(material: Int) {
    with { s, m in s.members[m].pairs.removeAll { $0.version <= material } }
  }

  /// 描画スレッドが、取引の頼んだ区間を組んだ行の x（`x`）が横に見えるところまで最小限動かす。`lineWidth` はその行の幅
  /// で、範囲を伸ばす（縮めない）。位置か範囲が変わったら true。
  func reveal(_ x: ClosedRange<Double>, lineWidth: Double) -> Bool {
    with { s, m in
      var limits = s.members[m].limits
      if lineWidth > limits.longestLine { limits.longestLine = lineWidth }
      let widened = limits != s.members[m].limits
      if widened {
        s.members[m].limits = limits
        s.syncLimits()
      }
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
      s.moved()
      return true
    }
  }

  /// 描画スレッドが、版 `version` の写しを描いたコマで組んだ行の最も長い幅を知らせる。測り直しを待っていればその幅に
  /// 置き直し（範囲に収める）、そうでなければ伸ばすだけ。範囲が変わったら true。初めての測定と測り直しで範囲が変われば、
  /// 基準の取り直しとして数える（`baselines`）。
  func measured(longestLine width: Double, version: Int?) -> Bool {
    with { s, m in
      var member = s.members[m]
      var limits = member.limits
      var baseline = member.unmeasured
      member.unmeasured = false
      if let from = member.remeasureFrom, let version, version >= from {
        limits.longestLine = width
        member.remeasureFrom = nil
        baseline = true
      } else if width > limits.longestLine {
        limits.longestLine = width
      }
      let changed = limits != member.limits
      member.limits = limits
      if changed, baseline { member.baselines += 1 }
      s.members[m] = member
      guard changed else { return false }
      s.syncLimits()
      s.moved()
      return true
    }
  }

  /// 横の範囲の基準を取り直した測定（測る前から初めて測った・本文を丸ごと置き換えて測り直した）の回数。増えたコマの横の
  /// 範囲の変化は、操作によるスクロールの状態の変化ではない（つまみを出さない）。
  var baselines: Int { with { s, m in s.members[m].baselines } }

  /// 描画スレッドがコマの時刻で読む。`material` はこのコマで描く材料の版、`period` は表示の刻みの長さ（刻みの位置を封じる）。
  /// このコマで初めて入った出来事を引き取る。
  func frame(at t: Double, period: Double? = nil, material: Int) -> Frame {
    with { s, m in
      s.physics.settle(at: t)
      let events = s.members[m].pendingEvents
      s.members[m].pendingEvents.removeAll(keepingCapacity: true)
      s.members[m].pairs.removeAll { $0.version <= material }
      var position: SIMD2<Double>
      var limits: ScrollPhysics.Limits
      var returning = s.physics.isReturning
      var revision = s.revision
      if let pair = s.members[m].pairs.first {
        position = pair.position
        limits = pair.limits
      } else {
        let shown = s.shown(at: t, period: period)
        (position, returning, revision) = (shown.position, shown.returning, shown.revision)
        limits = s.view(m)
      }
      return Frame(
        position: position, limits: limits, returning: returning, events: events,
        gesture: s.gesture, revision: revision)
    }
  }

  /// 出来事を引き取らずに、今の位置を読む（撮影）。
  func peek(at t: Double) -> (position: SIMD2<Double>, limits: ScrollPhysics.Limits) {
    with { s, m in (s.physics.shown(at: t), s.view(m)) }
  }

  /// 描くものが変わったかを、出来事を引き取らずに見る。
  var revision: Int { with { s, _ in s.revision } }
}
