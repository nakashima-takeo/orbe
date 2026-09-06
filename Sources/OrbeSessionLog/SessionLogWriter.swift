import Darwin
import Foundation

/// `agent-sessions.jsonl` の書き手。1 行 1 イベントを O_APPEND で 1 write（追記）、剪定後の書き直しは
/// 同ディレクトリの一時ファイルへ書いて `rename(2)`（原子的）。
public enum SessionLogWriter {
  /// 1 行ぶんのバイト列（JSON + 改行）。追記・書き直し・保持上限の計量が同じ符号化を使う。
  public static func encodeLine(_ event: SessionEvent) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(event)
    data.append(0x0A)
    return data
  }

  public static func append(_ event: SessionEvent, to url: URL) throws {
    let line = try encodeLine(event)
    let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { throw posixError() }
    defer { Darwin.close(fd) }
    try line.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var sent = 0
      while sent < line.count {
        let n = Darwin.write(fd, base + sent, line.count - sent)
        if n < 0 {
          if errno == EINTR { continue }
          throw posixError()
        }
        sent += n
      }
    }
  }

  public static func rewrite(_ events: [SessionEvent], to url: URL) throws {
    var data = Data()
    for event in events { data.append(try encodeLine(event)) }
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(url.lastPathComponent + ".tmp-\(getpid())")
    try data.write(to: temp)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
    guard Darwin.rename(temp.path, url.path) == 0 else {
      let error = posixError()
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
  }

  private static func posixError() -> Error {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
