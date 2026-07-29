import Foundation
import Observation

/// Attention 一覧の単一情報源（@Observable・main のみ）。WindowController が既存の chrome
/// coalesce（`flushChrome`）と同じ契機で snapshot を流し込み、パレットとメニューバーが同じ値を読む。
@Observable final class AttentionStore {
  /// 全対象行（waiting/done/working・stateChangedAt 降順）。`apply(rows:)` だけが差し替える。
  private(set) var rows: [AttentionRow] = []

  /// メニューバーの一覧行（waiting/done のみ）。
  var listRows: [AttentionRow] { AttentionSnapshot.listRows(rows) }
  /// メニューバーの件数 = waiting+done のみ（working は数えない）。
  var count: Int { listRows.count }
  /// working の減光集約ラベル（0 件は nil）。
  var workingLabel: String? { AttentionSnapshot.workingLabel(rows) }

  /// メニューバー②（状態変化の瞬間の滲み出し）の**滞留**時間（秒）。ユーザー確定値。
  /// ②の尺のうちここが持つのは滞留だけで、展開・艶・収縮は `MenuBarArrival`。
  /// 滞留の後に 600ms の収縮が続くので、②の総寿命は 22.6 秒。
  static let transientDwell: TimeInterval = 22

  /// メニューバー②（状態変化の瞬間の滲み出し）の一過性イベント。
  /// waiting / done への実変化のときだけ report 経路（controlReportAgent）が立てる。
  /// 期限管理（ホバー延長・収縮）は MenuBarController が担う。
  struct Transient {
    let row: AttentionRow
    /// 到来時刻。ホバー延長では変わらない——MenuBarController が「新しい到来か」を見分ける印
    /// （同じ paneId の積み替えも新しい到来なので `paneId` の比較では見分けられない）。
    let arrivedAt: Date
    /// 収縮の開始時刻（＝滞留の満了）。
    var expiresAt: Date
  }
  var transient: Transient?

  /// 一過性イベントを立てる（滞留 `transientDwell`。ホバー延長は MenuBarController）。
  func noteTransient(_ row: AttentionRow, now: Date = Date()) {
    transient = Transient(
      row: row, arrivedAt: now, expiresAt: now.addingTimeInterval(Self.transientDwell))
  }

  /// 行 snapshot を差し替え、②が指す行が一覧（`listRows`）に**同じ状態で**居なければ取り下げる。
  /// ②は一覧の投影なので、投影元が消えた（`idle` へ落ちた・`clear` された・閉じられた）／別の
  /// 状態になった（`working` へ戻った）ピルは残さない。行が残っている間の中身は更新しない
  /// （差し替えは report 経路が新しい行で立て直す）。
  ///
  /// 不変条件が成立するのは「行を差し替えた時点」であって常時ではない——`noteTransient` は
  /// まだ行に反映されていない変化を先に立てられる。
  func apply(rows newRows: [AttentionRow]) {
    rows = newRows
    guard let transient else { return }
    let projected = listRows.contains {
      $0.paneId == transient.row.paneId && $0.state == transient.row.state
    }
    if !projected { self.transient = nil }
  }
}
