import Foundation

/// dev サーバー検出。repo root 配下の pid が LISTEN している localhost ポートを lsof で探し、
/// 各候補へ `GET /` して `Content-Type` に text/html を含むポートだけを dev サーバーと見なし、
/// 慣習 dev ポート優先→最小ポートで 1 つ選んで http URL を返す（HTML を返さない MCP/API endpoint は除外）。
/// 外部コマンド・HTTP プローブは背景キューで同期実行し、結果のみ main へ返す。TTL 短期キャッシュで連打を抑える
/// （CompletionEngine.runShell の drain＋timeout 作法に倣う）。
final class DevServerProbe {
  static let shared = DevServerProbe()

  private let queue = DispatchQueue(label: "dev.orbe.devserver")
  private var cache: [String: (url: URL?, expires: Date)] = [:]
  private let ttl: TimeInterval = 2.5
  private static let timeout: TimeInterval = 2

  /// 慣習 dev ポート集合。ここに含まれるポートを最小ポートより優先して選ぶ
  /// （Vite の http と HMR が同居しても http 側を拾いやすくする）。
  private static let conventionalPorts: Set<Int> = [
    3000, 3001, 4200, 4321, 5000, 5173, 8000, 8080, 8888,
  ]

  /// repo root 配下で LISTEN 中の dev サーバー URL を返す（無ければ nil）。完了は main へ。
  func detect(repoRoot: String, _ done: @escaping (URL?) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      let url = self.compute(repoRoot: repoRoot)
      DispatchQueue.main.async { done(url) }
    }
  }

  /// queue 上で lsof を駆動して URL を得る。
  private func compute(repoRoot: String) -> URL? {
    let now = Date()
    if let hit = cache[repoRoot], now < hit.expires { return hit.url }
    cache = cache.filter { now < $0.value.expires }

    let listeners = Self.parseListeners(Self.run(["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"]))
    guard !listeners.isEmpty else { return store(repoRoot, nil) }

    let pids = Set(listeners.map { $0.pid })
    let pidArg = pids.map(String.init).joined(separator: ",")
    let cwds = Self.parseCwds(Self.run(["-a", "-p", pidArg, "-d", "cwd", "-Fpn"]))

    let root = Self.resolved(repoRoot)
    let ports = listeners.compactMap { listener -> Int? in
      guard let cwd = cwds[listener.pid], Self.isUnder(cwd, root: root) else { return nil }
      return listener.port
    }
    let htmlPorts = Set(ports).filter { Self.servesHTML(port: $0) }
    guard let port = Self.selectPort(htmlPorts) else { return store(repoRoot, nil) }
    return store(repoRoot, URL(string: "http://localhost:\(port)"))
  }

  private func store(_ repoRoot: String, _ url: URL?) -> URL? {
    cache[repoRoot] = (url, Date().addingTimeInterval(ttl))
    return url
  }

  // MARK: - 選択

  /// 慣習 dev ポートがあれば最小の慣習ポート、無ければ全体の最小ポートを選ぶ。
  private static func selectPort(_ ports: Set<Int>) -> Int? {
    if let conventional = ports.filter(conventionalPorts.contains).min() { return conventional }
    return ports.min()
  }

  // MARK: - lsof 出力の解析

  /// `-Fpn` 出力から localhost LISTEN の `{pid, port}` を集める。
  /// `p<pid>` が直前のプロセス集合を、`n<addr:port>` が socket を表す。
  private static func parseListeners(_ output: String) -> [(pid: Int, port: Int)] {
    var result: [(pid: Int, port: Int)] = []
    var pid: Int?
    for line in output.split(separator: "\n") {
      switch line.first {
      case "p":
        pid = Int(line.dropFirst())
      case "n":
        guard let pid, let (addr, port) = splitAddress(String(line.dropFirst())),
          isLocalhost(addr)
        else { continue }
        result.append((pid, port))
      default:
        continue
      }
    }
    return result
  }

  /// `-a -p <pids> -d cwd -Fpn` 出力から pid→cwd を集める。
  private static func parseCwds(_ output: String) -> [Int: String] {
    var result: [Int: String] = [:]
    var pid: Int?
    for line in output.split(separator: "\n") {
      switch line.first {
      case "p": pid = Int(line.dropFirst())
      case "n": if let pid { result[pid] = String(line.dropFirst()) }
      default: continue
      }
    }
    return result
  }

  /// `addr:port` を末尾コロンで分ける。port が数値でなければ nil（`*`＝任意ポートは対象外）。
  private static func splitAddress(_ value: String) -> (addr: String, port: Int)? {
    guard let sep = value.lastIndex(of: ":") else { return nil }
    guard let port = Int(value[value.index(after: sep)...]) else { return nil }
    return (String(value[..<sep]), port)
  }

  /// localhost で到達可能なバインドか（loopback / 全 IF ワイルドカード）。
  private static func isLocalhost(_ addr: String) -> Bool {
    switch addr {
    case "127.0.0.1", "0.0.0.0", "*", "[::1]", "::1", "[::]", "::":
      return true
    default:
      return false
    }
  }

  // MARK: - パス比較

  /// cwd が repo root と一致 or その配下か（シンボリックリンク解決済みで比較）。
  private static func isUnder(_ cwd: String, root: String) -> Bool {
    let path = resolved(cwd)
    return path == root || path.hasPrefix(root + "/")
  }

  private static func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  // MARK: - HTML プローブ

  private static let probeTimeout: TimeInterval = 1

  /// `GET http://localhost:<port>/` を短 timeout で叩き、`Content-Type` に text/html を含むか。
  /// リダイレクト・非 2xx でも判定は `Content-Type` のみ（4723 の 404＋非 html は除外、Vite 等の 200 text/html は残す）。
  /// timeout・接続不可・非 http（https 専用等）は false 扱い。queue 上で block してよい。
  private static func servesHTML(port: Int) -> Bool {
    guard let url = URL(string: "http://localhost:\(port)/") else { return false }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = probeTimeout
    config.timeoutIntervalForResource = probeTimeout
    let session = URLSession(configuration: config)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    let box = ContentTypeBox()
    let sem = DispatchSemaphore(value: 0)
    let task = session.dataTask(with: request) { _, response, _ in
      box.value = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
      sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + probeTimeout + 0.5) == .timedOut {
      task.cancel()
      session.invalidateAndCancel()
      return false
    }
    session.finishTasksAndInvalidate()
    guard let contentType = box.value else { return false }
    return contentType.lowercased().contains("text/html")
  }

  // MARK: - lsof 実行

  /// lsof を同期実行し stdout を返す（stdout のみ・timeout で打ち切り・queue 上で block してよい）。
  /// lsof は一部情報を取れないと非 0 終了するため終了コードは見ず stdout を素朴に解析する。
  private static func run(_ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return "" }

    // pipe を drain しないと大量 socket 列挙で write(2) がブロックし終わらない。
    let box = OutputBox()
    let sem = DispatchSemaphore(value: 0)
    let handle = out.fileHandleForReading
    DispatchQueue.global(qos: .userInitiated).async {
      box.data = (try? handle.readToEnd()) ?? Data()
      sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      sem.wait()
      return ""
    }
    process.waitUntilExit()
    return String(data: box.data, encoding: .utf8) ?? ""
  }
}

/// 別 queue で読んだ stdout を run へ受け渡す箱（queue 越え用）。
private final class OutputBox: @unchecked Sendable {
  var data = Data()
}

/// URLSession completion で得た Content-Type を servesHTML へ受け渡す箱（queue 越え用）。
private final class ContentTypeBox: @unchecked Sendable {
  var value: String?
}
