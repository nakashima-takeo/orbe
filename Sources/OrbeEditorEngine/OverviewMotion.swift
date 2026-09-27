import CoreGraphics
import Foundation

/// 俯瞰の操作の状態（main → 描画スレッド）。main が出来事から書き、描画スレッドがそのコマの配置で「帯・つまみの上か」を
/// 決め、時刻から帯とつまみの濃さを出す。
struct OverviewInput: Equatable, Sendable {
  /// 何をドラッグ中か。
  enum Drag: Equatable, Sendable {
    case minimap, vertical, horizontal
  }

  /// ポインタが面（本体）の上にある。
  var hovering = false
  /// 俯瞰（ミニマップ・縦横のスクロールバー）の上にあるポインタの位置（面の view の座標、pt）。
  var pointer: CGPoint?
  var drag: Drag?
  /// 動きを減らす設定（帯とつまみが時間を掛けずに現れ・消える）。
  var reduceMotion = false
}

/// 現れる・消えるの 1 つ——見える向きと、その向きに変わった時刻と、そのときの濃さ。濃さは時刻から直線で出す。
struct Fade: Equatable {
  private(set) var shown = false
  private var from = 0.0
  private var start = -Double.infinity

  /// 時刻 `t` の濃さ（0…1）。
  func value(at t: Double, fadeIn: Double, fadeOut: Double) -> Double {
    let target = shown ? 1.0 : 0.0
    let duration = shown ? fadeIn : fadeOut
    guard duration > 0, t < start + duration else { return target }
    let progress = max(0, (t - start) / duration)
    return from + (target - from) * progress
  }

  /// 時刻 `t` まで動いているか（濃さがまだ行き着いていない）。
  func moving(at t: Double, fadeIn: Double, fadeOut: Double) -> Bool {
    value(at: t, fadeIn: fadeIn, fadeOut: fadeOut) != (shown ? 1 : 0)
  }

  mutating func set(_ shown: Bool, at t: Double, fadeIn: Double, fadeOut: Double) {
    guard shown != self.shown else { return }
    from = value(at: t, fadeIn: fadeIn, fadeOut: fadeOut)
    self.shown = shown
    start = t
  }
}

/// 帯とつまみの濃さの時間の動き（描画スレッドだけ。面ごと）。点滅と同じ扱いで、フェードの間だけ刻みを回し、終われば止める。
/// 「スクロールが止まってから消え始める」は、その時刻に起きて刻みを回す（→ `wakeAt`）。つまみは本体の上にポインタがある
/// 間とドラッグ中は見え、スクロールの状態（縦横の位置・見えている大きさ・行数・横の範囲）が変わると現れ、変わらなくなって
/// から `hideDelay` 後に消え始める（ポインタが本体から出た・ドラッグを離したときは、すぐ消え始める）。面を結んだ最初の
/// コマの状態は変化に数えない。帯はミニマップの上にポインタがある間とドラッグ中に見える。
final class OverviewMotion {
  /// スクロールの状態（変化でつまみを見せる）。
  struct ScrollState: Equatable {
    var first: CGFloat
    var visible: CGFloat
    var lineCount: Int
    var x: Double
    var width: Double
    var range: Double
  }

  private var lastState: ScrollState?
  private var lastChange = -Double.infinity
  /// ポインタが本体から出た・ドラッグを離した時刻（それより前のスクロールでは、つまみを見せ続けない）。
  private var lastRelease = -Double.infinity
  private var lastInput = OverviewInput()
  private(set) var thumb = Fade()
  private(set) var slider = Fade()
  /// このコマの後もフェードが続く。
  private(set) var animating = false
  /// 止まった後に起きる時刻（つまみが消え始める時刻）。
  private(set) var wakeAt: Double?

  /// 時刻 `t` のコマを描く要がある（フェードの途中か、つまみが消え始める時刻を過ぎた）。
  func due(at t: Double) -> Bool {
    animating || wakeAt.map { t >= $0 } == true
  }

  /// このコマの時刻 `t`・スクロールの状態・操作の状態から、つまみの濃さを出す。
  func thumbOpacity(
    at t: Double, state: ScrollState, input: OverviewInput, motion: SurfaceConfig.Overview
  ) -> Double {
    if let lastState, lastState != state { lastChange = t }
    lastState = state
    let over = input.hovering
    let dragging = input.drag == .vertical || input.drag == .horizontal
    if (lastInput.hovering && !over) || (lastInput.drag != nil && input.drag == nil) {
      lastRelease = t
    }
    lastInput = input
    let delay = motion.hideDelay
    let recent = lastChange > lastRelease && t < lastChange + delay
    let shown = over || dragging || recent
    let (fadeIn, fadeOut) = durations(input, motion, fadeOut: motion.fadeOut)
    thumb.set(shown, at: t, fadeIn: fadeIn, fadeOut: fadeOut)
    wakeAt = recent && !over && !dragging ? lastChange + delay : nil
    animating = thumb.moving(at: t, fadeIn: fadeIn, fadeOut: fadeOut)
    return thumb.value(at: t, fadeIn: fadeIn, fadeOut: fadeOut)
  }

  /// 帯の濃さ（`shown` はミニマップの上にポインタがあるかドラッグ中で、帯が要る）。
  func sliderOpacity(
    at t: Double, shown: Bool, input: OverviewInput, motion: SurfaceConfig.Overview
  ) -> Double {
    let (fadeIn, fadeOut) = durations(input, motion, fadeOut: motion.fadeIn)
    slider.set(shown, at: t, fadeIn: fadeIn, fadeOut: fadeOut)
    if slider.moving(at: t, fadeIn: fadeIn, fadeOut: fadeOut) { animating = true }
    return slider.value(at: t, fadeIn: fadeIn, fadeOut: fadeOut)
  }

  private func durations(
    _ input: OverviewInput, _ motion: SurfaceConfig.Overview, fadeOut: Double
  ) -> (Double, Double) {
    input.reduceMotion ? (0, 0) : (motion.fadeIn, fadeOut)
  }
}
