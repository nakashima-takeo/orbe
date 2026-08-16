import AppKit
import Darwin
import Foundation
import OrbePaths
import XCTest

@testable import Orbe

/// L4（プロセス境界）の駆動台。テストクラスではない支援ファイルで、L3 の `ControlWireHarness` と
/// 同じ位置づけ。テストプロセス内に実 `WindowController` を target とした `ControlServer` を立て、
/// 外部プロセスとしてビルド済みの `orb` / `orbe-mcp` / `orbe-report` を起こす。
///
/// **main runloop を止めずに待つ**のがこの台の存在理由。`ControlServer` は domain 操作を
/// `DispatchQueue.main.async` へ hop するため、テストが `Process.waitUntilExit()` で main を塞ぐと、
/// 子プロセスがサーバの応答を待ち・サーバが main を待つ相互デッドロックになる。`run` は終了を
/// runloop を回しながら待つ。テスト本体で生 `Process` を組まないこと。
///
/// **子プロセスの env は明示辞書のみ**（親から継承しない）。`swift test` を Orbe のペインから走らせると
/// 親に開発者の実 `ORBE_SOCK` / `ORBE_PANE` / `ORBE_REPORT_BIN` が居る。`orbe-report` は `ORBE_SOCK` を
/// 直読みする（`ORBE_STATE_DIR` を見ない）ので、継承すると**テストが開発者の実 Orbe へ状態報告を飛ばす**。
///
/// これが壊れると、実行体をまたいだ導通——引数解釈・終了コード・stdout・組み立てる JSON-RPC・
/// hook 実経路・bare `orb` の PATH 解決——を測る唯一の経路が消える。
final class ControlProcess {
  /// 子プロセスの終了を待つ上限。**実時間の検証ではない**——進まなくなったら諦めるための上限。
  static let processTimeout: TimeInterval = 20
  /// 実ペインへ送った入力が画面へ反映されるまでの上限。ペインの spawn ＋ ログインシェルの起動 ＋
  /// 描画までを含むので `processTimeout` と別に持つ。これも実時間の検証ではない。
  static let paneSettleTimeout: TimeInterval = 15
  /// runloop を 1 回まわす刻み。control queue と main hop の両方をここで進ませる。
  private static let stepSeconds: TimeInterval = 0.01

  // MARK: - ビルド済み実行体の解決

  /// L4 が使うバイナリ位置の解決規則: xctest バンドルの親ディレクトリ。
  /// 「隣に在る」ことは `BuiltExecutablesTests` が先に固定し、L4 の全テストはここを通して同じ出所を引く
  /// （規則を二重管理しない）。
  static var builtProductsDirectory: URL {
    Bundle(for: ControlProcess.self).bundleURL.deletingLastPathComponent()
  }

  static func executable(_ name: String) -> URL {
    builtProductsDirectory.appendingPathComponent(name, isDirectory: false)
  }

  // MARK: - 同梱物のステージング

  /// `.app` 同梱物のレイアウトを `BundledResources.root`（＝ハーネスが配る `caseDir/resources/`）へ組む。
  ///
  /// **`WindowController()` より前に呼ぶ**——`injectRuntimeEnv` はペイン生成の時点で
  /// `reportBinaryPath` / `bundledBinDir` を読むため、後から置いてもペインに注入済みの env には効かない。
  /// 置くのは `bin/` だけで、`completion-engine.js` も `zsh/` も置かない（不在時の graceful degradation を
  /// 測る既存テストの前提を壊さない）。root は caseDir 配下なので、組んだ中身は `endCase` の削除に乗る。
  @discardableResult
  static func stageBundle() throws -> URL {
    let resources = try XCTUnwrap(BundledResources.root, "同梱リソースの探索根が張られていない")
    let bin = resources.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    // `.app` 同梱時の改名（orbe-cli → orb）をここでも再現する。bare `orb` の PATH 解決はこの名前に依る。
    try stage(executable("orbe-cli"), as: bin.appendingPathComponent("orb"))
    try stage(executable("orbe-report"), as: bin.appendingPathComponent("orbe-report"))
    return resources
  }

  private static func stage(_ source: URL, as destination: URL) throws {
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
  }

  // MARK: - サーバ

  /// `ControlServer.shared.target` は weak なので、実 `WindowController` の寿命はここが持つ。
  let target: WindowController

  /// `ControlServer.shared` を実 `WindowController` へ載せ、隔離根の socket で待ち受ける。
  init(target: WindowController, file: StaticString = #filePath, line: UInt = #line) {
    self.target = target
    let expected = TestIsolation.root.appendingPathComponent("control.sock").path
    // 空や別値だと `start` が no-op になり、子プロセス側は "Orbe not running" と区別できず緑に化ける。
    XCTAssertEqual(
      ControlServer.shared.socketPath, expected,
      "制御 socket が隔離根を指していない（隔離前に ControlServer が構築された）", file: file, line: line)
    ControlServer.shared.start(target: target)
    XCTAssertTrue(
      Self.waitUntil(5) { FileManager.default.fileExists(atPath: expected) },
      "control.sock が bind されない（bind 失敗は無言なので待ってから測る）", file: file, line: line)
  }

  /// `start` と必ず対にする。`openSocket()` は再入すると listenFD を漏らし `acceptSource` を
  /// cancel せず差し替えるため、テストごとに畳んでおく。
  func teardown() {
    ControlServer.shared.stop()
  }

  // MARK: - 子プロセス

  struct Outcome {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  /// 子プロセスへ渡す env。**明示辞書のみ**（親から継承しない）。
  static func childEnv(_ extra: [String: String] = [:]) -> [String: String] {
    var env = ["PATH": "/usr/bin:/bin", OrbePaths.stateDirEnvVar: TestIsolation.root.path]
    for (key, value) in extra { env[key] = value }
    return env
  }

  /// 子プロセスを起こして終了・出力を回収する。main を塞がずに待つのがこの関数の要点。
  static func run(
    _ executable: URL, _ args: [String], env: [String: String], stdin: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Outcome {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    process.environment = env
    let out = Pipe()
    let err = Pipe()
    let input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input

    // パイプが充填されると子が write で詰まるため、読み切りは背景で走らせる。
    var outData = Data()
    var errData = Data()
    let reads = DispatchGroup()
    reads.enter()
    DispatchQueue.global().async {
      outData = out.fileHandleForReading.readDataToEndOfFile()
      reads.leave()
    }
    reads.enter()
    DispatchQueue.global().async {
      errData = err.fileHandleForReading.readDataToEndOfFile()
      reads.leave()
    }
    var exited = false
    process.terminationHandler = { _ in DispatchQueue.main.async { exited = true } }

    // stdin は起動前に書く（読み手の居ないパイプへ書くと SIGPIPE で xctest ごと落ちる）。
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
    do {
      try process.run()
    } catch {
      XCTFail("\(executable.lastPathComponent) を起動できない: \(error)", file: file, line: line)
      return Outcome(status: -1, stdout: "", stderr: "")
    }
    if stdin != nil { try? input.fileHandleForWriting.close() }

    var readsDone = false
    reads.notify(queue: .main) { readsDone = true }
    if !waitUntil(processTimeout, { exited && readsDone }) {
      XCTFail(
        "\(executable.lastPathComponent) が \(processTimeout) 秒で終わらない"
          + "（main を塞ぐ待ち方をすると制御サーバの main hop が捌かれず相互デッドロックする）",
        file: file, line: line)
      process.terminate()
      // `readsDone` まで待つ。`outData` / `errData` は背景の 2 スレッドが書いている最中なので、
      // `exited` だけで先へ進むと診断に載せる stdout / stderr を競合したまま読むことになる。
      _ = waitUntil(3) { exited && readsDone }
    }
    return Outcome(
      status: exited ? process.terminationStatus : -1,
      stdout: readsDone ? Self.text(outData) : "<読み取り未完>",
      stderr: readsDone ? Self.text(errData) : "<読み取り未完>")
  }

  /// 出力を文字列へ。非 UTF-8 は握り潰さず、そうと分かる形で残す（空文字と区別できるようにする）。
  private static func text(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? "<非 UTF-8 \(data.count) バイト>"
  }

  /// runloop を回しながら条件成立を待つ。`Process.waitUntilExit()` の代わりに必ずこれを通す。
  @discardableResult
  static func waitUntil(_ seconds: TimeInterval, _ body: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
      if body() { return true }
      guard Date() < deadline else { return false }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(stepSeconds))
    }
  }

  // MARK: - orb（orbe-cli）

  /// サーバを張らずに `orb` を起こす。socket に触れる前に弾かれる usage エラーと、socket 不達の
  /// 経路はこちらで測る（実 `WindowController` を立てる必要が無い）。
  ///
  /// 渡す `ORBE_STATE_DIR` は `orb` を持つ側と同じ隔離根なので、**同じテストが先に
  /// `startControlProcess()` を呼んでいると socket は生きている**。その状態で呼ぶと「socket に
  /// 触れる前に落ちた」ではなく「触れて弾かれた」を測ることになり、terminal な usage エラーは
  /// どちらでも exit 2 なので終了コードの assert が判別力を失う（＝門番を外しても緑のまま通る）。
  /// 名前が嘘になる呼び方をここで落とす。
  static func orbWithoutServer(
    _ args: [String], env extra: [String: String] = [:],
    file: StaticString = #filePath, line: UInt = #line
  ) -> Outcome {
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: TestIsolation.root.appendingPathComponent("control.sock").path),
      "サーバが生きている状態で orbWithoutServer を呼んでいる（socket 前に落ちたことを測れない）",
      file: file, line: line)
    return run(executable("orbe-cli"), args, env: childEnv(extra), file: file, line: line)
  }

  /// 同梱名の `orb`（実体は `orbe-cli`）を隔離インスタンスへ向けて起こす。
  /// `stdin` を渡すと起動前に書いて閉じる（`orb pane send --stdin`）。渡さなければ子の標準入力は
  /// `/dev/null`——`--stdin` 無しの経路が標準入力に触れたら即 EOF になり、ハングせずに落ちる。
  /// 起動**前**に書くので読み手はまだ居ない。pipe 容量（macOS で約 64KB）を超える `stdin` は
  /// そこで詰まり、`processTimeout` にも到達しないまま固まる——渡すのは小さな入力だけにすること。
  @discardableResult
  func orb(
    _ args: [String], env extra: [String: String] = [:], stdin: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) -> Outcome {
    Self.run(
      Self.executable("orbe-cli"), args, env: Self.childEnv(extra), stdin: stdin, file: file,
      line: line)
  }

  /// `orb <args> --json` の stdout を JSON オブジェクトとして読む。workspace / pane の id は
  /// `IdGen` 採番で予測不能なので、テストは必ずこの出力から読む（直書きしない）。
  func orbJSON(
    _ args: [String], env extra: [String: String] = [:],
    file: StaticString = #filePath, line: UInt = #line
  ) -> [String: Any] {
    let outcome = orb(args + ["--json"], env: extra, file: file, line: line)
    XCTAssertEqual(
      outcome.status, 0, "orb \(args.joined(separator: " ")) --json が失敗した: \(outcome.stderr)",
      file: file, line: line)
    guard let data = outcome.stdout.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      XCTFail(
        "orb \(args.joined(separator: " ")) --json の stdout が JSON オブジェクトでない: "
          + outcome.stdout, file: file, line: line)
      return [:]
    }
    return obj
  }

  // MARK: - orbe-mcp

  /// `orbe-mcp` を 1 往復させる（`tools/call` 1 行を stdin へ流し `result.content[0].text` を読む）。
  /// MCP ブリッジの転送と `isError` の畳み込みも同時に踏む。
  func mcpCall(
    _ tool: String, _ arguments: [String: Any] = [:],
    file: StaticString = #filePath, line: UInt = #line
  ) -> (text: String, isError: Bool) {
    let request: [String: Any] = [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": ["name": tool, "arguments": arguments],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: request),
      let requestLine = String(data: data, encoding: .utf8)
    else {
      XCTFail("tools/call を JSON へ直列化できない: \(tool)", file: file, line: line)
      return ("", true)
    }
    let outcome = Self.run(
      Self.executable("orbe-mcp"), [], env: Self.childEnv(), stdin: requestLine + "\n",
      file: file, line: line)
    guard let out = outcome.stdout.split(separator: "\n").first,
      let payload = out.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let result = obj["result"] as? [String: Any],
      let content = result["content"] as? [[String: Any]],
      let text = content.first?["text"] as? String
    else {
      XCTFail(
        "orbe-mcp の tools/call 応答が読めない（\(tool)）: \(outcome.stdout)\(outcome.stderr)",
        file: file, line: line)
      return ("", true)
    }
    return (text, result["isError"] as? Bool ?? false)
  }

  /// `mcpCall` の本文を JSON オブジェクトとして読む（成功系の read ツール用）。
  func mcpJSON(
    _ tool: String, _ arguments: [String: Any] = [:],
    file: StaticString = #filePath, line: UInt = #line
  ) -> [String: Any] {
    let call = mcpCall(tool, arguments, file: file, line: line)
    XCTAssertFalse(call.isError, "\(tool) が error を返した: \(call.text)", file: file, line: line)
    guard let data = call.text.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      XCTFail("\(tool) の本文が JSON オブジェクトでない: \(call.text)", file: file, line: line)
      return [:]
    }
    return obj
  }
}

/// L4 の arrange。同梱物を組み → fixture を書き → 実 `WindowController` を起こし → サーバを張る、
/// までを 1 手で行う（順序を各テストの申告制にしない）。
extension OrbeTestCase {
  /// 既定の fixture は「アクティブ WS ＋ 背景 WS」。背景 WS を必ず作るので、`activate_workspace` の
  /// 検証が「背景 WS が無いから省略」に化けない。
  func startControlProcess(
    workspaces names: [String] = ["main", "background"],
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> ControlProcess {
    try ControlProcess.stageBundle()
    let fixture = WorkspacesFile(
      version: WorkspacePersistence.version, activeWorkspace: 0,
      workspaces: names.map {
        WorkspaceState(
          name: $0, rootPath: "/tmp", activeTab: 0,
          tabs: [TabState(tree: .leaf(cwd: nil, agent: nil), explicitTitle: nil)])
      })
    try JSONEncoder().encode(fixture).write(to: workspacesFile())
    let control = ControlProcess(target: WindowController())
    addTeardownBlock { control.teardown() }
    return control
  }

  /// runloop を回しながら条件成立を待つ（ポーリング）。
  @discardableResult
  func waitUntil(_ seconds: TimeInterval = 5, _ body: () -> Bool) -> Bool {
    ControlProcess.waitUntil(seconds, body)
  }
}
