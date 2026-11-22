import Darwin
import Foundation
import OrbeTestSupport
import XCTest

@testable import Orbe

/// git grep を、1 行も出力しないうちに止めておく門——テスト用リポジトリの `core.excludesFile` を FIFO にする。git は探し始める
/// 前に除外ファイルを開くので、書き手が現れるまでそこで待つ。本番コードへのフックなしで「git が走っている最中」を決定論的に
/// 作る。git が生きているかは、このテストプロセスの子の git grep を見て確かめる。
///
/// 門で止まるのは git grep だけではなく、除外ファイルを読む git の全部（開いた文書の根の status など）。1 回の実行が除外ファイルを
/// 何度も開くこともある。だから開くときは、待っている git を 1 度通すのではなく、書き手を開いたまま持ち、後から来る git も、
/// 同じ実行の 2 度目の open も止めない。開いた後の git が止まらないのは、git が除外ファイルを開いた後、fstat の大きさが 0 なら
/// read せずに閉じるから（FIFO の大きさは 0）。書き手を持っている間に read すれば、`close()` まで止まる。
///
/// 門が閉じたまま残らないように: `close()`（tearDown）が門を開いて FIFO を普通の空ファイルに置き換え、それも呼び損ねたとき
/// （テストプロセスが落ちた）のために、60 秒後に待っている git を通して自ら終わる見張りを置く。
final class GrepGate {
  private let fifo: String
  private let watchdog: Process
  /// 開いた門の書き手（読み書きで開くので、読み手を待たずに開け、開いている間は FIFO の open が止まらない）。閉じている間は nil。
  private var held: Int32?

  /// `repo` の、除外ファイルを読む git を、この後から門で止める（設定を書くだけなので、既に走っているものには効かない）。
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

  /// このテストプロセスが起こした git grep の優先度（`ps` の pri。QoS で決まる——既定 31・utility 20）。走っていなければ nil。
  static var grepPriority: Int? {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", String(getpid()), "-f", "grep --no-index"]
    let pids = Pipe()
    pgrep.standardOutput = pids
    guard (try? pgrep.run()) != nil else { return nil }
    pgrep.waitUntilExit()
    let pid = String(bytes: pids.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .split(separator: "\n").first
    guard let pid else { return nil }
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "pri=", "-p", String(pid)]
    let out = Pipe()
    ps.standardOutput = out
    guard (try? ps.run()) != nil else { return nil }
    ps.waitUntilExit()
    return String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
      .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  /// 門で待っている git が着くまで待ってから、門を開いたままにする。
  func open(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(sleepUntil(timeout) { release() }, "門で待つ git がいない", file: file, line: line)
    hold()
  }

  /// 後始末。門を開き、FIFO を普通の空ファイルに置き換えてから書き手を閉じ、見張りを止める（置き換えた後に除外ファイルを開く
  /// git は、空のファイルを読む）。
  func close() {
    hold()
    let empty = fifo + ".empty"
    FileManager.default.createFile(atPath: empty, contents: Data())
    rename(empty, fifo)
    if let held { Darwin.close(held) }
    held = nil
    watchdog.terminate()
  }

  private func hold() {
    guard held == nil else { return }
    let fd = Darwin.open(fifo, O_RDWR)
    if fd >= 0 { held = fd }
  }

  /// 書き手として開いて閉じる（待っている読み手がいれば通る）。読み手がいなければ false。
  private func release() -> Bool {
    let fd = Darwin.open(fifo, O_WRONLY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    Darwin.close(fd)
    return true
  }
}
