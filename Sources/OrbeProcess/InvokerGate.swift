import Darwin

/// `.app` 同梱の状態報告 CLI（`orbe-report`）と MCP ブリッジ（`orbe-mcp`）が、呼び出しに応えるかの判定。
///
/// codex からの呼び出しには、codex が直接起動したプロセス（起点）の親が制御端末を持つときだけ応える。起点の親は会話を
/// 動かしているプロセスで、デーモン経由の codex ではそれが端末から切り離された常駐プロセスになり、環境（`ORBE_TAB` など）は
/// デーモンを起動した時点の誰かの端末のもの——今の会話のタブとは関係が無い。環境がそのタブのものであることまでは確かめない。
/// ほかの CLI については、hook と MCP サーバーをどう起動するかを確かめていないので、判定しない。
public enum InvokerGate {
  /// codex が起点をどう起動したか。起点は、codex が子孫ごと止めるために作るセッションまたはプロセスグループの先頭なので、
  /// 間に挟まるシェルやシムが exec するかどうかに左右されない。
  public enum Invocation {
    /// hook。codex は利用者のログインシェルを新しいセッションの先頭として起動するので、起点は自分のセッションの先頭。
    case hook
    /// MCP サーバー。codex はシェルを挟まず、新しいプロセスグループの先頭として（セッションは会話を動かしているプロセスと
    /// 同じまま）起動するので、起点は自分のプロセスグループの先頭。
    case mcpServer
  }

  /// 起点またはその親のプロセス情報を取得できなければ応えない（取り違えた身元で応えるより、応えない）。
  public static func admitsCaller(agent: String, as invocation: Invocation) -> Bool {
    guard agent == "codex" else { return true }
    let origin =
      switch invocation {
      case .hook: getsid(0)
      case .mcpServer: getpgrp()
      }
    guard origin > 0, let parent = ProcessEntry(pid: origin)?.parent,
      let entry = ProcessEntry(pid: parent)
    else { return false }
    return entry.hasControllingTerminal
  }
}
