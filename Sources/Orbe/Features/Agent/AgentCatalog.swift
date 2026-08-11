import Foundation

/// 検出されたエージェント CLI。path は解決済み絶対パス（起動にもこれを使う）。
struct AgentCLI: Equatable {
  let command: String
  let path: String
}

/// インストール済みエージェント CLI（claude / codex / agy）の検出。
/// `ShellPATH` が解決した PATH 上で実行ファイルを絶対パスへ解決する
/// （「ユーザーのシェルが見つけるもの＝候補」の契約。GUI アプリの素の PATH に依存しない）。
final class AgentCatalog {
  /// 一級サポートのセット。並び＝デフォルト未設定時の優先順。
  static let supported = ["claude", "codex", "agy"]

  private(set) var agents: [AgentCLI] = []
  /// 一度でも検出を完了したか（detecting を解く判断に使う）。
  private(set) var hasResolved = false
  /// 検出結果が変わった通知（メインスレッドで呼ぶ）。
  var onChange: (() -> Void)?
  /// 検出完了通知（refresh ごとに必ず一度呼ぶ。メインスレッドで呼ぶ）。
  var onResolved: (() -> Void)?
  private var refreshing = false

  /// 裏で再検出する。実行中なら何もしない（パレット開閉の連打で走査を積み上げない）。
  /// 走査するのはファイルシステムだけ——PATH はプロセスの事実なので取り直さない
  /// （`brew install` で変わるのは PATH ではなく、その PATH 上に現れるファイル）。
  func refresh() {
    guard !refreshing else { return }
    refreshing = true
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let found = Self.resolve(in: ShellPATH.shared.value())
      DispatchQueue.main.async {
        guard let self else { return }
        self.refreshing = false
        if self.agents != found {
          self.agents = found
          self.onChange?()
        }
        self.hasResolved = true
        self.onResolved?()
      }
    }
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
}
