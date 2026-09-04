import Foundation
import SwiftUI

/// メニューバー②（到来ピル）の尺と easing。design 原典（Menubar_Notification_Animation）の
/// タイムライン表を尺の原典、keyframe を順序と easing の原典として移植する。
/// 持つのは展開・艶・収縮まで——両者に挟まれる滞留は設定 `menubar-notification-duration`（発信元
/// workspace の実効値）から到来時に決まり、`AttentionStore.Transient.expiresAt` が担う。
enum MenuBarArrival {
  /// 展開（地・件数・文言・◐ を束ねる単一の窓）。
  static let expand: TimeInterval = 0.84
  /// 到来から艶が走り出すまで。
  static let glossDelay: TimeInterval = 1.2
  /// 艶が左端の外から右端の外へ通り抜ける尺。
  static let glossDuration: TimeInterval = 1.1
  /// 収縮（文言を畳み、件数を出し、地を③へ戻す）。滞留を満了したときの尺。
  static let collapse: TimeInterval = 0.6
  /// 同じ収縮の速い尺。取り下げ・②中のクリックはこちらで閉じる——閉じ方は 1 つ（同じ動きの
  /// 尺違い）で、②が消える見え方が経路によって変わらない。
  static let collapseQuick: TimeInterval = 0.18

  /// 要素ごとの easing（原典 keyframe から逐語）。位相は線形なので曲線はここだけが持つ。
  enum Curve {
    /// 文言の幅・opacity（`mbText`）。
    static let text = UnitCurve.bezier(
      startControlPoint: UnitPoint(x: 0.2, y: 0.8), endControlPoint: UnitPoint(x: 0.3, y: 1))
    /// 地のクロスフェード（`mbBg`）。
    static let background = UnitCurve.easeInOut
    /// 件数の畳み込み・出現（`mbCountSwap` / `mbCountIn`）。CSS の `ease`。
    static let count = UnitCurve.bezier(
      startControlPoint: UnitPoint(x: 0.25, y: 0.1), endControlPoint: UnitPoint(x: 0.25, y: 1))
    /// ◐ の減光解除（`mbGlyph`）。
    static let glyph = UnitCurve.easeInOut
    /// 艶の走査（`mbGloss`）。
    static let gloss = UnitCurve.bezier(
      startControlPoint: UnitPoint(x: 0.35, y: 0.1), endControlPoint: UnitPoint(x: 0.25, y: 1))
  }

  /// ビューへ注入する位相。ビューはこれだけで見た目が決まる（内部に時間を持たない）。
  struct Phase: Equatable {
    /// 開き具合の**線形**進捗。0＝閉じ切り、1＝開き切り。easing はビューが当てる。
    var openness: Double
    /// 艶の走査進捗（nil＝走っていない）。0＝左端の外、1＝右端の外。
    var gloss: Double?
    /// 収縮の途中か。原典の easing は開く動きも閉じる動きも**その動きの進捗**に対して前のめり
    /// なので、同じ `openness` でも向きで見た目が違う（向きを落とすと、閉じ始めの 300ms が
    /// 動かず後半で一気に畳まれる）。両端では両向きの見た目が一致するので false に均す。
    var closing: Bool = false

    static let closed = Phase(openness: 0, gloss: nil)
    static let open = Phase(openness: 1, gloss: nil)
  }
}

/// ②の位相を時刻から決める状態機械。タイマーは持たず（`MenuBarController` が持つ）、
/// 時刻は必ず注入する——テストとフィルムストリップが同じ経路で任意のフレームを再現できる。
/// main スレッド規律（AppKit・`AttentionStore` と同じ）。
///
/// Reduce Motion は「展開と収縮の尺が 0・艶は立てない」の一言で表す。位相は 0 と 1 しか取らず、
/// ビューは Reduce Motion を知らないままでよい。
final class MenuBarArrivalDriver {
  var reduceMotion = false

  private(set) var phase = MenuBarArrival.Phase.closed

  /// 展開・収縮・艶の基点。位相はこの 3 つと注入時刻だけから決まる。
  private var openingSince: Date?
  private var closingSince: Date?
  private var glossSince: Date?
  /// 収縮を撃ち終えた。`tick` が 1 度だけ true として返す（controller が②を落とす合図）。
  private var collapseCompleted = false

  /// tween が進行中か。controller はこれが true の間だけ tick を回す（滞留中は止める）。
  var isAnimating: Bool { openingSince != nil || closingSince != nil || glossSince != nil }

  /// 収縮の最中か。controller はこの間だけ期限タイマーを張らない（一度閉じ始めたら閉じ切る）。
  var isCollapsing: Bool { closingSince != nil }

  private var expandDuration: TimeInterval { reduceMotion ? 0 : MenuBarArrival.expand }
  /// 進行中の収縮の尺（`expired` は通常・`dismissed` は速い尺で立てる）。Reduce Motion は 0。
  private var collapseDuration: TimeInterval = MenuBarArrival.collapse

  /// 到来（初回・積み替えの両方）。開き切っていれば開き直さず、艶だけを立て直す。
  /// 開きかけ／閉じかけからの到来は現在の開き具合から続けて開く（位相は飛ばない）。
  func arrived(at now: Date) {
    closingSince = nil
    collapseCompleted = false
    phase.closing = false
    glossSince = reduceMotion ? nil : now
    if phase.openness < 1 {
      openingSince = now.addingTimeInterval(-phase.openness * expandDuration)
    }
    advance(to: now)
  }

  /// 滞留満了。ここから 600ms かけて閉じる（Reduce Motion では尺 0 ＝その場で閉じ切る）。
  func expired(at now: Date) {
    beginCollapse(at: now, over: MenuBarArrival.collapse)
  }

  /// 途中終了（取り下げ・②中のクリック）。**同じ収縮を速い尺で**撃つ——閉じ方を 1 つに保ち、
  /// 幅が 1 フレームで飛ばない（飛ばすと content と `statusItem.length` の反映がずれ、
  /// 広いままのアイテムの中で content が中央寄せに描かれて「中央へ萎む」ように見える）。
  func dismissed(at now: Date) {
    beginCollapse(at: now, over: MenuBarArrival.collapseQuick)
  }

  /// もう描く材料が無い（②の行そのものが外から消えた）。tween を捨ててその場で閉じ切る。
  func closedOut() {
    openingSince = nil
    closingSince = nil
    glossSince = nil
    collapseCompleted = false
    phase = .closed
  }

  /// 現在の開き具合から、指定の尺で閉じ始める（既に閉じかけなら尺だけ差し替えて続きから閉じる）。
  /// 閉じ始めたら艶は止める——祝いは開いている間のもので、速い収縮（180ms）は艶（到来 1.2s 後
  /// から 1.1s）の最中に撃たれうる。残すと閉じ切った後も基点が生きて ticker が回り続ける。
  private func beginCollapse(at now: Date, over duration: TimeInterval) {
    openingSince = nil
    glossSince = nil
    collapseDuration = reduceMotion ? 0 : duration
    closingSince = now.addingTimeInterval(-(1 - phase.openness) * collapseDuration)
    advance(to: now)
  }

  /// 位相を now まで進める。収縮を撃ち終えたときだけ true を返す。
  @discardableResult func tick(now: Date) -> Bool {
    advance(to: now)
    guard collapseCompleted else { return false }
    collapseCompleted = false
    return true
  }

  private func advance(to now: Date) {
    if let since = closingSince {
      let p = progress(since: since, now: now, over: collapseDuration)
      phase.openness = 1 - p
      phase.closing = p > 0 && p < 1
      if p >= 1 {
        closingSince = nil
        collapseCompleted = true
      }
    } else if let since = openingSince {
      let p = progress(since: since, now: now, over: expandDuration)
      phase.openness = p
      phase.closing = false
      if p >= 1 { openingSince = nil }
    }
    guard let since = glossSince else {
      phase.gloss = nil  // 基点が無い＝走っていない。Reduce Motion 下の到来もここへ落ちる
      return
    }
    let elapsed = now.timeIntervalSince(since)
    if elapsed > MenuBarArrival.glossDelay + MenuBarArrival.glossDuration {
      phase.gloss = nil
      glossSince = nil
    } else if elapsed < MenuBarArrival.glossDelay {
      phase.gloss = nil
    } else {
      phase.gloss = (elapsed - MenuBarArrival.glossDelay) / MenuBarArrival.glossDuration
    }
  }

  /// 尺 0（Reduce Motion）は「その場で撃ち終わっている」＝進捗 1。
  private func progress(since: Date, now: Date, over duration: TimeInterval) -> Double {
    guard duration > 0 else { return 1 }
    return min(1, max(0, now.timeIntervalSince(since) / duration))
  }
}
