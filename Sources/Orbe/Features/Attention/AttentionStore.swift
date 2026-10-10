import Foundation
import Observation

/// メニューバー②が映す中身。agent のタブ由来か、タスク由来か。
enum MenuBarNotice {
  /// 見ていないタブの状態変化。Attention 一覧の投影なので、投影元が消えれば取り下げる。
  case agent(AttentionRow)
  /// 待ちの条件が解けた瞬間。一覧の投影ではない出来事の知らせなので、取り下げは無い。
  case task(TaskNotice)
}

/// タスク由来の知らせの中身。本文は到来の時点の UI の言語で組んだもの。
struct TaskNotice: Equatable {
  let taskId: Int
  /// タスクの workspace の名前。workspace が無ければ nil（名前の欄を出さない）。
  let workspaceName: String?
  let text: String
}

/// Attention 一覧と、メニューバー②の一過性の知らせの単一情報源（@Observable・main のみ）。
/// WindowController が既存の chrome coalesce（`flushChrome`）と同じ契機で snapshot を流し込み、
/// パレットとメニューバーが同じ値を読む。
@Observable final class AttentionStore {
  /// 全対象行（waiting/done/working・stateChangedAt 降順）。`apply(rows:)` だけが差し替える。
  private(set) var rows: [AttentionRow] = []

  /// メニューバーの一覧行（waiting/done のみ）。
  var listRows: [AttentionRow] { AttentionSnapshot.listRows(rows) }
  /// メニューバーの件数 = waiting+done のみ（working は数えない）。
  var count: Int { listRows.count }
  /// working の減光集約 1 行の素材（件数と WS 名。0 件は nil）。書式は描画側が L10n で組む。
  var workingSummary: (count: Int, names: [String])? { AttentionSnapshot.workingSummary(rows) }

  /// メニューバー②（状態変化・待ちが解けた瞬間の滲み出し）の一過性イベント。
  /// 立てるのは窓の通知の流し口（`WindowController.deliver`）だけ。
  /// 期限管理（ホバー延長・収縮）は MenuBarController が担う。
  struct Transient {
    let notice: MenuBarNotice
    /// 到来時刻。ホバー延長では変わらない——MenuBarController が「新しい到来か」を見分ける印
    /// （同じ tabId の積み替えも新しい到来なので `tabId` の比較では見分けられない）。
    let arrivedAt: Date
    /// 到来した瞬間の件数。開いている間の②はこれを見せる——`count` は報告の coalesce で
    /// 展開の途中に増えるので、実件数を見せると 0→1 の到来で数字が展開中に閃く（原典は
    /// 「閉じながら生まれる」）。到来ごとに一度だけ確定し、その到来が終わるまで動かない。
    let arrivedCount: Int
    /// 収縮の開始時刻（＝滞留の満了）。
    var expiresAt: Date
    /// 投影元が消えて取り下げが決まった（agent の中身だけ）。ここから閉じるだけで、②としてはもう生きていない
    /// （中身は収縮を描き切るために残す——落とすのは閉じ切った `MenuBarController`）。
    var retracted = false
  }
  var transient: Transient?

  /// 一過性イベントを立てる。`dwell`（滞留秒）は到来の属性——立てる側が発信元 workspace の
  /// 実効設定（`menubar-notification-duration`）から解決して渡し、その到来が終わるまで動かない。
  /// store が既定を持たないのは、発信元を知らない store が設定の既定と別口の既定を作らないため。
  /// ホバー延長は MenuBarController が `expiresAt` を伸ばす。
  func noteTransient(_ notice: MenuBarNotice, dwell: TimeInterval, now: Date = Date()) {
    transient = Transient(
      notice: notice, arrivedAt: now, arrivedCount: count,
      expiresAt: now.addingTimeInterval(dwell))
  }

  /// 行 snapshot を差し替え、②が指す agent の行が一覧（`listRows`）に**同じ状態で**居なければ取り下げる。
  /// ②は一覧の投影なので、投影元が消えた（`idle` へ落ちた・`clear` された・閉じられた）／別の
  /// 状態になった（`working` へ戻った）ピルは残さない。行が残っている間の中身は更新しない
  /// （差し替えは report 経路が新しい行で立て直す）。
  ///
  /// 取り下げは `retracted` を立てるだけで、`transient` はここでは落とさない——落とすのは
  /// 収縮を描き切った `MenuBarController`。②が消える見え方を「収縮 1 つ」に保つ。
  ///
  /// 不変条件が成立するのは「行を差し替えた時点」であって常時ではない——`noteTransient` は
  /// まだ行に反映されていない変化を先に立てられる。
  func apply(rows newRows: [AttentionRow]) {
    rows = newRows
    guard let transient, !transient.retracted, case .agent(let row) = transient.notice else {
      return
    }
    let projected = listRows.contains { $0.tabId == row.tabId && $0.state == row.state }
    if !projected { self.transient?.retracted = true }
  }
}
