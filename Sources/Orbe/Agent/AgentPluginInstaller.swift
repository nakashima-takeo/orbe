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

  /// パッケージのプラグイン名（＝marketplace 名＝`plugins/` 直下の唯一のサブディレクトリ名）。
  /// 名前はビルド時にチャネルから導出されるため Swift には焼かず、パッケージ自身から読む。
  /// サブディレクトリが 1 つでなければ nil（壊れたパッケージで誤った名前を登録しない）。
  static func pluginName(in packageDir: URL) -> String? {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: packageDir.appendingPathComponent("plugins", isDirectory: true),
        includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles),
      entries.count == 1,
      (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { return nil }
    return entries[0].lastPathComponent
  }

  /// 同梱プラグインを安定パスへ実体化（コピー）し、その安定パスを返す。失敗時は nil。
  /// claude は登録した安定パスをライブ参照するため、これが `.app` 同梱の更新を届ける経路になる
  /// （起動ごとに呼ぶ）。codex / agy は導入時にコピーを取るので、更新が届くのは次に登録し直した
  /// ときで、そのときのコピー元が最新であることをこの実体化が保証する。
  /// 一時ディレクトリへコピーしてから原子的に差し替える: コピー途中で失敗しても
  /// 既存の安定コピー（marketplace 登録先）を消さないため、止血時の再実行で dangling を作らない。
  /// 冪等で古いファイルの残置も無い。`copyItem`/`replaceItemAt` は POSIX permission を
  /// 保持するため install.sh / hooks の +x も残る。
  static func materializeStablePlugin() -> URL? {
    guard let src = bundledPluginDir, let dst = stablePluginDir else { return nil }
    let fm = FileManager.default
    let tmp = dst.deletingLastPathComponent()
      .appendingPathComponent("agent-plugin.tmp-\(UUID().uuidString)", isDirectory: true)
    do {
      try fm.copyItem(at: src, to: tmp)
      // 自分のチャネル（bundle ID）をシムの隣へ刻む。シムがこれとペインの ORBE_BUNDLE_ID を
      // 突き合わせ、他チャネルの Orbe から来た呼び出しを落とす。差し替えの前に書くので、
      // 実体化先が channel を持たない瞬間は生じない。
      guard let name = pluginName(in: tmp) else {
        try? fm.removeItem(at: tmp)
        return nil
      }
      try Data("\(StateDir.bundleId)\n".utf8).write(
        to: tmp.appendingPathComponent("plugins/\(name)/hooks/channel"))
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

  /// 同梱 `install.sh <pluginDir> <pluginName>` をバックグラウンド実行し、stdout の各行を Event として
  /// メインスレッドで `onEvent` に、読み切りを `onComplete` に流す。子プロセスは呼び出し側が
  /// 戻り値で保持する（実行中の Process 寿命を UI に紐付ける）。
  ///
  /// 完了は stdout の EOF で発火する: 全行を読み切ってから同じ読み取りキューで `onComplete` を
  /// main へ投入するので、`onComplete` は必ず最後の `onEvent` の後に届く。呼び出し側はこの順序に
  /// 依って完了時点で失敗の有無を判定する（`AgentLauncher` は 1 つでも失敗すれば名前を記録しない）。
  @discardableResult
  static func run(
    pluginDir: URL, pluginName: String, shellPATH: String?,
    onEvent: @escaping (Event) -> Void, onComplete: @escaping () -> Void
  ) -> Process {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [
      pluginDir.appendingPathComponent("install.sh").path, pluginDir.path, pluginName,
    ]
    var env = ProcessInfo.processInfo.environment
    if let shellPATH { env["PATH"] = shellPATH }
    proc.environment = env
    proc.standardInput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    proc.standardOutput = pipe

    let emit: (Data) -> Void = { lineData in
      guard let line = String(bytes: lineData, encoding: .utf8), let event = parse(line) else {
        return
      }
      DispatchQueue.main.async { onEvent(event) }
    }
    var buffer = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {  // EOF: 書き手が全て閉じた＝これ以上 1 行も来ない
        handle.readabilityHandler = nil
        emit(buffer)  // 改行で終わらない最後の 1 行
        DispatchQueue.main.async { onComplete() }
        return
      }
      buffer.append(chunk)
      while let nl = buffer.firstIndex(of: 0x0a) {
        emit(buffer[buffer.startIndex..<nl])
        buffer.removeSubrange(buffer.startIndex...nl)
      }
    }
    do { try proc.run() } catch {
      pipe.fileHandleForReading.readabilityHandler = nil  // 起動できなければ EOF も来ない
      DispatchQueue.main.async { onComplete() }
    }
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
