import Darwin
import Foundation
import XCTest

@testable import Orbe

/// git grep を、1 行も出力しないうちに止めておく門——テスト用リポジトリの `core.excludesFile` を FIFO にする。git は探し始める
/// 前に除外ファイルを開くので、書き手が現れるまでそこで待つ。本番コードへのフックなしで「git が走っている最中」を決定論的に
/// 作る。git が生きているかは、このテストプロセスの子の git grep を見て確かめる。
///
/// 門が閉じたまま残らないように: `close()`（tearDown）が待っている git を通し、それも呼び損ねたとき（テストプロセスが落ちた）
/// のために、60 秒後に待っている git を通して自ら終わる見張りを置く。
final class GrepGate {
  private let fifo: String
  private let watchdog: Process

  /// `repo` の git grep をこの後から門で止める（設定を書くだけなので、既に走っているものには効かない）。
  init(_ repo: TempGitRepo) throws {
    fifo =
      repo.dir.deletingLastPathComponent()
      .appendingPathComponent("orbe-gate-\(UUID().uuidString)").path
    guard mkfifo(fifo, 0o600) == 0 else { throw POSIXError(.EIO) }
    watchdog = Process()
    watchdog.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    watchdog.arguments = [
      "-e",
      "use Fcntl; sleep 60; for (1..50) { sysopen(my $f, $ARGV[0], O_WRONLY|O_NONBLOCK) or last; close $f }",
      fifo,
    ]
    try watchdog.run()
    XCTAssertTrue(repo.git(["config", "core.excludesFile", fifo]).isSuccess)
  }

  /// このテストプロセスが起こした git grep が生きているか。
  static var isGrepRunning: Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", String(getpid()), "-f", "grep --no-index"]
    pgrep.standardOutput = FileHandle.nullDevice
    guard (try? pgrep.run()) != nil else { return false }
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0
  }

  /// 門で待っている git を通す（着くまで待ってから）。
  func open(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while !release(), Date() < deadline { usleep(10_000) }
    XCTAssertLessThan(Date(), deadline, "門で待つ git がいない", file: file, line: line)
    while release() {}
  }

  /// 後始末。待っている git を通し、見張りを止めて FIFO を消す。
  func close() {
    while release() {}
    watchdog.terminate()
    unlink(fifo)
  }

  /// 書き手として開いて閉じる（待っている読み手がいれば通る）。読み手がいなければ false。
  private func release() -> Bool {
    let fd = Darwin.open(fifo, O_WRONLY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    Darwin.close(fd)
    return true
  }
}
