import Darwin
import Foundation

/// 外部通信ゼロで `http://127.0.0.1:<port>` を提供するテスト用ループバック HTTP サーバー。
final class LocalLoopbackHTTPServer: @unchecked Sendable {
  private let listenFD: Int32
  private let routes: [String: String]
  let port: UInt16

  init(port: UInt16 = 0, routes: [String: String]) throws {
    self.routes = routes
    let (fd, boundPort) = try Self.bindLoopback(port: port, listenBacklog: 8)
    self.listenFD = fd
    self.port = boundPort
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.acceptLoop()
    }
  }

  /// 一時的に空きポートを確保して即閉じ、ECONNREFUSED を起こす未起動ポート番号を返す。
  static func reserveClosedPort() throws -> UInt16 {
    let (fd, boundPort) = try bindLoopback(port: 0, listenBacklog: nil)
    close(fd)
    return boundPort
  }

  fileprivate static func bindLoopback(port: UInt16, listenBacklog: Int32?) throws
    -> (Int32, UInt16)
  {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    let listenOK = listenBacklog.map { listen(fd, $0) == 0 } ?? true
    guard bound == 0, listenOK else {
      close(fd)
      throw POSIXError(.EADDRINUSE)
    }

    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    return (fd, UInt16(bigEndian: actual.sin_port))
  }

  func url(for path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
  }

  func stop() {
    shutdown(listenFD, SHUT_RDWR)
    close(listenFD)
  }

  private func acceptLoop() {
    while true {
      let client = accept(listenFD, nil, nil)
      if client < 0 { break }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        defer { close(client) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        self?.handleClient(client)
      }
    }
  }

  private func handleClient(_ fd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0, let request = String(bytes: buffer.prefix(count), encoding: .utf8) else {
      return
    }
    let path =
      request.split(separator: "\r\n").first?
      .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let body = routes[path] ?? ""
    let status = routes[path] != nil ? "200 OK" : "404 Not Found"
    let payload = Data(body.utf8)
    let header =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    let response = Data(header.utf8) + payload
    response.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var written = 0
      while written < response.count {
        let n = write(fd, base.advanced(by: written), response.count - written)
        if n <= 0 { break }
        written += n
      }
    }
  }
}

/// TCP 接続を受け入れるが応答を返さず保留し、`stop()` で全接続を閉じるテスト用ループバックサーバー。
final class HangingLoopbackServer: @unchecked Sendable {
  private let listenFD: Int32
  private let lock = NSLock()
  private var clients: [Int32] = []
  private var stopped = false
  let port: UInt16

  init() throws {
    let (fd, boundPort) = try LocalLoopbackHTTPServer.bindLoopback(port: 0, listenBacklog: 8)
    self.listenFD = fd
    self.port = boundPort
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.acceptLoop()
    }
  }

  func stop() {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    stopped = true
    let openClients = clients
    clients.removeAll()
    lock.unlock()
    shutdown(listenFD, SHUT_RDWR)
    close(listenFD)
    for client in openClients {
      shutdown(client, SHUT_RDWR)
      close(client)
    }
  }

  private func acceptLoop() {
    while true {
      let client = accept(listenFD, nil, nil)
      if client < 0 { break }
      lock.lock()
      if stopped {
        lock.unlock()
        close(client)
        break
      }
      clients.append(client)
      lock.unlock()
    }
  }
}
