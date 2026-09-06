import Darwin
import Foundation

/// 外部やエージェントが Orbe を操作するための domain 操作（main スレッドでのみ呼ぶ）。
/// 実体は WindowController。ControlServer がリクエストを main へ hop して叩く。
protocol ControlTarget: AnyObject {
  func controlListWorkspaces() -> [[String: Any]]
  func controlListTabs() -> [[String: Any]]
  /// 検出済みエージェント CLI を列挙する（読み取り専用）。
  /// 検出未完了なら空配列（エラーにしない）。
  func controlListAgents() -> [[String: Any]]
  func controlResolveTab(_ id: Int) -> TerminalTab?
  /// 新タブをアクティブ workspace（または指定 workspace）に開く。戻り値は新タブ ID。
  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?) -> Int?
  /// 検出済みエージェントを新タブで起こす（spawn_agent）。command 省略時は対象 workspace の
  /// 実効 default-agent を解く。未知 workspaceId は -32004・未検出 command は -32602・
  /// 検出ゼロは -32000。
  func controlSpawnAgent(command: String?, workspaceId: Int?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  /// 既存セッションを resume してエージェントを新タブで起こす（resume_agent）。
  /// 安全文字集合の外の sessionId は -32602。
  func controlResumeAgent(command: String, sessionId: String, workspaceId: Int?, cwd: String?)
    -> Result<AgentLaunch, ControlError>
  /// タブのエージェントへ text を送って Enter を押す（prompt_agent）。入力欄が空いている状態
  /// （idle / done / 報告なし）にだけ届く動詞で、working / waiting は -32000（何も送らない）、
  /// 未 mount も -32000。成功は nil。
  func controlPromptAgent(tab: TerminalTab, text: String) -> ControlError?
  /// 背景/休眠 workspace を前面化し全タブを mount する。戻り値は activate 後の
  /// activeWorkspaceId と当該 workspace のタブ ID 群。未知 id は nil（spawn と違いフォールバックしない）。
  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, tabIds: [Int])?
  /// エージェント hook の状態報告を発信元タブへ適用する（report_agent）。
  func controlReportAgent(tab: TerminalTab, report: AgentHookReport)
  /// 指定タブへフォーカスする（focus_tab）。別 WS なら activate＋タブ選択も行う。未解決は -32004。
  func controlFocusTab(tabId: Int) -> Result<Any, ControlError>
  /// 指定タブ（TerminalTab.id）を閉じる（close_tab）。カスケードは GUI（Cmd+W）と一致。未解決は -32004。
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

  let queue = DispatchQueue(label: "dev.orbe.control")
  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: Set<Connection> = []
  /// イベント履歴と seq の所有者は queue。接続の有無に依らず seq は進む（start 前 / stop 後も積む）。
  private var history = EventHistory(capacity: EventHistory.retainedRecords)
  private(set) var socketPath = ""

  /// socketPath は StateDir から決定的に決まるため init で確定する（start より前に
  /// タブの env 注入が socketPath を読む——復元タブは WindowController.init 内 restore で
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
      // listener fd を閉じるのは source の cancel handler 1 箇所だけ（`Connection` と同じ規律）。
      // fd ベースの source は cancel handler での close が libdispatch の要求。
      listenFD = -1
      if !socketPath.isEmpty { unlink(socketPath) }
    }
  }

  /// 状態変化イベントに seq を振って履歴へ積み、待機者へ配信する（任意スレッドから呼ばれ queue へ hop）。
  ///
  /// 順序保証: queue は FIFO なので、main の操作 A の後に積まれる応答 hop は A より前に emit された
  /// 全イベントを見た後に走る。A が引き起こす遷移がプロセス外の報告を経て届く経路（PTY 書込み →
  /// hook → report_agent → main → didSet → emit）では、そのイベントは必ず応答 hop より後に積まれる
  /// ——応答が刻む `latestSeq` は「A 以前の履歴位置」で、A の直後に queue で張った待機は A が
  /// 引き起こす遷移を取りこぼさない。逆に A 自身が main ブロック内で同期的に didSet → emit を撃つ
  /// 操作（`report_agent`）では emit が応答 hop より先に積まれ、応答の `seq` はその遷移を含む。
  func emit(_ event: ControlEvent) {
    queue.async {
      let record = self.history.append(event)
      for conn in self.connections { conn.deliver(record) }
    }
  }

  /// 応答時点の最新 seq（queue 上でのみ読む）。
  var latestSeq: Int {
    dispatchPrecondition(condition: .onQueue(queue))
    return history.latestSeq
  }

  /// `after` 以後の履歴を replay する（queue 上でのみ）。
  func replay(after: Int, where matches: (ControlEvent) -> Bool) -> EventHistory.Replay {
    dispatchPrecondition(condition: .onQueue(queue))
    return history.replay(after: after, where: matches)
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
    source.setCancelHandler { Darwin.close(fd) }
    acceptSource = source
    source.resume()
  }

  private func acceptOne() {
    let cfd = accept(listenFD, nil, nil)
    guard cfd >= 0 else { return }
    attach(fd: cfd)  // 既に queue 上なので直に呼ぶ（adopt は自 queue への sync になり詰まる）
  }

  /// 既に接続済みの fd を制御プレーンへ載せる（queue 外からの入口）。本番は listener の accept が
  /// queue 上で `attach` を直に呼ぶので、この口を使うのは socketpair を繋ぐテストだけ。生の fd を受け取るので
  /// 所有権の移譲はこの呼びで確定させる——`async` にすると「戻ったが所有権はまだ移っていない」
  /// 窓が開き、そこで呼び出し側が閉じると再利用された fd 番号が制御プレーンに載る。
  func adopt(fd: Int32) {
    // queue 上から呼ぶと自 queue への sync で即 deadlock する。この規律は規約に頼らず
    // ここで落とす——deadlock は「固まった」としか見えず、制御プレーン全体（accept・
    // 他接続・event 配信・timeout）が同時に止まるので原因に辿り着けない。trap なら
    // 違反した呼び出し元がその場でスタックに出る。
    dispatchPrecondition(condition: .notOnQueue(queue))
    queue.sync { attach(fd: fd) }
  }

  /// 非ブロッキング化・Connection 生成・登録・受信開始。
  /// Connection は必ずこの queue で作る——`handle` が respond をこの queue へ hop するため、
  /// 別 queue で作ると受信と送信が Connection の内部状態（出力バッファ・fd・writeSource）を
  /// 跨いで触ることになる。その規律を次行で強制する（`acceptOne` は queue 上なので直に、
  /// queue 外からは `adopt` 経由で入る、という非対称の受け側）。
  private func attach(fd: Int32) {
    dispatchPrecondition(condition: .onQueue(queue))
    // 非ブロッキング化。詰まった 1 接続の write/read を全体から隔離し head-of-line blocking を断つ。
    // 失敗した fd はブロッキングのままなので制御プレーンへ入れず捨てる（詰まると共有 queue を凍結させる）。
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      Darwin.close(fd)
      return
    }
    let conn = Connection(fd: fd, server: self, queue: queue)
    connections.insert(conn)
    conn.resume()
  }

  func remove(_ conn: Connection) {
    connections.remove(conn)
  }

  // MARK: - ルーティング（queue 上で 1 行受信ごとに）

  func handle(line: Data, from conn: Connection) {
    // 読めない行を黙って捨てない。クライアント（`orb` / MCP ブリッジ）は 1 行応答を待って
    // 読むので、無応答で return するとそのままハングになる。JSON-RPC 2.0 どおり 2 コードへ割る
    // ——「JSON テキストとして読めない」と「JSON だがリクエストオブジェクトでない」は別の失敗で、
    // 配列を送ったことを parse error と呼ぶのは嘘になる。
    guard let value = try? JSONSerialization.jsonObject(with: line) else {
      conn.respond(id: nil, result: .failure(ControlError(code: -32700, message: "parse error")))
      return
    }
    guard let obj = value as? [String: Any], let method = obj["method"] as? String else {
      // id は取れれば返す（配列には無い。最上位スカラは前段の -32700 に落ちてここへ来ない）。
      // guard で束ねた obj は else 節から見えないので、id を拾うのにここで再キャストする。
      conn.respond(
        id: (value as? [String: Any])?["id"],
        result: .failure(ControlError(code: -32600, message: "invalid request")))
      return
    }
    let id = obj["id"]
    let params = obj["params"] as? [String: Any] ?? [:]

    // 待機を伴う動詞は queue が受け持つ（main → respond の 1 往復では完結しない）。
    switch method {
    case "wait_for_event":
      conn.waitForEvent(id: id, params: params)
      return
    case "prompt_agent":
      promptAgent(id: id, params: params, conn: conn)
      return
    case "spawn_agent":
      launchAgent(id: id, params: params, conn: conn) {
        self.spawnAgent(params: params, target: $0)
      }
      return
    case "resume_agent":
      launchAgent(id: id, params: params, conn: conn) {
        self.resumeAgent(params: params, target: $0)
      }
      return
    default:
      break
    }

    DispatchQueue.main.async {
      // nil は「無応答契約」のメソッド（completion_update / completion_end）。打鍵ごとに応答を
      // 書くと、補完クライアントが accept 応答を読む前に fd へ行が積み、締切内に読めなくなる。
      guard let result = self.runOnMain(method: method, params: params) else { return }
      self.queue.async { conn.respond(id: id, result: result) }
    }
  }

  /// main スレッドで domain 操作を実行する。nil を返すメソッドは応答を書かない（無応答契約）。
  private func runOnMain(method: String, params: [String: Any]) -> Result<Any, ControlError>? {
    // 補完系は無応答契約（update/end は nil）を含むため、target 有無に依らず最優先で分離する
    // （target==nil 時に update/end が "no window" 応答を書くと、打鍵ぶんの行が accept 応答の前に積む）。
    if method.hasPrefix("completion_") {
      let surface = (params["tabId"] as? Int).flatMap { target?.controlResolveTab($0)?.surface }
      return runCompletion(method: method, surface: surface, params: params)
    }

    guard let target = target else {
      return .failure(ControlError(code: -32000, message: "no window"))
    }
    return runWindowed(method: method, params: params, target: target)
  }

  /// ウィンドウ（target）を要するタブ/workspace 操作を実行する。
  private func runWindowed(method: String, params: [String: Any], target: ControlTarget)
    -> Result<Any, ControlError>
  {
    func tab() -> TerminalTab? { (params["tabId"] as? Int).flatMap(target.controlResolveTab) }
    let notFound = ControlError(code: -32004, message: "tab not found")

    switch method {
    case "list_workspaces":
      return .success(["workspaces": target.controlListWorkspaces()])
    case "list_tabs":
      return .success(["tabs": target.controlListTabs()])
    case "list_agents":
      return .success(["agents": target.controlListAgents()])
    case "get_tab_text":
      guard let t = tab() else { return .failure(notFound) }
      let scrollback = params["scrollback"] as? Bool ?? false
      return .success(["text": t.surface.controlReadText(scrollback: scrollback) ?? ""])
    case "send_text":
      guard let t = tab() else { return .failure(notFound) }
      guard let text = params["text"] as? String else {
        return .failure(ControlError(code: -32602, message: "missing text"))
      }
      t.surface.controlSendText(text)
      return .success(["ok": true])
    case "send_key":
      guard let t = tab() else { return .failure(notFound) }
      guard let spec = params["key"] as? String, let key = ControlKey.parse(spec) else {
        return .failure(ControlError(code: -32602, message: "invalid key"))
      }
      t.surface.controlSendKey(key)
      return .success(["ok": true])
    case "spawn":
      guard
        let tid = target.controlSpawn(
          workspaceId: params["workspaceId"] as? Int,
          cwd: params["cwd"] as? String,
          command: params["command"] as? String)
      else { return .failure(ControlError(code: -32000, message: "spawn failed")) }
      return .success(["tabId": tid])
    case "activate_workspace":
      guard let wid = params["workspaceId"] as? Int else {
        return .failure(ControlError(code: -32602, message: "missing workspaceId"))
      }
      guard let r = target.controlActivateWorkspace(workspaceId: wid) else {
        return .failure(ControlError(code: -32004, message: "workspace not found"))
      }
      return .success(["activeWorkspaceId": r.activeWorkspaceId, "tabIds": r.tabIds])
    case "report_agent":
      guard let t = tab() else { return .failure(notFound) }
      guard let report = hookReport(params) else {
        return .failure(ControlError(code: -32602, message: "missing agent/state"))
      }
      target.controlReportAgent(tab: t, report: report)
      return .success(["ok": true])
    default:
      // タブ操作・config / workspace CRUD は拡張の dispatch（ControlServer+Dispatch）へ。
      // いずれも非該当なら未知メソッド。
      return runTab(method: method, params: params, target: target)
        ?? runConfigWorkspace(method: method, params: params, target: target)
        ?? .failure(ControlError(code: -32601, message: "method not found: \(method)"))
    }
  }

  /// 補完系メソッドを main で実行する。`completion_update` /
  /// `completion_end` は無応答契約で nil を返し、Connection が書込みを抑止する。
  private func runCompletion(method: String, surface: SurfaceView?, params: [String: Any])
    -> Result<Any, ControlError>?
  {
    switch method {
    case "completion_update":
      if let surface, let buffer = params["buffer"] as? String,
        let cursor = params["cursor"] as? Int
      {
        surface.completionUpdate(buffer: buffer, cursor: cursor)
      }
      return nil
    case "completion_end":
      surface?.completionEnd()
      return nil
    case "completion_accept":
      guard let surface else {
        return .failure(ControlError(code: -32004, message: "tab not found"))
      }
      let advance = params["advance"] as? Bool ?? true
      if let applied = surface.completionAccept(advance: advance) {
        return .success(["buffer": applied.buffer, "cursor": applied.cursor])
      }
      return .success(["buffer": NSNull()])
    default:
      return .failure(ControlError(code: -32601, message: "method not found: \(method)"))
    }
  }
}
