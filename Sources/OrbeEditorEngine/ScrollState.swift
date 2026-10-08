import QuartzCore
import os
import simd

/// スクロールの状態——物理と、それを共にする面ごとの寄与。共にしていない面は面 1 つだけを持つ。
struct ScrollState: Sendable {
  var physics = ScrollPhysics()
  var revision = 0
  var gesture = 0
  var members: [Member]
  /// main か描画スレッドが位置か範囲を置き直すたびに進む（封じた刻みの値が古いかを見分ける）。
  var generation = 0
  /// 刻みごとに封じた位置（共にする面だけ。新しい順に少しだけ）。
  var seals: [Seal] = []

  /// 面 1 つの寄与。
  struct Member: Sendable {
    let id: Int
    /// この面の範囲（見えている大きさ・最も長い行・縦の端。`shared` は持たない）。
    var limits = ScrollPhysics.Limits()
    var pendingEvents: [Double] = []
    /// 最も長い行を測り直す（この版以降の写しを描いたコマの幅で置き直す）。
    var remeasureFrom: Int?
    /// 最も長い行をまだ一度も測っていない。
    var unmeasured = true
    /// 横の範囲の基準を取り直した測定の回数。
    var baselines = 0
    /// 材料の版ごとに組む位置（版の昇順。描画スレッドがまだ引き取っていない版の分だけ）。
    var pairs: [Pair] = []
    /// 面が閉じていない。
    var active = true
  }

  /// 版 `version` を置く直前に見せていた位置と範囲——`version` より前の材料に組む。
  struct Pair: Sendable {
    var position: SIMD2<Double>
    var limits: ScrollPhysics.Limits
    var version: Int
  }

  /// 予定時刻 `target` の刻みに封じた位置と、戻りの途中か。`generation` は封じたときの置き直しの回数、`revision` は
  /// 封じた位置が表す状態の版（封じた後に届いた出来事で進んだ版より古い）。
  struct Seal: Sendable {
    var target: Double
    var generation: Int
    var position: SIMD2<Double>
    var returning: Bool
    var revision: Int
  }

  /// 覚えておく封じの数。
  static let sealDepth = 4

  /// 面 `m` から見た範囲——面の範囲に、共にする面の範囲の端を添えたもの。
  func view(_ m: Int) -> ScrollPhysics.Limits {
    var limits = members[m].limits
    guard members.count > 1 else { return limits }
    for member in members where member.active {
      limits.shared = simd_max(limits.shared, member.limits.own)
    }
    return limits
  }

  /// 面の範囲が変わった。物理の範囲を、共にする面の範囲の端に合わせる（止まっていれば範囲に収める）。
  mutating func syncLimits() {
    let lead = members.firstIndex(where: \.active) ?? 0
    let limits = view(lead)
    if limits != physics.limits { physics.setLimits(limits) }
  }

  /// main か描画スレッドが位置か範囲を置き直した。
  mutating func moved() {
    revision += 1
    generation += 1
  }

  /// 面 `m` の版 `material` を置く直前の位置と範囲を、その版より前の材料に組む位置として残す（同じ版で続けて置けば、
  /// 最初に置く前のものだけ）。
  mutating func pair(_ m: Int, before material: Int, at t: Double) {
    guard members[m].pairs.last?.version != material else { return }
    members[m].pairs.append(
      Pair(position: physics.shown(at: t), limits: view(m), version: material))
  }

  /// 時刻 `t` に見せる位置と戻りの途中か、それが表す状態の版。共にする面では、その刻みに封じた値（無いか古ければ今の値を
  /// 封じる）。封じた後に出来事が届いていれば、封じた値の版は今の版より古い——その刻みを後で描く面は、描いた版が今の版に
  /// 届いていないことを知り、次の刻みで描き直す（描いたつもりで止まらない）。
  mutating func shown(at t: Double, period: Double?) -> Shown {
    let position = physics.shown(at: t)
    let returning = physics.isReturning
    guard members.count > 1, let period, period > 0 else {
      return Shown(position: position, returning: returning, revision: revision)
    }
    // 同じ刻みかは予定時刻の近さで決める（2 面は同じ画面の同じ刻みを読む）。予定時刻を刻みの長さで丸めた番号で決めると、
    // 画面の刻みの位相が格子の半ばにあるとき、続く 2 つの刻みが同じ番号になり、前の刻みの位置を次の刻みに描く。
    let same = { (seal: Seal) in abs(seal.target - t) < period / 2 }
    if let seal = seals.first(where: same), seal.generation == generation {
      return Shown(position: seal.position, returning: seal.returning, revision: seal.revision)
    }
    seals.removeAll(where: same)
    seals.insert(
      Seal(
        target: t, generation: generation, position: position, returning: returning,
        revision: revision), at: 0)
    if seals.count > Self.sealDepth { seals.removeLast() }
    return Shown(position: position, returning: returning, revision: revision)
  }

  /// 刻みに見せる位置と戻りの途中か、それが表す状態の版。
  struct Shown {
    var position: SIMD2<Double>
    var returning: Bool
    var revision: Int
  }

  /// 出す 1 か所の置くもの（面ごと）を 1 回で置く。位置か範囲が変われば、材料を書く面の版より前の材料に組む位置として前の
  /// 位置を残す。
  mutating func commit(_ entries: [(member: Int, commit: ScrollBox.Commit)]) {
    for (member, commit) in entries {
      if let from = commit.remeasure { members[member].remeasureFrom = from }
    }
    guard entries.contains(where: { changes($0.member, $0.commit) }) else { return }
    let t = CACurrentMediaTime()
    for (member, commit) in entries {
      if let material = commit.material { pair(member, before: material, at: t) }
    }
    move(entries)
  }

  /// ずらし・範囲・位置の順に当てる（範囲は止まっていれば位置を収め、置く位置はその後）。
  private mutating func move(_ entries: [(member: Int, commit: ScrollBox.Commit)]) {
    for (_, commit) in entries where commit.shift != 0 { physics.shift(by: commit.shift) }
    for (member, commit) in entries {
      guard let update = commit.limits else { continue }
      update.apply(to: &members[member].limits)
    }
    syncLimits()
    for (_, commit) in entries {
      if let p = commit.position { physics.place(p) }
    }
    moved()
  }

  /// `commit` が面 `m` のずらし・範囲・位置を変えるか。
  private func changes(_ m: Int, _ commit: ScrollBox.Commit) -> Bool {
    guard commit.shift == 0, commit.position == nil else { return true }
    guard let update = commit.limits else { return false }
    var limits = members[m].limits
    update.apply(to: &limits)
    return limits != members[m].limits
  }
}

/// スクロールの状態の入れ物（共にする面の箱が同じものを指す）。
final class ScrollCore: Sendable {
  let state: OSAllocatedUnfairLock<ScrollState>

  init(surface: Int) {
    state = OSAllocatedUnfairLock(
      initialState: ScrollState(members: [ScrollState.Member(id: surface)]))
  }

  /// 2 つの状態を 1 つにする——物理は `lead` のものを引き継ぎ、面の寄与は両方を持つ。
  init(joining lead: ScrollState, _ other: ScrollState) {
    var joined = lead
    joined.members = lead.members + other.members
    joined.revision = max(lead.revision, other.revision) + 1
    joined.seals = []
    joined.syncLimits()
    state = OSAllocatedUnfairLock(initialState: joined)
  }
}
