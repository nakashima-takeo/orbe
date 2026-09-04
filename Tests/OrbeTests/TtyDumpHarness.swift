import AppKit
import Foundation
import XCTest

@testable import Orbe

/// ペインの PTY へ届いた生バイトを観測する駆動台。テストクラスではない支援ファイルで、
/// `ControlProcessHarness` と同じ位置づけ。
///
/// ペインに raw tty で読む dump プログラム（python3）を起こし、受信したバイト列を hex で画面へ
/// 書かせる。画面は `controlReadText` で読めるので、surface へ送ったキー入力が端末モード
/// （legacy / bracketed paste / kitty keyboard protocol）に応じてどんなバイトになったかを、
/// libghostty の符号化を通した実物で測れる。モードの切替（bracketed paste の有効化・kitty flags の
/// push）は dump 自身が行う。
///
/// 1 打ごとに `next()` で待ってから次を送る——連打すると dump の 1 回の read に複数打が合流し、
/// 打鍵単位の突き合わせができなくなる。
final class TtyDumpPane {
  enum Mode: String { case legacy, paste, kitty }

  /// 1 打あたりの到達を待つ上限。実時間の検証ではなく、進まなくなったら諦めるための上限。
  static let keyTimeout: TimeInterval = 5

  private static let script = """
    import os, sys, tty
    mode = sys.argv[1]
    fd = sys.stdin.fileno()
    tty.setraw(fd)
    enter = {"paste": "\\x1b[?2004h", "kitty": "\\x1b[>1u"}.get(mode, "")
    sys.stdout.write(enter + "READY\\r\\n")
    sys.stdout.flush()
    while True:
        data = os.read(fd, 4096)
        if not data:
            break
        sys.stdout.write("GOT " + data.hex() + "\\r\\n")
        sys.stdout.flush()

    """

  /// dump のペインを 1 枚だけ持つ実 `WindowController`。ペイン（surface と PTY）の寿命は window が
  /// 持つので、駆動台がここで抱えて自分と同時に畳む（`ControlProcess.target` と同じ形）。
  let controller: WindowController
  let pane: SurfaceView
  private var consumed = 0

  /// `controller` のアクティブ workspace に dump のペインを開き、READY を待つ。
  init(
    in controller: WindowController, mode: Mode,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    self.controller = controller
    let script = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("ttydump.py")
    try Self.script.write(to: script, atomically: true, encoding: .utf8)
    let paneId = try XCTUnwrap(
      controller.controlSpawn(
        workspaceId: nil, cwd: nil,
        command: "/usr/bin/python3 \(script.path) \(mode.rawValue)"),
      "dump のペインを開けない", file: file, line: line)
    pane = try XCTUnwrap(controller.controlResolvePane(paneId), file: file, line: line)
    XCTAssertTrue(
      ControlProcess.waitUntil(ControlProcess.paneSettleTimeout) {
        self.screen().contains("READY")
      },
      "dump が READY にならない: \(screen())", file: file, line: line)
  }

  /// 次に届いたバイト列（`hex` と同じ表記）。届かなければ nil（`keyTimeout` まで待つ）。
  func next() -> String? {
    guard
      ControlProcess.waitUntil(Self.keyTimeout, { self.received().count > self.consumed })
    else { return nil }
    defer { consumed += 1 }
    return received()[consumed]
  }

  /// 期待値の側を dump と同じ表記へ（`"\u{1b}[A"` → `"1b5b41"`）。
  static func hex(_ bytes: String) -> String {
    bytes.utf8.map { String(format: "%02x", $0) }.joined()
  }

  private func screen() -> String { pane.controlReadText(scrollback: true) ?? "" }

  private func received() -> [String] {
    screen().split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return trimmed.hasPrefix("GOT ") ? String(trimmed.dropFirst(4)) : nil
    }
  }
}
