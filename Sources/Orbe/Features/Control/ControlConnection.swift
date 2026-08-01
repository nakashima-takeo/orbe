import Darwin
import Foundation

/// 1 クライアント接続。読み取り・行分割・応答・イベント待機を queue 上で扱う。
/// fd は非ブロッキング。送信は per-connection 出力バッファ + writeSource で backpressure を持つ。
/// fd・source・buffer 操作はすべて serial queue 上に閉じ、順序保証の前提を崩さない。
final class Connection: Hashable {
  /// 改行無しの 1 行上限（1 MiB）。制御 JSON-RPC は通常数 KB なので十分広く、枯渇を防ぐ。
  private static let maxLineBytes = 1 << 20
  /// 出力滞留上限（8 MiB）。get_pane_text の scrollback 全体でも収まる広さを取りつつ、
  /// 読まないクライアントを有限で切る。
  private static let maxOutBytes = 8 << 20

  private let fd: Int32
  private weak var server: ControlServer?
  private let queue: DispatchQueue
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var writeSourceActive = false  // writeSource が resume 済みか（suspend/resume の釣り合い管理）
  private var framer = LineFramer(maxLineBytes: Connection.maxLineBytes)
  private var outBuffer = Data()  // 送信待ちバイト列
  private var outStart = 0  // outBuffer 内の未送出先頭（front 削除の O(n) コピー回避）
  private var closed = false  // close 済みフラグ。冪等な close と、close 後の write/timeout 応答抑止に使う

  // wait_for_event の待機状態（最大 1 件 / 接続）。
  private var waitId: Any?
  private var waitPaneId: Int?
  private var waitKinds: Set<String>?
  // 待機の世代。登録ごとに +1 し、タイムアウトクロージャは自分の世代だけを打ち切る
  // （前の待機のタイムアウトが、後続の別待機を誤発火で横取りするのを防ぐ）。
  private var waitGen = 0

  init(fd: Int32, server: ControlServer, queue: DispatchQueue) {
    self.fd = fd
    self.server = server
    self.queue = queue
  }

  func resume() {
    let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    s.setEventHandler { [weak self] in self?.readAvailable() }
    // fd close は readSource の cancel handler 1 箇所のみ（writeSource には持たせない＝二重 close 防止）。
    s.setCancelHandler { [fd] in Darwin.close(fd) }
    readSource = s
    s.resume()
  }

  func close() {
    guard !closed else { return }  // 冪等
    closed = true
    if let w = writeSource {
      // suspended source を release するとクラッシュする → cancel 前に必ず resume で釣り合わせる。
      if !writeSourceActive { w.resume() }
      w.cancel()
      writeSource = nil
      writeSourceActive = false
    }
    readSource?.cancel()  // cancel handler が fd を閉じる
    readSource = nil
    outBuffer.removeAll(keepingCapacity: false)
    outStart = 0
  }

  /// 受信エラー・overflow・送信エラーから接続を畳む。connections からの除去と close をまとめる。
  private func disconnect() {
    server?.remove(self)
    close()
  }

  private func readAvailable() {
    // 非ブロッキング fd は 1 回の read で全ては読めない／level-trigger で再発火するため、
    // EAGAIN まで drain する。
    var tmp = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(fd, &tmp, tmp.count)
      if n > 0 {
        switch framer.feed(Data(tmp[0..<n])) {
        case .overflow:
          disconnect()
          return
        case .lines(let lines):
          for line in lines {
            server?.handle(line: line, from: self)
            if closed { return }  // ハンドラ経由で切断されたらバッチ残りの行も read もやめる
          }
        }
        continue
      }
      if n == 0 {
        disconnect()  // EOF
        return
      }
      // n < 0
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return }  // 読み切った
      disconnect()  // その他 errno
      return
    }
  }

  // MARK: - 応答 / イベント（queue 上）

  func respond(id: Any?, result: Result<Any, ControlError>) {
    var msg: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
    switch result {
    case .success(let value): msg["result"] = value
    case .failure(let err): msg["error"] = ["code": err.code, "message": err.message]
    }
    write(msg)
  }

  func registerWait(id: Any?, params: [String: Any]) {
    // 仕様は 1 接続 1 待機。既に待機中なら 2 件目は黙って捨てず即エラーで返す
    // （後勝ち上書きは 1 件目を無応答にしクライアントをハングさせる）。
    guard waitId == nil else {
      respond(id: id, result: .failure(ControlError(code: -32005, message: "wait already pending")))
      return
    }
    waitId = id
    waitPaneId = params["paneId"] as? Int
    waitKinds = (params["kinds"] as? [String]).map(Set.init)
    waitGen += 1
    let gen = waitGen
    let timeoutMs = params["timeoutMs"] as? Int ?? 30000
    queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
      guard let self, self.waitId != nil, self.waitGen == gen else { return }
      let pending = self.waitId
      self.clearWait()
      self.respond(id: pending, result: .success(["timedOut": true]))
    }
  }

  /// 待機中ならフィルタ一致するイベントで応答し、消費したかを返す。
  @discardableResult func deliver(_ event: ControlEvent) -> Bool {
    guard waitId != nil else { return false }
    if let paneId = waitPaneId, paneId != event.paneId { return false }
    if let kinds = waitKinds, !kinds.contains(event.kind) { return false }
    let pending = waitId
    clearWait()
    respond(id: pending, result: .success(["event": event.toDict()]))
    return true
  }

  private func clearWait() {
    waitId = nil
    waitPaneId = nil
    waitKinds = nil
  }

  private func write(_ obj: [String: Any]) {
    // close 済みなら fd は cancel ハンドラで閉じられ再利用されうる。
    // main 往復から戻った respond 等が無関係な fd へ書かないよう抑止する。
    guard !closed else { return }
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0A)
    // 滞留上限を超えるなら、この接続を drop（他接続・accept・event 配信は無傷）。
    if outBuffer.count - outStart + data.count > Connection.maxOutBytes {
      disconnect()
      return
    }
    outBuffer.append(data)
    flush()  // common case はここで送り切る＝低レイテンシ
  }

  /// outBuffer の未送出分を非ブロッキングで送れるだけ送る。送り切れなければ writeSource で待つ。
  private func flush() {
    while outStart < outBuffer.count {
      let n = outBuffer.withUnsafeBytes { raw -> Int in
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        return Darwin.write(fd, base + outStart, outBuffer.count - outStart)
      }
      if n > 0 {
        outStart += n
        continue
      }
      if n < 0 && errno == EINTR { continue }  // リトライ（残バイトを捨てない）
      if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        // 送出済み先頭（dead prefix）が残りの未送出分以上に積もったら前詰めする。
        // 完全 drain を挟まない遅い読み手の下で outStart が累積し、確保メモリが
        // maxOutBytes（未送出分のみ判定）を超えて単調増加するのを防ぐ。dead >= live
        // 閾値で圧縮するため償却 O(1)（front 削除の O(n²) は招かない）。
        if outStart >= outBuffer.count - outStart {
          outBuffer.removeSubrange(outBuffer.startIndex..<(outBuffer.startIndex + outStart))
          outStart = 0
        }
        resumeWriteSource()  // 書込可能まで待つ
        return
      }
      disconnect()  // EPIPE・n==0・その他 → 切断
      return
    }
    // 全部送れた
    outBuffer.removeAll(keepingCapacity: false)
    outStart = 0
    suspendWriteSource()
  }

  private func resumeWriteSource() {
    if writeSource == nil {
      let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
      w.setEventHandler { [weak self] in self?.flush() }
      // cancel handler で fd を閉じない——閉じるのは readSource 一択（二重 close 防止）。
      writeSource = w
    }
    if !writeSourceActive {
      writeSource?.resume()
      writeSourceActive = true
    }
  }

  private func suspendWriteSource() {
    if writeSourceActive {
      writeSource?.suspend()
      writeSourceActive = false
    }
  }

  static func == (lhs: Connection, rhs: Connection) -> Bool { lhs === rhs }
  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
