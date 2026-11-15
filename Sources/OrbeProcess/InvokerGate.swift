import Darwin

/// `.app` 同梱の状態報告 CLI（`orbe-report`）と MCP ブリッジ（`orbe-mcp`）が、呼び出しに応えるかの判定。
///
/// codex は hook と MCP サーバーを、会話を動かしているプロセスの直接の子として起動する。デーモン経由の codex では、そのプロセスは
/// 端末から切り離された常駐プロセスで、環境（`ORBE_TAB` など）はデーモンを最初に起動した端末のもの——今の会話のタブとは
/// 関係が無い。そこで codex からの呼び出しには、親が制御端末を持つときだけ応える。環境がそのタブのものであることまでは
/// 確かめない。ほかの CLI については、hook が会話を動かしているプロセスの直接の子として起動されるのかを確かめていないので、判定しない。
public enum InvokerGate {
  public static func admits(agent: String, parentHasControllingTerminal: Bool) -> Bool {
    agent != "codex" || parentHasControllingTerminal
  }

  /// このプロセスの親で判定する。親を読めなければ、制御端末を持たないとみなす。
  public static func admitsCaller(agent: String) -> Bool {
    admits(
      agent: agent,
      parentHasControllingTerminal: ProcessEntry(pid: getppid())?.hasControllingTerminal == true)
  }
}
