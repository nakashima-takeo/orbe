import Foundation

/// `.app` 同梱の状態追跡プラグインを、検出された各 CLI へ
/// 同梱の `install.sh` 経由で導入する。導入機構は各 CLI のプラグイン機構に委ね、ユーザー設定
/// ファイルは直接書き換えない。`install.sh` が CLI ごとに出す 1 行を Event として流す。
enum AgentPluginInstaller {
  /// install.sh の 1 行イベント（CLI 名つき）。
  enum Event {
    case start(String)  // 導入開始
    case done(String, ok: Bool)  // installed/unchanged=ok・error=失敗
    case skip(String)  // skip-no-cli（未検出）
  }

  /// 同梱プラグインのディレクトリ（`<bundle>/Contents/Resources/agent-plugin`）。
  /// `swift run`（バンドル無し）では nil。同梱が在るかのゲート判定に使う。
  static var bundledPluginDir: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let dir = resources.appendingPathComponent("agent-plugin", isDirectory: true)
    let script = dir.appendingPathComponent("install.sh")
    return FileManager.default.isExecutableFile(atPath: script.path) ? dir : nil
  }

  /// marketplace へ登録する安定パス（`ORBE_STATE_DIR` 非依存の application support 直下）。
  /// ビルド固有 ephemeral パスを焼き付けないための固定登録先。
  static var stablePluginDir: URL? {
    StateDir.appSupport()?.appendingPathComponent("agent-plugin", isDirectory: true)
  }

  /// 同梱プラグインを安定パスへ実体化（コピー）し、その安定パスを返す。失敗時は nil。
  /// 一時ディレクトリへコピーしてから原子的に差し替える: コピー途中で失敗しても既存の
  /// 安定コピー（marketplace 登録先）を消さないため、止血時の再実行で dangling を作らない。
  /// 冪等で古いファイルの残置も無い。`copyItem`/`replaceItemAt` は POSIX permission を
  /// 保持するため install.sh / hooks の +x も残る。
  static func materializeStablePlugin() -> URL? {
    guard let src = bundledPluginDir, let dst = stablePluginDir else { return nil }
    let fm = FileManager.default
    let tmp = dst.deletingLastPathComponent()
      .appendingPathComponent("agent-plugin.tmp-\(UUID().uuidString)", isDirectory: true)
    do {
      try fm.copyItem(at: src, to: tmp)
      if fm.fileExists(atPath: dst.path) {
        _ = try fm.replaceItemAt(dst, withItemAt: tmp)
      } else {
        try fm.moveItem(at: tmp, to: dst)
      }
      return dst
    } catch {
      try? fm.removeItem(at: tmp)
      return nil
    }
  }

  /// 同梱 `install.sh <pluginDir>` をバックグラウンド実行し、stdout の各行を Event として
  /// メインスレッドで `onEvent` に、終了を `onComplete` に流す。子プロセスは呼び出し側が
  /// 戻り値で保持する（実行中の Process 寿命を UI に紐付ける）。
  @discardableResult
  static func run(
    pluginDir: URL, shellPATH: String?,
    onEvent: @escaping (Event) -> Void, onComplete: @escaping () -> Void
  ) -> Process {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [pluginDir.appendingPathComponent("install.sh").path, pluginDir.path]
    var env = ProcessInfo.processInfo.environment
    if let shellPATH { env["PATH"] = shellPATH }
    proc.environment = env
    proc.standardInput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    proc.standardOutput = pipe

    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      buffer.append(handle.availableData)
      while let nl = buffer.firstIndex(of: 0x0a) {
        let lineData = buffer[buffer.startIndex..<nl]
        buffer.removeSubrange(buffer.startIndex...nl)
        if let line = String(bytes: lineData, encoding: .utf8), let event = parse(line) {
          DispatchQueue.main.async { onEvent(event) }
        }
      }
    }
    proc.terminationHandler = { proc in
      pipe.fileHandleForReading.readabilityHandler = nil
      proc.terminationHandler = nil
      DispatchQueue.main.async { onComplete() }
    }
    do { try proc.run() } catch { DispatchQueue.main.async { onComplete() } }
    return proc
  }

  private static func parse(_ line: String) -> Event? {
    let parts = line.split(separator: " ")
    guard parts.count == 2 else { return nil }
    let cli = String(parts[1])
    switch parts[0] {
    case "start": return .start(cli)
    case "installed", "unchanged": return .done(cli, ok: true)
    case "error": return .done(cli, ok: false)
    case "skip-no-cli": return .skip(cli)
    default: return nil
    }
  }
}
