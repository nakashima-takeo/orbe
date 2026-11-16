import Foundation

@testable import Orbe

/// 子プロセスの親とセッションを作り分ける起動。制御端末を持つかどうかで振る舞いが変わる呼び出しを、テストを動かす環境が
/// 端末を持つかどうかに関わらず再現する。
extension ControlProcess {
  /// デーモンが実行ファイルを起動するときに作る、セッションまたはプロセスグループの種類。codex は hook を新しいセッションで、
  /// MCP サーバーを新しいプロセスグループで起動する。
  enum DaemonChild {
    case newSession
    case newGroup
  }

  /// `run` と同じく子プロセスを起動して回収するが、デーモン経由の codex と同じ親子関係で起動する。端末から切り離したプロセス
  /// （デーモン役）が、`child` の種類のセッションまたはプロセスグループを作ってから実行ファイルを起動する。テストを動かす環境が
  /// 端末を持つかどうかに関わらず、実行ファイルが属するセッション（またはプロセスグループ）の先頭の親、つまりデーモン役は端末を持たない。
  static func runDetached(
    _ executable: URL, _ args: [String], env: [String: String], stdin: String? = nil,
    cwd: String? = nil, child: DaemonChild, file: StaticString = #filePath, line: UInt = #line
  ) -> Outcome {
    let start =
      switch child {
      case .newSession: #"POSIX::setsid() or die "setsid: $!";"#
      case .newGroup: #"POSIX::setpgid(0, 0) or die "setpgid: $!";"#
      }
    return run(
      URL(fileURLWithPath: "/usr/bin/perl"),
      ["-MPOSIX", "-e", detach(start), executable.path] + args,
      env: env, stdin: stdin, cwd: cwd, file: file, line: line)
  }

  /// プロセスグループリーダーは setsid できないので、fork した子が setsid で端末から切り離してデーモン役になる。デーモン役は
  /// さらに fork し、その子が `start` でセッションまたはプロセスグループを作ってから実行ファイルへ exec する。
  private static func detach(_ start: String) -> String {
    """
    defined(my $pid = fork) or die "fork: $!";
    if ($pid) { waitpid($pid, 0); exit($? >> 8) }
    POSIX::setsid() or die "setsid: $!";
    defined(my $child = fork) or die "fork: $!";
    if (!$child) { \(start) exec @ARGV or die "exec: $!" }
    waitpid($child, 0);
    exit($? >> 8);
    """
  }

  /// `words` を、それ自身だけ新しいセッションへ移して（制御端末を持たずに）実行するシェルの 1 行。親は端末を持ったまま。
  /// codex は hook を新しいセッションで起動するので、hook 自身は端末を持たず、会話を動かす親だけがタブの端末を持つ。
  static func shellCommandInNewSession(_ words: [String]) -> String {
    let start = #"POSIX::setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";"#
    return (["/usr/bin/perl", "-MPOSIX", "-e", start] + words).map(ShellWord.quoted)
      .joined(separator: " ")
  }
}
