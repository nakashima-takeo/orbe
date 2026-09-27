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
  /// 最も長い行をこの版以降の写しで測り直す。
  var remeasure: Int?
  /// 指の出来事で箱の位置が動いた（描画スレッドを起こすだけ）。
  var wakes = false

  var isEmpty: Bool {
    writes.isEmpty && limits == nil && position == nil && remeasure == nil && !wakes
  }

  /// 箱の版を進めずに起こすだけで足りる。
  var wakesOnly: Bool { writes.isEmpty && limits == nil && position == nil && remeasure == nil }
}

/// 取引が置く範囲の値（描画スレッドが組んだ行で伸ばす最も長い行の幅は含まない）。
struct LimitsUpdate: Equatable, Sendable {
  var lineCount: Int
  var lineHeight: Double
  var viewport: SIMD2<Double>
  var cell: Double

  func apply(to limits: inout ScrollPhysics.Limits) {
    limits.lineCount = lineCount
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

  /// 出す。手順の順番は約束——① 版 N（今の材料の版 + 1）を先に決め、② 版 N を添えて位置と範囲をスクロールの箱へ置き、
  /// ③ 材料の箱へ 1 回書き（版 N になる）、④ 描画スレッドを 1 回起こす。描画スレッドは材料の版が N に追いつくまで前の位置を
  /// 描くので、位置を先・材料を後の順でなければ「新しい位置に古い本文」のコマが出る。出す前の状態が空なら何もしない。
  func flush() {
    FlushScheduler.shared.cancel(self)
    guard !pending.isEmpty else { return }
    let out = pending
    pending = Pending()
    guard !out.wakesOnly else {
      wake()
      return
    }
    let revision = material.revision + 1
    if let from = out.remeasure { scroll.remeasure(from: from) }
    if let limits = out.limits { scroll.updateLimits(limits, heldUntil: revision) }
    if let p = out.position { scroll.place(p, heldUntil: revision) }
    let written = material.update { material in
      for write in out.writes { write(&material) }
    }
    precondition(written == revision, "描く材料の箱を書くのは main の出す 1 か所だけ")
    wake()
  }

  /// main から見た今の位置と範囲——まだ出していない範囲と位置（取引の中で置いた位置を含む）を当てた値。
  func scrollState(at t: Double = CACurrentMediaTime()) -> (
    position: SIMD2<Double>, limits: ScrollPhysics.Limits
  ) {
    scroll.peek(at: t, limits: pending.limits, place: transaction?.scrollTo ?? pending.position)
  }
}

/// main の runloop の 1 周の終わり（待ちに入る前と、runloop を抜けるとき。全部のモード）に、出す前の状態を持つ面を出す。
/// Core Animation の暗黙の確定と同じ見張り方で、出来事や main の仕事が途切れず「待ちに入る前」が来ない間も、runloop を
/// 抜けるたびに出す。
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
