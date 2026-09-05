import Foundation

/// Attention 一覧の 1 行（値型 snapshot）。`TerminalTab` 参照を UI に漏らさず、
/// パレット・メニューバードロップダウンが同じ形を読む。
struct AttentionRow: Equatable {
  let tabId: Int
  let workspaceName: String
  /// TerminalTab.displayTitle(workspaceRoot:) の導出タイトル。
  let tabTitle: String
  /// "waiting" | "done" | "working"（builder が対象状態のみ集める）。
  let state: String
  /// hook 由来の文言。working は持たない（ライブ進行は配管しない＝builder が nil に落とす）。
  let message: String?
  let stateChangedAt: Date
}

/// Attention snapshot の builder と派生（pure）。対象は**activatedタブのライブスロットのみ**で、
/// agentState ∈ {waiting, done, working} のタブを
/// stateChangedAt 降順（同時刻は tabId 降順）に並べる。idle・nil は出さない。
enum AttentionSnapshot {
  /// 一覧に出す状態（idle は出さない。nil は対象外）。
  static let attentionStates: Set<String> = ["waiting", "done", "working"]

  /// 全 workspace を走査して Attention 行を組む。未activatedタブは対象外。
  static func rows(of workspaces: [Workspace]) -> [AttentionRow] {
    var out: [AttentionRow] = []
    for ws in workspaces {
      for tab in ws.tabs where tab.activated {
        guard let report = tab.agentReport, attentionStates.contains(report.state) else {
          continue
        }
        out.append(
          AttentionRow(
            tabId: tab.id,
            workspaceName: ws.name,
            tabTitle: tab.displayTitle(workspaceRoot: ws.rootPath),
            state: report.state,
            message: report.state == "working" ? nil : report.message?.text,
            stateChangedAt: report.stateChangedAt))
      }
    }
    return out.sorted {
      if $0.stateChangedAt != $1.stateChangedAt { return $0.stateChangedAt > $1.stateChangedAt }
      return $0.tabId > $1.tabId
    }
  }

  /// メニューバーの一覧行 = waiting/done のみ（working は数えず・出さず、下の集約 1 行へ）。
  static func listRows(_ rows: [AttentionRow]) -> [AttentionRow] {
    rows.filter { $0.state != "working" }
  }

  /// working の減光集約 1 行の**素材**（件数と WS 名。名は重複排除・出現順）。0 件は nil。
  /// 書式は持たない——語順が言語で変わるので、組み立ては L10n テンプレート
  /// （`.menubarWorkingSummary`）を通す描画側の仕事。
  static func workingSummary(_ rows: [AttentionRow]) -> (count: Int, names: [String])? {
    let working = rows.filter { $0.state == "working" }
    guard !working.isEmpty else { return nil }
    var seen = Set<String>()
    let names = working.map(\.workspaceName).filter { seen.insert($0).inserted }
    return (working.count, names)
  }

  /// 経過時間の表示（`45s` / `8m` / `2h` / `3d`）。負は 0s に丸める。
  static func elapsedLabel(from: Date, to: Date) -> String {
    let seconds = max(0, Int(to.timeIntervalSince(from)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d"
  }
}
