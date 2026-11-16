import Foundation

@testable import Orbe

/// 子プロセスの親とセッションを作り分ける起動。制御端末を持つかどうかで振る舞いが変わる呼び出しを、テストを動かす環境が
/// 端末を持つかどうかに関わらず再現する。
extension ControlProcess {
  /// `run` と同じく子プロセスを起動して回収するが、実行ファイルの親を、制御端末を持たないプロセス（新しいセッションの先頭）にする。
  /// デーモンのように端末から切り離された親が実行ファイルを起動する状況を、テストを動かす環境が端末を持つかどうかに関わらず作る。
  static func runDetached(
    _ executable: URL, _ args: [String], env: [String: String], stdin: String? = nil,
    cwd: String? = nil, file: StaticString = #filePath, line: UInt = #line
  ) -> Outcome {
    run(
      URL(fileURLWithPath: "/usr/bin/perl"), ["-MPOSIX", "-e", detach, executable.path] + args,
      env: env, stdin: stdin, cwd: cwd, file: file, line: line)
  }

  /// プロセスグループの先頭は setsid できないので、fork した子が setsid で端末から切り離してから、実行ファイルを起動する。
  private static let detach = """
    defined(my $pid = fork) or die "fork: $!";
    if ($pid) { waitpid($pid, 0); exit($? >> 8) }
    POSIX::setsid() or die "setsid: $!";
    exit(system(@ARGV) >> 8);
    """

  /// `words` を、それ自身だけ新しいセッションへ移して（制御端末を持たずに）実行するシェルの 1 行。親は端末を持ったまま。
  /// codex は hook を新しいセッションで起動するので、hook 自身は端末を持たず、会話を動かす親だけがタブの端末を持つ。
  static func shellCommandInNewSession(_ words: [String]) -> String {
    let start = #"POSIX::setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";"#
    return (["/usr/bin/perl", "-MPOSIX", "-e", start] + words).map(ShellWord.quoted)
      .joined(separator: " ")
  }
}
