import AppKit
import OrbeEditorCore
import QuartzCore
import simd

/// 出す前の状態——面の main 側に積んだ、まだ箱へ書いていない変化。main の読み取り（写し・位置・見えている範囲）はこれを
/// 当てた値を読み、描画スレッドは出した状態（箱）だけを読む。
struct Pending {
  /// 材料の欄の書き込み（積んだ順）。
  var writes: [@Sendable (inout FrameMaterial) -> Void] = []
  /// 積んだ写しのうち最新。
  var content: SurfaceContent?
  /// 行の数の上限と見えている大きさ。
  var limits: LimitsUpdate?
  /// 置く位置（取引が置いた位置と見せ方の位置）。
  var position: SIMD2<Double>?
  /// 縦の位置のずらし（縦の並びが見えている所より上で変わった。範囲と位置より先に当てる）。
  var shift: Double = 0
  /// 最も長い行をこの版以降の写しで測り直す。
  var remeasure: Int?
  /// 縦の並びが変わり、見えている先頭の文書の行を保つずらしを決めた（スクロールを共にする面は、先に結んだ面のずらしだけを
  /// 当てる）。
  var anchored = false

  var isEmpty: Bool {
    writes.isEmpty && limits == nil && position == nil && remeasure == nil && shift == 0
  }
}

/// 取引が置く範囲の値（描画スレッドが組んだ行で伸ばす最も長い行の幅は含まない）。
struct LimitsUpdate: Equatable, Sendable {
  /// 縦のスクロールの端（→ `ScrollPhysics.Limits.lastTop`）。
  var lastTop: Double
  var lineHeight: Double
  var viewport: SIMD2<Double>
  var cell: Double

  func apply(to limits: inout ScrollPhysics.Limits) {
    limits.lastTop = lastTop
    limits.lineHeight = lineHeight
    limits.viewport = viewport
    limits.cell = cell
  }
}

/// 出す 1 か所と、出すきっかけ。面が描画スレッドへ出す道はここだけで、きっかけは 2 つ——面自身の入力（キー・マウス・
/// スクロール・IME の呼び出し・俯瞰のドラッグ）の処理の一番外側の終わりと、main の runloop の 1 周の終わり（Orbe から
/// 始まる呼び出しの並び）。面自身の入力への Orbe の反応は処理の中に同期に入るので、処理の終わりには全部が出す前の状態に
/// 揃っている。同じまとまりで起きたことは、どの呼び手から来ても同じコマに出る。
extension MetalTextSurface {
  /// 面自身の入力の一番外側。処理の終わりで出す（入れ子は外側が 1 回だけ出す）。
  func inputScope(_ body: () -> Void) {
    inputDepth += 1
    body()
    inputDepth -= 1
    if inputDepth == 0 { flush() }
  }

  /// 面自身の入力を 1 つの取引で行い、処理の終わりで出す。
  func input(keystroke: Double? = nil, _ body: () -> Void) {
    inputScope { transact(keystroke: keystroke, body) }
  }

  /// 出す前の状態を、入力の処理の終わりか、runloop の 1 周の終わりに出す。
  func flushLater() {
    guard inputDepth == 0 else { return }
    FlushScheduler.shared.schedule(self)
  }

  /// 出す。手順の順番は約束——① 版 N（今の材料の版 + 1）を先に決め、② 版 N を添えてずらし・範囲・位置をスクロールの箱へ置き
  /// （箱は置く前の位置を N より前の材料に組んで残す）、③ 材料の箱へ 1 回書き（版 N になる）、④ 描画スレッドを 1 回起こす。
  /// 描画スレッドは引き取った材料の版に組む位置を描くので、位置を先・材料を後の順でなければ「新しい位置に古い本文」の
  /// コマが出る。出す前の状態が空なら何もしない。
  ///
  /// スクロールを共にする面は一緒に出す——②を両面ぶん 1 つの鍵の中で置き（両面の版に組む位置を同時に残す）、並びが変わった
  /// 面のずらしは先に結んだ面のものだけを当て、両面の見えている範囲を知らせ直す。
  func flush() {
    let group = scrollGroup
    for surface in group { FlushScheduler.shared.cancel(surface) }
    guard group.contains(where: { !$0.pending.isEmpty }) else { return }
    let outs = group.map { surface in
      let out = surface.pending
      surface.pending = Pending()
      return out
    }
    let anchor = outs.firstIndex(where: \.anchored)
    let revisions = zip(group, outs).map { surface, out in
      out.isEmpty ? nil : surface.material.revision + 1
    }
    ScrollBox.commit(
      outs.indices.map { index in
        let out = outs[index]
        return (
          group[index].scroll,
          ScrollBox.Commit(
            material: revisions[index], remeasure: out.remeasure,
            shift: group.count == 1 || index == anchor ? out.shift : 0, limits: out.limits,
            position: out.position)
        )
      })
    for (surface, (out, revision)) in zip(group, zip(outs, revisions)) {
      guard let revision else { continue }
      let written = surface.material.update { material in
        for write in out.writes { write(&material) }
      }
      precondition(written == revision, "描く材料の箱を書くのは main の出す 1 か所だけ")
    }
    wake()
    guard group.count > 1 else { return }
    for surface in group { surface.refreshViewport() }
  }

  /// 一緒に出す面——自分と、スクロールを共にする相手（先に結んだ面が先）。
  var scrollGroup: [MetalTextSurface] {
    guard let partner else { return [self] }
    return leadsScroll ? [self, partner] : [partner, self]
  }

  /// main から見た今の位置と範囲——まだ出していないずらし・範囲・位置（取引の中で置いた位置を含む）を当てた値。
  func scrollState(at t: Double = CACurrentMediaTime()) -> (
    position: SIMD2<Double>, limits: ScrollPhysics.Limits
  ) {
    scroll.peek(
      at: t, shift: pending.shift, limits: pending.limits,
      place: transaction?.scrollTo ?? pending.position)
  }
}

/// main の runloop の 1 周の終わり（待ちに入る前と、runloop を抜けるとき。共通のモード——既定・イベントの追跡・
/// モーダルのパネル）に、出す前の状態を持つ面を出す。Core Animation の暗黙の確定と同じ見張り方で、出来事や main の
/// 仕事が途切れず「待ちに入る前」が来ない間も、runloop を抜けるたびに出す。
@MainActor
final class FlushScheduler {
  static let shared = FlushScheduler()

  private final class Entry {
    weak var surface: MetalTextSurface?
    init(_ surface: MetalTextSurface) { self.surface = surface }
  }

  private var waiting: [Int: Entry] = [:]
  private var observer: CFRunLoopObserver?

  func schedule(_ surface: MetalTextSurface) {
    guard waiting[surface.id] == nil else { return }
    waiting[surface.id] = Entry(surface)
    installIfNeeded()
  }

  func cancel(_ surface: MetalTextSurface) {
    waiting[surface.id] = nil
  }

  private func installIfNeeded() {
    guard observer == nil else { return }
    // 同じ見張りの中で最後に走る（AppKit の配置・表示の見張りが面へ置いた変化も同じ周で出す）。
    let observer = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true,
      CFIndex.max
    ) { _, _ in
      MainActor.assumeIsolated { FlushScheduler.shared.flushAll() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  private func flushAll() {
    guard !waiting.isEmpty else { return }
    let entries = waiting.values
    waiting.removeAll()
    for entry in entries { entry.surface?.flush() }
  }
}
