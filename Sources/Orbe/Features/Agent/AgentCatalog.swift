import Foundation

/// 検出されたエージェント CLI。path は解決済み絶対パス（起動にもこれを使う）。
struct AgentCLI: Equatable {
  let command: String
  let path: String
}

/// インストール済みエージェント CLI（claude / codex / agy）の検出。
/// ユーザーのデフォルトシェルを login + interactive で起こして PATH を取得し、
/// その PATH 上で実行ファイルを解決する（「ユーザーのシェルが見つけるもの＝候補」の契約。
/// GUI アプリの素の PATH に依存しない）。
final class AgentCatalog {
  /// 一級サポートのセット。並び＝デフォルト未設定時の優先順。
  static let supported = ["claude", "codex", "agy"]

  private(set) var agents: [AgentCLI] = []
  /// 検出に使ったログインシェルの PATH（エージェントタブの環境へ引き継ぐ）。
  private(set) var shellPATH: String?
  /// 一度でも検出を完了したか（detecting を解く判断に使う）。
  private(set) var hasResolved = false
  /// 検出結果が変わった通知（メインスレッドで呼ぶ）。
  var onChange: (() -> Void)?
  /// 検出完了通知（成功・失敗どちらでも refresh ごとに必ず一度呼ぶ。メインスレッドで呼ぶ）。
  var onResolved: (() -> Void)?
  private var refreshing = false

  /// 裏で再検出する。実行中なら何もしない（パレット開閉の連打でシェルを積み上げない）。
  func refresh() {
    guard !refreshing else { return }
    refreshing = true
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // シェル起動の失敗は「検出ゼロ」と区別し、既知の検出結果を保持する（path=nil）。
      let path = Self.loginShellPATH()
      let found = path.map { Self.resolve(in: $0) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.refreshing = false
        // 成功時のみ結果を更新（変化があれば onChange）。失敗時は既知結果を保持。
        if let path, let found {
          self.shellPATH = path
          Self.cacheShellPATH(path)  // 次回起動の同期復元経路へ温存（subprocess を避ける）
          if self.agents != found {
            self.agents = found
            self.onChange?()
          }
        }
        // 完了は成功・失敗を問わず必ず一度シグナルする（detecting が固まらない）。
        self.hasResolved = true
        self.onResolved?()
      }
    }
  }

  /// resume 用に PATH を同期取得する（startup 復元では非同期検出が未完了なため）。
  /// メモリ→ディスクキャッシュ（sub-ms）→（無ければ一度だけ）同期 subprocess の順。
  /// 起動クリティカルパスを subprocess で塞がないため、温まったキャッシュで同期完結する。
  func ensureShellPATH() -> String? {
    if let path = shellPATH { return path }
    if let cached = AppStatePersistence.load()?.cachedShellPath {
      shellPATH = cached
      return cached
    }
    // キャッシュも無い稀ケース（app-state.json 削除等）のみ同期 subprocess。以後キャッシュで吸収。
    let path = Self.loginShellPATH()
    shellPATH = path
    if let path { Self.cacheShellPATH(path) }
    return path
  }

  /// ログインシェル PATH を app-state.json へ温存する（変化時のみ書く）。メインスレッドで呼ぶ。
  private static func cacheShellPATH(_ path: String) {
    guard AppStatePersistence.load()?.cachedShellPath != path else { return }
    AppStatePersistence.update { $0.cachedShellPath = path }
  }

  /// 各 CLI の resume コマンド文字列（`/bin/sh -c` 経由で実行される前提）。
  /// 未対応 agent・安全な文字集合（UUID 等）外の sessionId は nil（呼び出し側が素のシェルへ fallback）。
  /// command は switch のリテラルでのみ一致し、sessionId は文字集合検証するため shell インジェクションを防ぐ。
  static func resumeCommand(forAgent command: String, sessionId: String) -> String? {
    guard !sessionId.isEmpty,
      sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
    else { return nil }
    switch command {
    case "claude": return "\(command) --resume \(sessionId)"
    case "agy": return "\(command) --conversation \(sessionId)"
    case "codex": return "\(command) resume \(sessionId)"
    default: return nil
    }
  }

  /// PATH 文字列から supported の実行ファイルを解決する（検出の純粋部分）。
  static func resolve(in path: String, fileManager: FileManager = .default) -> [AgentCLI] {
    let dirs = path.split(separator: ":").map(String.init)
    return supported.compactMap { command in
      for dir in dirs where !dir.isEmpty {
        let candidate = dir.hasSuffix("/") ? dir + command : dir + "/" + command
        if fileManager.isExecutableFile(atPath: candidate) {
          return AgentCLI(command: command, path: candidate)
        }
      }
      return nil
    }
  }

  /// ユーザーのデフォルトシェルを login + interactive で起こし、/usr/bin/env の出力から
  /// PATH を抜く（rc の echo ノイズと混ざっても最後の PATH= 行を取る。シェル方言に依存しない）。
  /// rc が入力待ちで固まる事故に備えて 10 秒で打ち切る。
  private static func loginShellPATH() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-l", "-i", "-c", "/usr/bin/env"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardInput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak proc] in
      if proc?.isRunning == true { proc?.terminate() }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let out = String(data: data, encoding: .utf8) else { return nil }
    let paths = out.split(separator: "\n").filter { $0.hasPrefix("PATH=") }
    return paths.last.map { String($0.dropFirst("PATH=".count)) }
  }
}
