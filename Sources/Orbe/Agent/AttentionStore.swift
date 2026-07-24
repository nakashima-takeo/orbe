import Foundation
import Observation

/// Attention 一覧の単一情報源（@Observable・main のみ）。WindowController が既存の chrome
/// coalesce（`flushChrome`）と同じ契機で snapshot を流し込み、パレットとメニューバーが同じ値を読む。
@Observable final class AttentionStore {
  /// 全対象行（waiting/done/working・stateChangedAt 降順）。`flushChrome` が代入する。
  var rows: [AttentionRow] = []

  /// メニューバーの一覧行（waiting/done のみ）。
  var listRows: [AttentionRow] { AttentionSnapshot.listRows(rows) }
  /// メニューバーの件数 = waiting+done のみ（working は数えない）。
  var count: Int { listRows.count }
  /// working の減光集約ラベル（0 件は nil）。
  var workingLabel: String? { AttentionSnapshot.workingLabel(rows) }

  /// メニューバー②（状態変化の瞬間の滲み出し）の表示時間（秒・唯一の定数）。ユーザー確定値。
  static let transientDuration: TimeInterval = 22

  /// メニューバー②（状態変化の瞬間・0〜`transientDuration` 秒の滲み出し）の一過性イベント。
  /// waiting / done への実変化のときだけ report 経路（controlReportAgent）が立てる。
  /// 期限管理（ホバー延長・収縮）は MenuBarController が担う。
  struct Transient {
    let row: AttentionRow
    var expiresAt: Date
  }
  var transient: Transient?

  /// 一過性イベントを立てる（表示期間 `transientDuration`。ホバー延長は MenuBarController）。
  func noteTransient(_ row: AttentionRow, now: Date = Date()) {
    transient = Transient(row: row, expiresAt: now.addingTimeInterval(Self.transientDuration))
  }
}
