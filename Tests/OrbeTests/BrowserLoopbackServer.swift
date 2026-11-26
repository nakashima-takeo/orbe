import Darwin
import Foundation

/// `O_NONBLOCK` リスナーを直列キュー＋`DispatchSourceRead` で管理し、`cancelHandler` 1 箇所だけで
/// `Darwin.close(fd)` する共通土台（`ControlServer.swift` と同じ規律）。
/// `stop()` は冪等で `close` 完了まで待ち、受け入れたクライアント FD には `SO_NOSIGPIPE` を設定する。
private final class LoopbackListener: @unchecked Sendable {
  private let queue: DispatchQueue
  private var listenFD: Int32
  private var acceptSource: DispatchSourceRead?
  private var onAccept: ((Int32) -> Void)?
  private let closeDone = DispatchSemaphore(value: 0)
  let port: UInt16

  init(label: String, port: UInt16 = 0) throws {
    let (fd, boundPort) = try Self.bindLoopback(port: port, listenBacklog: 8)
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      Darwin.close(fd)
      throw POSIXError(.EIO)
    }
    self.queue = DispatchQueue(label: label)
    self.listenFD = fd
    self.port = boundPort

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    let done = closeDone
    source.setEventHandler { [weak self] in self?.acceptAvailable() }
    source.setCancelHandler {
      Darwin.close(fd)
      done.signal()
    }
    self.acceptSource = source
  }

  func start(onAccept: @escaping (Int32) -> Void) {
    queue.sync {
      guard let source = acceptSource, self.onAccept == nil else { return }
      self.onAccept = onAccept
      source.resume()
    }
  }

  deinit {
    // queue 上で最後の強参照が落ちた場合に備え、deinit では queue.sync を使わず cancel のみ行う。
    if let source = acceptSource {
      if onAccept == nil { source.resume() }
      source.cancel()
    }
  }

  func stop() {
    let cancelled: Bool = queue.sync {
      guard let source = acceptSource else { return false }
      let needsResume = onAccept == nil
      acceptSource = nil
      onAccept = nil
      listenFD = -1
      if needsResume { source.resume() }
      source.cancel()
      return true
    }
    if cancelled {
      closeDone.wait()
    }
  }

  private func acceptAvailable() {
    guard listenFD >= 0, let onAccept else { return }
    while true {
      let client = accept(listenFD, nil, nil)
      if client < 0 { break }
      Self.configureClient(client)
      onAccept(client)
    }
  }

  private static func configureClient(_ fd: Int32) {
    // accept した FD は listener の O_NONBLOCK を継承するため、ブロッキング I/O へ戻す。
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }
    // テストプロセス（xctest）には SIGPIPE 無視がないため、切断競合での異常終了を防ぐ。
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  }

  static func bindLoopback(port: UInt16, listenBacklog: Int32?) throws -> (Int32, UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

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
      Darwin.close(fd)
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
}

/// 外部通信ゼロで `http://127.0.0.1:<port>` を提供するテスト用ループバック HTTP サーバー。
final class LocalLoopbackHTTPServer: @unchecked Sendable {
  enum Route: Sendable {
    /// 200 OK で全本文を返して接続を閉じる通常応答。
    case html(String)
    /// 302 Found リダイレクト応答（`Cache-Control: no-store` 付き）。
    case redirect(String)
    /// リクエスト受理後に応答を返さず接続を保留する（暫定遷移の検証用）。
    case hang
    /// 200 OK ヘッダと先頭本文だけ送って残余を保留し、コミット済み・読込継続中を作る。
    case partial(String)
    /// リクエストごとに順次応答を切り替え、末尾以降は最後の応答を返す。
    case sequence([Route])
  }

  private let responses: [String: Route]
  private let heldLock = NSLock()
  private var heldClients: [Int32] = []
  private var sequenceIndices: [String: Int] = [:]
  private var stopped = false
  private let listener: LoopbackListener
  let port: UInt16

  convenience init(port: UInt16 = 0, routes: [String: String]) throws {
    try self.init(port: port, responses: routes.mapValues(Route.html))
  }

  init(port: UInt16 = 0, responses: [String: Route]) throws {
    self.responses = responses
    let created = try LoopbackListener(label: "dev.orbe.test.http-loopback", port: port)
    self.listener = created
    self.port = created.port
    created.start { [weak self] client in
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else {
          Darwin.close(client)
          return
        }
        self.handleClient(client)
      }
    }
  }

  deinit {
    closeHeldConnections()
  }

  /// 一時的に空きポートを確保して即閉じ、ECONNREFUSED を起こす未起動ポート番号を返す。
  static func reserveClosedPort() throws -> UInt16 {
    let (fd, boundPort) = try LoopbackListener.bindLoopback(port: 0, listenBacklog: nil)
    Darwin.close(fd)
    return boundPort
  }

  func url(for path: String) -> URL {
    URL(string: "http://127.0.0.1:\(port)\(path)")!
  }

  func stop() {
    closeHeldConnections()
    listener.stop()
  }

  private func closeHeldConnections() {
    let openClients: [Int32] = heldLock.withLock {
      stopped = true
      let copy = heldClients
      heldClients.removeAll()
      return copy
    }
    for client in openClients {
      shutdown(client, SHUT_RDWR)
      Darwin.close(client)
    }
  }

  private func holdOrClose(_ fd: Int32) {
    let shouldClose: Bool = heldLock.withLock {
      if stopped { return true }
      heldClients.append(fd)
      return false
    }
    if shouldClose {
      Darwin.close(fd)
    }
  }

  private func handleClient(_ fd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0, let request = String(bytes: buffer.prefix(count), encoding: .utf8) else {
      Darwin.close(fd)
      return
    }
    let path =
      request.split(separator: "\r\n").first?
      .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
    let route = resolveRoute(for: path)
    sendRoute(route, to: fd)
  }

  private func resolveRoute(for path: String) -> Route? {
    guard let route = responses[path] else { return nil }
    guard case .sequence(let steps) = route, !steps.isEmpty else { return route }
    let index: Int = heldLock.withLock {
      let current = sequenceIndices[path, default: 0]
      sequenceIndices[path] = current + 1
      return current
    }
    return steps[min(index, steps.count - 1)]
  }

  private func sendRoute(_ route: Route?, to fd: Int32) {
    switch route {
    case .hang:
      holdOrClose(fd)
    case .partial(let body):
      let payload = Data(body.utf8)
      let header =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
        + "Content-Length: \(payload.count + 4096)\r\nConnection: close\r\n\r\n"
      writeAll(Data(header.utf8) + payload, to: fd)
      holdOrClose(fd)
    case .html(let body):
      sendHTML(body, status: "200 OK", to: fd)
      Darwin.close(fd)
    case .redirect(let location):
      let header =
        "HTTP/1.1 302 Found\r\nLocation: \(location)\r\n"
        + "Cache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      writeAll(Data(header.utf8), to: fd)
      Darwin.close(fd)
    case .sequence(let steps):
      sendRoute(steps.first, to: fd)
    case nil:
      sendHTML("", status: "404 Not Found", to: fd)
      Darwin.close(fd)
    }
  }

  private func sendHTML(_ body: String, status: String, to fd: Int32) {
    let payload = Data(body.utf8)
    let header =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    writeAll(Data(header.utf8) + payload, to: fd)
  }

  private func writeAll(_ data: Data, to fd: Int32) {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var written = 0
      while written < data.count {
        let n = write(fd, base.advanced(by: written), data.count - written)
        if n <= 0 { break }
        written += n
      }
    }
  }
}

/// TCP 接続を受け入れるが応答を返さず保留し、`stop()` で全接続を閉じるテスト用ループバックサーバー。
final class HangingLoopbackServer: @unchecked Sendable {
  private let lock = NSLock()
  private var clients: [Int32] = []
  private var stopped = false
  private let listener: LoopbackListener
  let port: UInt16

  init() throws {
    let created = try LoopbackListener(label: "dev.orbe.test.hang-loopback", port: 0)
    self.listener = created
    self.port = created.port
    created.start { [weak self] client in
      guard let self else {
        Darwin.close(client)
        return
      }
      self.acceptClient(client)
    }
  }

  deinit {
    closeAllClients()
  }

  func stop() {
    closeAllClients()
    listener.stop()
  }

  private func acceptClient(_ client: Int32) {
    let shouldClose: Bool = lock.withLock {
      if stopped { return true }
      clients.append(client)
      return false
    }
    if shouldClose {
      Darwin.close(client)
    }
  }

  private func closeAllClients() {
    let openClients: [Int32] = lock.withLock {
      stopped = true
      let copy = clients
      clients.removeAll()
      return copy
    }
    for client in openClients {
      shutdown(client, SHUT_RDWR)
      Darwin.close(client)
    }
  }
}
