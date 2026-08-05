import AppKit
import Darwin
import Foundation
import XCTest

@testable import Orbe

/// L3 wire 契約の駆動台。`socketpair(2)` の片端を `ControlServer.shared` へ載せ、もう片端から
/// 行を書いて応答を読む。サーバ側は本番と同じ実 `Connection`・実 `LineFramer`・実 `handle` を通る。
///
/// listener は張らない（`start()` を呼ばない）ので、実 socket に bind する L4 と同じ singleton を
/// 共有していても待ち受けを奪い合わず、bind 完了を待つポーリングも要らない。
///
/// `teardown` は client fd を閉じて target を外すだけで、サーバ側の EOF 処理（`connections` からの
/// 自己除去）が control queue 上で非同期に終わるのは待たない。待たなくてよいのは `emit` が
/// `connections` 全件へ配るファンアウトだからで、待機を張ったまま終えたテスト（フィルタの素通りを
/// 見る 2 本）の残骸が起きても、後続テストが張った待機は消費されない。
///
/// 応答を読まない行を残したまま終えるのは別で、`handle` の main hop は実行時に
/// `ControlServer.shared.target` を読むため後続テストの Fake を汚す。各テストは送った行を
/// `nextResponse` か `barrier` で締めることでこれを断つ。
///
/// これが壊れると、制御プロトコルの語（method 名・params キー・エラーコード）を測る唯一の
/// 経路が消える。`WindowController` を直接叩く既存テストは `ControlServer` の検証層を丸ごと
/// 迂回するため、wire のキーを片側だけ改名しても全部緑のまま通る。
final class ControlWire {
  /// 応答待ちの上限。**実時間の検証ではない**——タイムアウト値の契約は `timeoutMs` を明示指定した
  /// テストだけが測り、ここは「進まなくなったら諦める」ための上限に過ぎない。
  private static let deadlineSeconds: TimeInterval = 2
  /// runloop を 1 回まわす刻み。control queue と main hop の両方をここで進ませる。
  private static let stepSeconds: TimeInterval = 0.005

  /// `ControlServer.shared.target` は weak なので、Fake の寿命はここが持つ。
  let target: FakeControlTarget?

  private var clientFD: Int32 = -1
  /// 読んだが行に切れていない残り。
  private var pending = Data()
  private var barrierSeq = 0

  init(target: FakeControlTarget?) {
    self.target = target
    ControlServer.shared.target = target

    var fds: [Int32] = [-1, -1]
    let made = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    precondition(made == 0, "socketpair に失敗した（errno=\(errno)）")
    clientFD = fds[0]

    // 相手が畳んだ後の write を EPIPE で受ける。テストプロセスには本番 main.swift の
    // `signal(SIGPIPE, SIG_IGN)` が無く、既定のままだと 1 本の失敗ではなく xctest ごと落ちる。
    // プロセス全域の signal を書き換えず、この socketpair の 2 本だけに閉じる。
    for fd in fds { Self.silencePipeSignal(fd) }
    // 応答待ちで runloop を回すため client 側も非ブロッキングにする。
    let flags = fcntl(clientFD, F_GETFL)
    precondition(flags >= 0 && fcntl(clientFD, F_SETFL, flags | O_NONBLOCK) >= 0, "O_NONBLOCK 失敗")

    // 生の fd の所有権はこの呼びで制御プレーンへ移る（以後この fd は Connection が閉じる）。
    ControlServer.shared.adopt(fd: fds[1])
  }

  private static func silencePipeSignal(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  func teardown() {
    if clientFD >= 0 {
      Darwin.close(clientFD)
      clientFD = -1
    }
    ControlServer.shared.target = nil
  }

  // MARK: - 送信

  /// JSON-RPC リクエストを 1 行として送る。
  func send(
    _ request: [String: Any], file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let data = try? JSONSerialization.data(withJSONObject: request) else {
      XCTFail("リクエストを JSON へ直列化できない: \(request)", file: file, line: line)
      return
    }
    sendRaw(data + Data([0x0A]), file: file, line: line)
  }

  /// 要求を 1 件送り、その応答を読む。応答の id が送った id と違えば失敗させる——表駆動で
  /// 何十件も往復するとき、1 件の取りこぼしが以降すべてを 1 つずれた応答で緑にしてしまう。
  func request(
    id: Int, method: String, params: [String: Any] = [:],
    file: StaticString = #filePath, line: UInt = #line
  ) -> [String: Any]? {
    send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], file: file, line: line)
    let response = nextResponse(file: file, line: line)
    XCTAssertEqual(
      response?["id"] as? Int, id,
      "\(method) の応答 id がずれた（行と応答の対応が崩れている）", file: file, line: line)
    return response
  }

  /// バイト列をそのまま送る（不正 JSON・不正 UTF-8・行の分割送信用）。改行は付けない。
  func sendRaw(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(Self.deadlineSeconds)
    var sent = 0
    while sent < bytes.count {
      let n = bytes.withUnsafeBytes { raw -> Int in
        let base = raw.bindMemory(to: UInt8.self).baseAddress!
        return Darwin.write(clientFD, base + sent, bytes.count - sent)
      }
      if n > 0 {
        sent += n
        continue
      }
      if n < 0 && errno == EINTR { continue }
      if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
          XCTFail("送信バッファが空かない（サーバが読み進めていない）", file: file, line: line)
          return
        }
        // 書き込み可能になった瞬間に再開する。runloop を一定刻みで回す形にすると、socket の
        // 送信バッファ（8 KiB）を空けるたびに刻みぶん止まり、1 MiB の送出だけで締切の大半を食う。
        var pfd = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
        _ = poll(&pfd, 1, Int32(min(remaining, Self.stepSeconds) * 1000))
        continue
      }
      // EPIPE 等。上限超過で切られたケース（overflow）はこれが正常な帰結なので黙って抜ける。
      return
    }
  }

  // MARK: - 受信

  /// 次の 1 行応答を JSON オブジェクトとして読む。読めなければ失敗させて nil。
  func nextResponse(file: StaticString = #filePath, line: UInt = #line) -> [String: Any]? {
    let raw: Data
    switch nextLine() {
    case .line(let data): raw = data
    case .eof:
      XCTFail("応答の前にサーバが接続を畳んだ", file: file, line: line)
      return nil
    case .timedOut:
      XCTFail("応答が 1 行も返らない（無応答のままハングする契約違反）", file: file, line: line)
      return nil
    }
    guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
      let shown = String(bytes: raw, encoding: .utf8) ?? "<非 UTF-8 \(raw.count) バイト>"
      XCTFail("応答が JSON オブジェクトでない: \(shown)", file: file, line: line)
      return nil
    }
    return obj
  }

  /// 直前までに送った行をサーバが処理し終えたことを確定させる。即応答する要求を 1 つ挟んで
  /// その応答を読み捨てる——同一接続の行は受信順に処理されるため、これが返った時点で前の行
  /// （`wait_for_event` の登録・無応答メソッド・空行）は処理済みになっている。
  ///
  /// 「応答が出ないこと」の実証もこれで行う。実時間を待って何も来ないことを確かめる形にすると、
  /// 遅れて届いただけの応答を「無応答」と誤判定するか、待ち時間ぶん flaky になるかのどちらかになる。
  @discardableResult func barrier(file: StaticString = #filePath, line: UInt = #line) -> [String:
    Any]?
  {
    barrierSeq += 1
    let id = "barrier-\(barrierSeq)"
    send(["jsonrpc": "2.0", "id": id, "method": "list_workspaces"], file: file, line: line)
    let response = nextResponse(file: file, line: line)
    XCTAssertEqual(
      response?["id"] as? String, id,
      "barrier より先に別の応答が届いた＝直前の行が応答を出している", file: file, line: line)
    return response
  }

  /// サーバが接続を畳んだ（read が EOF を返した）ことを待つ。
  func waitForDisconnect(file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(Self.deadlineSeconds)
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(clientFD, &buf, buf.count)
      if n > 0 { continue }  // 切断前に残っていた応答は読み飛ばす
      if n == 0 { return }  // EOF＝サーバが畳んだ
      if errno == EINTR { continue }
      guard errno == EAGAIN || errno == EWOULDBLOCK else { return }  // 相手が落ちた扱い
      guard Date() < deadline else {
        XCTFail("接続が切れない（上限超過で切断する契約が働いていない）", file: file, line: line)
        return
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(Self.stepSeconds))
    }
  }

  /// `nextLine` の帰結。EOF と締切超過を分ける——どちらも「応答が読めない」に見えるが、原因の
  /// 向きが逆で、前者は接続が畳まれた（overflow 判定や write エラー経路の回帰）、後者は応答が
  /// そもそも書かれていない。同じ文言で報告すると調査が反対側へ誘導される。
  private enum LineOutcome {
    case line(Data)
    case eof
    case timedOut
  }

  /// 改行までを 1 行として取り出す。EAGAIN のあいだは runloop を回し、control queue と
  /// `handle` の main hop の両方を進ませる（テスト本体は main に留まる）。
  private func nextLine() -> LineOutcome {
    let deadline = Date().addingTimeInterval(Self.deadlineSeconds)
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      if let nl = pending.firstIndex(of: 0x0A) {
        let line = Data(pending[pending.startIndex..<nl])
        pending.removeSubrange(pending.startIndex...nl)
        return .line(line)
      }
      let n = read(clientFD, &buf, buf.count)
      if n > 0 {
        pending.append(contentsOf: buf[0..<n])
        continue
      }
      if n == 0 { return .eof }
      if errno == EINTR { continue }
      guard errno == EAGAIN || errno == EWOULDBLOCK else { return .eof }  // 相手が落ちた扱い
      guard Date() < deadline else { return .timedOut }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(Self.stepSeconds))
    }
  }
}

/// `ControlTarget` の Fake。受け取った引数を記録し、ドメインは一切実行しない。
///
/// 記録するのは `ControlServer` が params から取り出して**渡した値**なので、`-32602` ガードの
/// 無い optional param（`messageSource` 等）の到達もここでしか観測できない。
///
/// 宛先解決に使う `pane` は実 `SurfaceView` だが、window に載せないので libghostty surface は
/// 生まれない（surface を作るのは `viewDidMoveToWindow`）。制御系のメソッドは surface 不在で
/// no-op / nil を返すため、L3 は L2 の重さを背負わずに宛先解決の経路だけを通せる。
final class FakeControlTarget: ControlTarget {
  // MARK: - 返り値（テストが決める）

  var workspaces: [[String: Any]] = []
  var panes: [[String: Any]] = []
  var agents: [[String: Any]] = []
  /// nil にすると `spawn` が `-32000`（spawn failed）になる。
  var spawnedPaneId: Int? = 4242
  /// nil にすると `activate_workspace` が `-32004` になる。
  var activateResult: (activeWorkspaceId: Int, paneIds: [Int])? = (
    activeWorkspaceId: 1, paneIds: []
  )
  /// 立てると `Result` を返す全メソッド（ペイン/タブ操作・config・workspace CRUD）が
  /// これを `.failure` で返す。ドメインが決めるコード（tab 未発見の `-32004`・最後の
  /// workspace 削除の `-32000` 等）は `ControlServer` が生まず target から素通しするため、
  /// wire 側でその素通しを見るにはここを差し替えるしかない。
  var domainFailure: ControlError?

  /// 記録は常に行い、`domainFailure` が立っていればそれを、無ければ success を返す。
  private func outcome(_ value: Any) -> Result<Any, ControlError> {
    if let failure = domainFailure { return .failure(failure) }
    return .success(value)
  }

  // MARK: - 記録

  struct ReportedAgent {
    let paneId: Int
    let agent: String
    let state: String
    let sessionId: String?
    let messageText: String?
    let messageSource: String?
  }
  struct Spawn {
    let workspaceId: Int?
    let cwd: String?
    let command: String?
  }
  struct Split {
    let paneId: Int
    let direction: String
    let command: String?
  }
  struct ConfigSet {
    let key: String
    let value: Any
    let scope: String
    let workspaceId: Int?
  }
  struct CreatedWorkspace {
    let name: String
    let rootPath: String?
  }
  struct RenamedWorkspace {
    let workspaceId: Int
    let name: String
  }
  struct WorkspaceRoot {
    let workspaceId: Int
    let rootPath: String
  }

  private(set) var reportedAgents: [ReportedAgent] = []
  private(set) var spawns: [Spawn] = []
  private(set) var splits: [Split] = []
  private(set) var configSets: [ConfigSet] = []
  private(set) var configLists: [Int?] = []
  private(set) var createdWorkspaces: [CreatedWorkspace] = []
  private(set) var renamedWorkspaces: [RenamedWorkspace] = []
  private(set) var workspaceRoots: [WorkspaceRoot] = []
  private(set) var removedWorkspaceIds: [Int] = []
  private(set) var activatedWorkspaceIds: [Int] = []
  private(set) var closedPaneIds: [Int] = []
  private(set) var focusedPaneIds: [Int] = []
  private(set) var closedTabIds: [Int] = []
  private(set) var resolvedPaneIds: [Int] = []

  // MARK: - 宛先

  /// 解決可能な唯一のペイン。id は `IdGen` のプロセス単調増加なので、テストは必ずここから読む。
  let pane = SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  var paneId: Int { pane.id }

  func controlResolvePane(_ id: Int) -> SurfaceView? {
    resolvedPaneIds.append(id)
    return id == pane.id ? pane : nil
  }

  // MARK: - ControlTarget

  func controlListWorkspaces() -> [[String: Any]] { workspaces }
  func controlListPanes() -> [[String: Any]] { panes }
  func controlListAgents() -> [[String: Any]] { agents }

  func controlSpawn(workspaceId: Int?, cwd: String?, command: String?) -> Int? {
    spawns.append(Spawn(workspaceId: workspaceId, cwd: cwd, command: command))
    return spawnedPaneId
  }

  func controlActivateWorkspace(workspaceId: Int) -> (activeWorkspaceId: Int, paneIds: [Int])? {
    activatedWorkspaceIds.append(workspaceId)
    return activateResult
  }

  func controlReportAgent(
    pane: SurfaceView, agent: String, state: String, sessionId: String?, message: AgentMessage?
  ) {
    reportedAgents.append(
      ReportedAgent(
        paneId: pane.id, agent: agent, state: state, sessionId: sessionId,
        messageText: message?.text, messageSource: message?.source))
  }

  func controlSplitPane(paneId: Int, direction: String, command: String?)
    -> Result<Any, ControlError>
  {
    splits.append(Split(paneId: paneId, direction: direction, command: command))
    return outcome(["paneId": 5151])
  }

  func controlClosePane(paneId: Int) -> Result<Any, ControlError> {
    closedPaneIds.append(paneId)
    return outcome(["ok": true])
  }

  func controlFocusPane(paneId: Int) -> Result<Any, ControlError> {
    focusedPaneIds.append(paneId)
    return outcome(["ok": true])
  }

  func controlCloseTab(tabId: Int) -> Result<Any, ControlError> {
    closedTabIds.append(tabId)
    return outcome(["ok": true])
  }

  func controlConfigList(workspaceId: Int?) -> Result<Any, ControlError> {
    configLists.append(workspaceId)
    return outcome(["settings": []])
  }

  func controlConfigSet(key: String, value: Any, scope: String, workspaceId: Int?)
    -> Result<Any, ControlError>
  {
    configSets.append(ConfigSet(key: key, value: value, scope: scope, workspaceId: workspaceId))
    return outcome(["ok": true, "key": key, "value": value, "scope": scope])
  }

  func controlCreateWorkspace(name: String, rootPath: String?) -> Result<Any, ControlError> {
    createdWorkspaces.append(CreatedWorkspace(name: name, rootPath: rootPath))
    return outcome(["workspaceId": 7, "name": name, "rootPath": rootPath ?? "/tmp"])
  }

  func controlRenameWorkspace(workspaceId: Int, name: String) -> Result<Any, ControlError> {
    renamedWorkspaces.append(RenamedWorkspace(workspaceId: workspaceId, name: name))
    return outcome(["ok": true])
  }

  func controlSetWorkspaceRoot(workspaceId: Int, rootPath: String) -> Result<Any, ControlError> {
    workspaceRoots.append(WorkspaceRoot(workspaceId: workspaceId, rootPath: rootPath))
    return outcome(["ok": true])
  }

  func controlRemoveWorkspace(workspaceId: Int) -> Result<Any, ControlError> {
    removedWorkspaceIds.append(workspaceId)
    return outcome(["ok": true])
  }
}
