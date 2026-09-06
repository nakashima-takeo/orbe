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
  /// CLI 1 つぶんの静的な知識。`resumeFlag` は `<command> <resumeFlag> <sessionId>` の席。
  /// `reportsIdleOnStart` は Orbe のプラグインがその CLI の起動時 hook に idle を配線しているか
  /// （claude の SessionStart→idle。codex CLI 自身も SessionStart を持つが `codex-hooks.json` は
  /// 配線していない）——出所は `docs/spec/agent/plugin-package.md` の event→state 表。
  struct AgentProfile {
    let command: String
    let resumeFlag: String
    let reportsIdleOnStart: Bool
  }

  /// 一級サポートの全体。並び＝デフォルト未設定時の優先順。
  static let profiles = [
    AgentProfile(command: "claude", resumeFlag: "--resume", reportsIdleOnStart: true),
    AgentProfile(command: "codex", resumeFlag: "resume", reportsIdleOnStart: false),
    AgentProfile(command: "agy", resumeFlag: "--conversation", reportsIdleOnStart: false),
  ]

  static var supported: [String] { profiles.map(\.command) }

  static func profile(_ command: String) -> AgentProfile? {
    profiles.first { $0.command == command }
  }

  /// `spawn_agent` / `resume_agent` が「準備できた」を待てるか（未対応 agent は偽）。
  static func reportsIdleOnStart(_ command: String) -> Bool {
    profile(command)?.reportsIdleOnStart ?? false
  }

  private(set) var agents: [AgentCLI] = []
  /// 一度でも検出を完了したか（detecting を解く判断に使う）。
  private(set) var hasResolved = false
  /// 検出結果が変わった通知（メインスレッドで呼ぶ）。
  var onChange: (() -> Void)?
  /// 検出完了通知（refresh ごとに必ず一度呼ぶ。メインスレッドで呼ぶ）。
  var onResolved: (() -> Void)?
  private var refreshing = false

  /// 裏で再検出する。実行中なら何もしない（パレット開閉の連打で走査を積み上げない）。
  /// 走査するのはファイルシステムだけで、PATH は `ShellPATH` がプロセスで一度捉えた値を読む。
  /// 既に PATH にあるディレクトリへ入る導入（`brew install` 等）はここで見つかり、rc に新しい
  /// ディレクトリを足すインストーラで入れたものは次の Orbe 起動から見える。
  ///
  /// 待ちは `.settled`——ここは背景で走っており、probe の着地を待って困る者がいない。**打ち切って
  /// floor で答えると、検出ゼロがこのセッションの確定結果になる**（オンボーディングは 1 度しか出ない）。
  func refresh() {
    guard !refreshing else { return }
    refreshing = true
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let found = Self.resolve(in: ShellPATH.shared.value(wait: .settled))
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

  /// resume コマンドへ埋めてよい sessionId の文字集合（非空・letter / number / `-` / `_` / `.`）。
  /// `resumeCommand` と `restore_sessions` の検証が同じ 1 関数を読む。
  static func isSafeSessionId(_ sessionId: String) -> Bool {
    !sessionId.isEmpty
      && sessionId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
  }

  /// 各 CLI の resume コマンド文字列（`/bin/sh -c` 経由で実行される前提）。
  /// 未対応 agent・安全な文字集合（UUID 等）外の sessionId は nil（呼び出し側が素のシェルへ fallback）。
  /// command は表のリテラルでのみ一致し、sessionId は文字集合検証するため shell インジェクションを防ぐ。
  static func resumeCommand(forAgent command: String, sessionId: String) -> String? {
    guard isSafeSessionId(sessionId), let profile = profile(command) else { return nil }
    return "\(profile.command) \(profile.resumeFlag) \(sessionId)"
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
