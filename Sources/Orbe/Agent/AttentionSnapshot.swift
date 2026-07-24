import Foundation

/// Attention 一覧の 1 行（値型 snapshot）。`SurfaceView` 参照を UI に漏らさず、
/// パレット・メニューバードロップダウンが同じ形を読む。
struct AttentionRow: Equatable {
  let paneId: Int
  let workspaceName: String
  /// TerminalController.displayTitle(workspaceRoot:) の導出タイトル。
  let tabTitle: String
  /// "waiting" | "done" | "working"（builder が対象状態のみ集める）。
  let state: String
  /// hook 由来の文言。working は持たない（ライブ進行は配管しない＝builder が nil に落とす）。
  let message: String?
  let stateChangedAt: Date
}

/// Attention snapshot の builder と派生（pure）。対象は**ライブペインのみ**
/// （activated な workspace ＝休眠除外）で、agentState ∈ {waiting, done, working} のペインを
/// stateChangedAt 降順（同時刻は paneId 降順）に並べる。idle・nil は出さない。
enum AttentionSnapshot {
  /// 一覧に出す状態（idle は出さない。nil は対象外）。
  static let attentionStates: Set<String> = ["waiting", "done", "working"]

  /// 全 workspace を走査して Attention 行を組む。休眠（未 activate）workspace は対象外。
  static func rows(of workspaces: [Workspace]) -> [AttentionRow] {
    var out: [AttentionRow] = []
    for ws in workspaces where ws.activated {
      for tab in ws.tabs {
        for pane in tab.controlAllPanes() {
          guard let state = pane.agentState, attentionStates.contains(state) else { continue }
          out.append(
            AttentionRow(
              paneId: pane.id,
              workspaceName: ws.name,
              tabTitle: tab.displayTitle(workspaceRoot: ws.rootPath),
              state: state,
              message: state == "working" ? nil : pane.agentMessage,
              // 理論上 nil にならない（stateChangedAt は report が必ず立てる）が、防御で最古扱い。
              stateChangedAt: pane.agentStateChangedAt ?? .distantPast))
        }
      }
    }
    return out.sorted {
      if $0.stateChangedAt != $1.stateChangedAt { return $0.stateChangedAt > $1.stateChangedAt }
      return $0.paneId > $1.paneId
    }
  }

  /// メニューバーの一覧行 = waiting/done のみ（working は数えず・出さず、下の集約 1 行へ）。
  static func listRows(_ rows: [AttentionRow]) -> [AttentionRow] {
    rows.filter { $0.state != "working" }
  }

  /// working の減光集約ラベル（`2 working — ws1, ws2`）。WS 名は重複排除・出現順。0 件は nil。
  static func workingLabel(_ rows: [AttentionRow]) -> String? {
    let working = rows.filter { $0.state == "working" }
    guard !working.isEmpty else { return nil }
    var seen = Set<String>()
    let names = working.map(\.workspaceName).filter { seen.insert($0).inserted }
    return "\(working.count) working — \(names.joined(separator: ", "))"
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
