/// 制御 API `session_log` / `restore_sessions` の件数の上限。検証する Orbe と、上限いっぱいを送る `orb` が
/// 同じ値を見る（片方だけ動くと `orb session closed` / `restore --at` が毎回 -32602 で落ちる）。
public enum SessionLogLimits {
  /// `session_log` の `limit` 既定。
  public static let defaultLimit = 1000
  /// `session_log` の `limit` 上限。
  public static let maxLimit = 10000
  /// `restore_sessions` の `sessionIds` 1 回あたりの上限。
  public static let restoreMaxIds = 100
}
