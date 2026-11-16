import Foundation

@testable import Orbe

/// 子プロセスの親とセッションを作り分ける起動。制御端末を持つかどうかで振る舞いが変わる呼び出しを、テストを動かす環境が
/// 端末を持つかどうかに関わらず再現する。
extension ControlProcess {
  /// codex が hook または MCP サーバーを起動するときに作る区切り。codex は hook を新しいセッションの先頭として、MCP サーバーを
  /// 新しいプロセスグループの先頭として（セッションは自分と同じまま）起動する。デーモンを使うかどうかに関わらず同じ。
  enum CodexChild {
    case newSession
    case newGroup

    /// 区切りを作る perl の 1 文。
    fileprivate var start: String {
      switch self {
      case .newSession: #"POSIX::setsid() or die "setsid: $!";"#
      case .newGroup: #"POSIX::setpgid(0, 0) or die "setpgid: $!";"#
      }
    }
  }

  /// `run` と同じく子プロセスを起動して回収するが、デーモン経由の codex と同じ親子関係で起動する。端末から切り離したプロセス
  /// （デーモン役）が、`child` の種類のセッションまたはプロセスグループを作ってから実行ファイルを起動する。テストを動かす環境が
  /// 端末を持つかどうかに関わらず、実行ファイルが属するセッション（またはプロセスグループ）の先頭の親、つまりデーモン役は端末を持たない。
  static func runDetached(
    _ executable: URL, _ args: [String], env: [String: String], stdin: String? = nil,
    cwd: String? = nil, child: CodexChild, file: StaticString = #filePath, line: UInt = #line
  ) -> Outcome {
    run(
      URL(fileURLWithPath: "/usr/bin/perl"),
      ["-MPOSIX", "-e", detach(child.start), executable.path] + args,
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

  /// `words` を、codex が子を起動するのと同じ区切り（`child`）の先頭として実行するシェルの 1 行。このシェル（会話を動かす
  /// codex の役）は端末を持ったままなので、タブの中で使えばデーモンを使わない codex と同じ親子関係になる。
  static func shellCommand(_ words: [String], as child: CodexChild) -> String {
    let start = child.start + #" exec @ARGV or die "exec: $!";"#
    return (["/usr/bin/perl", "-MPOSIX", "-e", start] + words).map(ShellWord.quoted)
      .joined(separator: " ")
  }
}
