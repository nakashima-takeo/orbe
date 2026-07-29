import Darwin
import Foundation

/// 外部やエージェントが Orbe を操作するための domain 操作（main スレッドでのみ呼ぶ）。
/// 実体は WindowController。ControlServer がリクエストを main へ hop して叩く。
protocol ControlTarget: AnyObject {
  func controlListWorkspaces() -> [[String: Any]]
  func controlListPanes() -> [[String: Any]]
  /// 検出済みエージェント CLI を列挙する（読み取り専用）。
  /// 検出未完了なら空配列（エラーにしない）。
  func controlListAgents() -> [[String: Any]]
  func controlResolvePane(_ id: Int) -> SurfaceView?
  /// 新タブをアクティブ workspace（または指定 workspace）に開く。戻り値は新ペイン ID。
  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?) -> Int?
  /// 背景/休眠 workspace を前面化し全タブを mount する。戻り値は activate 後の
  /// activeWorkspaceId と当該 workspace のペイン ID 群。未知 id は nil（spawn と違いフォールバックしない）。
  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, paneIds: [Int])?
  /// エージェント hook の状態報告を発信元ペインへ適用する（report_agent）。
  func controlReportAgent(
    pane: SurfaceView, agent: String, state: String, sessionId: String?, message: String?)
  /// 指定ペインを分割し新ペイン ID を返す（split_pane）。direction は "right"=左右 / "down"=上下。
  /// 所有 TerminalController の split(from:command:) へ委譲する。未解決ペインは -32004。
  func controlSplitPane(paneId: Int, direction: String, command: String?)
    -> Result<Any, ControlError>
  /// 指定ペインを閉じる（close_pane）。所有 TerminalController.close へ委譲。未解決は -32004。
  func controlClosePane(paneId: Int) -> Result<Any, ControlError>
  /// 指定ペインへフォーカスする（focus_pane）。別 WS なら activate＋タブ選択も行う。未解決は -32004。
  func controlFocusPane(paneId: Int) -> Result<Any, ControlError>
  /// 指定タブ（TerminalController.id）を閉じる（close_tab）。カスケードは GUI（Cmd+W）と一致。未解決は -32004。
  func controlCloseTab(tabId: Int) -> Result<Any, ControlError>
  /// 全設定項目の実効値・由来 scope・型・値域（domain）を列挙する（config CLI 用・読み取り専用）。
  /// workspaceId 指定でその WS の上書きを重ねる（未指定はアクティブ WS）。未知 id は -32004。
  func controlConfigList(workspaceId: Int?) -> Result<Any, ControlError>
  /// 設定 1 項目を global / workspace スコープへ設定しライブ反映する（config CLI 用）。
  /// workspaceId 指定で対象 WS（未指定はアクティブ WS）の上書きへ書く。未知 id は -32004。
  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: Int?)
    -> Result<Any, ControlError>
  /// workspace を新規作成しアクティブ化する。戻り値は新 workspace の id・name・rootPath。
  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError>
  /// workspace を改名する（id 未発見 -32004・name 空 -32602）。
  func controlRenameWorkspace(workspaceId: Int, name: String) -> Result<Any, ControlError>
  /// workspace の rootPath を変更する（id 未発見 -32004・rootPath 空 -32602）。
  func controlSetWorkspaceRoot(workspaceId: Int, rootPath: String) -> Result<Any, ControlError>
  /// workspace を削除する（id 未発見 -32004・最後の 1 つは削除不可 -32000）。
  func controlRemoveWorkspace(workspaceId: Int) -> Result<Any, ControlError>
}

struct ControlError: Error {
  let code: Int
  let message: String
}

/// 外部 → Orbe の制御チャネル（out-of-band）のトランスポート。
/// Unix domain socket 上で改行区切り JSON-RPC 2.0 を喋る。受信は背景キュー、
/// domain 操作は main へ hop する。MCP・orbe-report・`orb` CLI が共有する唯一の制御契約面。
final class ControlServer {
  nonisolated(unsafe) static let shared = ControlServer()

  weak var target: ControlTarget?

  private let queue = DispatchQueue(label: "dev.orbe.control")
  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: Set<Connection> = []
  private(set) var socketPath = ""

  /// socketPath は StateDir から決定的に決まるため init で確定する（start より前に
  /// ペイン env 注入が socketPath を読む——復元ペインは WindowController.init 内 restore で
  /// mount され、AppDelegate の start() より前に走るため）。空なら制御 API 無効。
  private init() {
    guard let dir = StateDir.base() else { return }
    let path = dir.appendingPathComponent("control.sock").path
    // AF_UNIX の sun_path は 104 バイト上限。超えるなら諦める（汚い迂回はしない）。
    guard path.utf8.count < 104 else {
      NSLog("[control] socket path too long, control API disabled: \(path)")
      return
    }
    socketPath = path
  }

  /// ソケットを開いて待ち受け開始する。socketPath は workspaces.json と同じディレクトリ。
  func start(target: ControlTarget) {
    self.target = target
    guard !socketPath.isEmpty else { return }
    queue.async { self.openSocket() }
  }

  func stop() {
    queue.sync {
      acceptSource?.cancel()
      acceptSource = nil
      connections.forEach { $0.close() }
      connections.removeAll()
      if listenFD >= 0 { Darwin.close(listenFD) }
      listenFD = -1
      if !socketPath.isEmpty { unlink(socketPath) }
    }
  }

  /// 状態変化イベントを wait_for_event の待機者へ配信する（main から呼ばれ queue へ hop）。
  /// start 前 / stop 後は connections が空なので queue 上で no-op（フラグを main から読まない）。
  func emit(_ event: ControlEvent) {
    queue.async {
      for conn in self.connections { conn.deliver(event) }
    }
  }

  // MARK: - ソケット（すべて queue 上）

  private func openSocket() {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    unlink(socketPath)  // 前回の残骸を掃除

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          dst.update(from: src.baseAddress!, count: min(src.count, 104))
        }
      }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
      Darwin.close(fd)
      return
    }
    chmod(socketPath, 0o600)  // 所有ユーザーのみ（ディレクトリも 0700 相当）
    listenFD = fd

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptOne() }
    acceptSource = source
    source.resume()
  }

  private func acceptOne() {
    let cfd = accept(listenFD, nil, nil)
    guard cfd >= 0 else { return }
    // 非ブロッキング化。詰まった 1 接続の write/read を全体から隔離し head-of-line blocking を断つ。
    // 失敗した fd はブロッキングのままなので制御プレーンへ入れず捨てる（詰まると共有 queue を凍結させる）。
    let flags = fcntl(cfd, F_GETFL)
    guard flags >= 0, fcntl(cfd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      Darwin.close(cfd)
      return
    }
    let conn = Connection(fd: cfd, server: self, queue: queue)
    connections.insert(conn)
    conn.resume()
  }

  func remove(_ conn: Connection) {
    connections.remove(conn)
  }

  // MARK: - ルーティング（queue 上で 1 行受信ごとに）

  func handle(line: Data, from conn: Connection) {
    guard
      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let method = obj["method"] as? String
    else { return }
    let id = obj["id"]
    let params = obj["params"] as? [String: Any] ?? [:]

    if method == "wait_for_event" {
      conn.registerWait(id: id, params: params)
      return
    }

    DispatchQueue.main.async {
      // nil は「無応答契約」のメソッド（completion_update / completion_end）。
      // 応答を書かないことで、accept fd から読める行を accept 応答だけに保つ（framing 健全性）。
      guard let result = self.runOnMain(method: method, params: params) else { return }
      self.queue.async { conn.respond(id: id, result: result) }
    }
  }

  /// main スレッドで domain 操作を実行する。nil を返すメソッドは応答を書かない（無応答契約）。
  private func runOnMain(method: String, params: [String: Any]) -> Result<Any, ControlError>? {
    // 補完系は無応答契約（update/end は nil）を含むため、target 有無に依らず最優先で分離する
    // （target==nil 時に update/end が "no window" 応答を書くと accept fd に stray 行が残り framing が壊れる）。
    if method.hasPrefix("completion_") {
      let pane = (params["paneId"] as? Int).flatMap { target?.controlResolvePane($0) }
      return runCompletion(method: method, pane: pane, params: params)
    }

    guard let target = target else {
      return .failure(ControlError(code: -32000, message: "no window"))
    }
    return runWindowed(method: method, params: params, target: target)
  }

  /// ウィンドウ（target）を要するペイン/タブ/workspace 操作を実行する。
  private func runWindowed(method: String, params: [String: Any], target: ControlTarget)
    -> Result<Any, ControlError>
  {
    func pane() -> SurfaceView? { (params["paneId"] as? Int).flatMap(target.controlResolvePane) }
    let notFound = ControlError(code: -32004, message: "pane not found")

    switch method {
    case "list_workspaces":
      return .success(["workspaces": target.controlListWorkspaces()])
    case "list_panes":
      return .success(["panes": target.controlListPanes()])
    case "list_agents":
      return .success(["agents": target.controlListAgents()])
    case "get_pane_text":
      guard let p = pane() else { return .failure(notFound) }
      let scrollback = params["scrollback"] as? Bool ?? false
      return .success(["text": p.controlReadText(scrollback: scrollback) ?? ""])
    case "send_text":
      guard let p = pane() else { return .failure(notFound) }
      guard let text = params["text"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing text"))
      }
      p.controlSendText(text)
      return .success(["ok": true])
    case "send_key":
      guard let p = pane() else { return .failure(notFound) }
      guard let spec = params["key"] as? String, let key = ControlKey.parse(spec) else {
        return .failure(ControlError(code: -32602, message: "invalid key"))
      }
      p.controlSendKey(key)
      return .success(["ok": true])
    case "spawn":
      guard
        let pid = target.controlSpawn(
          workspaceId: params["workspaceId"] as? Int,
          cwd: params["cwd"] as? String,
          command: params["command"] as? String)
      else { return .failure(ControlError(code: -32000, message: "spawn failed")) }
      return .success(["paneId": pid])
    case "activate_workspace":
      guard let wid = params["workspaceId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing workspaceId"))
      }
      guard let r = target.controlActivateWorkspace(workspaceId: wid) else {
        return .failure(ControlError(code: -32004, message: "workspace not found"))
      }
      return .success(["activeWorkspaceId": r.activeWorkspaceId, "paneIds": r.paneIds])
    case "report_agent":
      guard let p = pane() else { return .failure(notFound) }
      guard let agent = params["agent"] as? String, let state = params["state"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing agent/state"))
      }
      target.controlReportAgent(
        pane: p, agent: agent, state: state, sessionId: params["sessionId"] as? String,
        message: params["message"] as? String)
      return .success(["ok": true])
    default:
      // ペイン/タブ操作・config / workspace CRUD は拡張の dispatch（ControlServer+Dispatch）へ。
      // どちらも非該当なら未知メソッド。
      return runPaneTab(method: method, params: params, target: target)
        ?? runConfigWorkspace(method: method, params: params, target: target)
        ?? .failure(ControlError(code: -32601, message: "method not found: \(method)"))
    }
  }

  /// 補完系メソッドを main で実行する。`completion_update` /
  /// `completion_end` は無応答契約で nil を返し、Connection が書込みを抑止する。
  private func runCompletion(method: String, pane: SurfaceView?, params: [String: Any])
    -> Result<Any, ControlError>?
  {
    switch method {
    case "completion_update":
      if let pane, let buffer = params["buffer"] as? String, let cursor = params["cursor"] as? Int {
        pane.completionUpdate(buffer: buffer, cursor: cursor)
      }
      return nil
    case "completion_end":
      pane?.completionEnd()
      return nil
    case "completion_accept":
      guard let pane else { return .failure(ControlError(code: -32004, message: "pane not found")) }
      let advance = params["advance"] as? Bool ?? true
      if let applied = pane.completionAccept(advance: advance) {
        return .success(["buffer": applied.buffer, "cursor": applied.cursor])
      }
      return .success(["buffer": NSNull()])
    default:
      return .failure(ControlError(code: -32601, message: "method not found: \(method)"))
    }
  }
}
