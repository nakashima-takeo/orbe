import Foundation

/// ペイン 1 枚の「agent スロット」の状態機械。格納は `SurfaceView.agentSlot` の 1 箇所だけで、
/// 「未消費のチケットに報告がある」「同一性なしの稼働」のような表現不能な状態を型で排除する。
/// exited は置かない——今日の配管に「動いて止まった」を生む遷移も読む消費者も存在しない
/// （プロセス終了は libghostty がペインごと閉じる）。再休眠等が実装されたらケースを足す。
enum AgentSlot: Equatable {
  /// agent と無関係なただのシェル。
  case none
  /// 凍結された同一性。未消費の復元チケット（materialize 開始で一度だけ消費される）。
  case dormant(AgentSession)
  /// 稼働中。同一性＋最新の自己報告（spawn 直後・初回報告前は report が nil）。
  case live(session: AgentSession, report: AgentReport?)
}

extension AgentSlot {
  /// スロットが保持する同一性（none は nil）。list_panes・snapshot の読み口。
  var session: AgentSession? {
    switch self {
    case .none: return nil
    case .dormant(let s), .live(let s, _): return s
    }
  }

  /// 稼働中の最新の自己報告（live 以外は nil）。
  var report: AgentReport? {
    if case .live(_, let r) = self { return r }
    return nil
  }

  /// 未消費の復元チケットか（休眠集計の読み口）。
  var isDormant: Bool {
    if case .dormant = self { return true }
    return false
  }
}

/// 稼働中プロセスの最新の自己報告。live と完全に同じ寿命（dormant / none には存在しえない）。
struct AgentReport: Equatable {
  /// 報告された状態（idle / working / waiting / done）。
  var state: String
  /// 文言と出所（waiting の質問文・done の最終応答）。Attention 一覧が読む。
  var message: AgentMessage?
  /// state の値が実際に変わった時刻（Attention の並び・経過時間表示）。
  /// 同値の連続報告・done のフォーカス消費（done→idle）では動かさない。
  var stateChangedAt: Date
}

extension AgentSession {
  /// 報告で同一性を更新する。command は毎報告で上書きし、sessionId は**同じ CLI からの報告の
  /// あいだだけ** sticky——session id は発行した CLI に属する値なので、CLI が変われば旧 id は
  /// resume 不能な無意味な値になり捨てる。
  func updated(command: String, sessionId: String?) -> AgentSession {
    AgentSession(
      command: command,
      sessionId: sessionId ?? (command == self.command ? self.sessionId : nil))
  }
}
