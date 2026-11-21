import Darwin

/// `.app` 同梱の状態報告 CLI（`orbe-report`）と MCP ブリッジ（`orbe-mcp`）が、呼び出しに応えるかの判定。
///
/// codex からの呼び出しには、codex が直接起動したプロセス（起点）の親が制御端末を持つときだけ応える。起点の親は会話を
/// 動かしているプロセスで、デーモン経由の codex ではそれが端末から切り離された常駐プロセスになり、環境（`ORBE_TAB` など）は
/// デーモンを起動した時点の誰かの端末のもの——今の会話のタブとは関係が無い。環境がそのタブのものであることまでは確かめない。
/// ほかの CLI は判定しない。agy と claude は hook と MCP サーバーを自分の直接の子として起動し、環境を受け継がせる（agy 1.5.13・
/// claude 2.1.330）。例外は claude の背景のセッションで、claude の常駐プロセスの下で動き、環境は常駐プロセスを最初に起こした
/// タブのもの。この判定はそれを見分けない。
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
