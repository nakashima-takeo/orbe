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
  /// `headless` は裏で非対話に回す能力。
  struct AgentProfile {
    let command: String
    let resumeFlag: String
    let reportsIdleOnStart: Bool
    let headless: HeadlessSupport
  }

  /// 一級サポートの全体。並び＝デフォルト未設定時の優先順。
  static let profiles = [
    AgentProfile(
      command: "claude", resumeFlag: "--resume", reportsIdleOnStart: true,
      headless: .runs(
        HeadlessCLI(
          arguments: ClaudeHeadless.arguments, environment: ClaudeHeadless.environment,
          reply: ClaudeHeadless.reply, availableTools: ClaudeHeadless.availableTools))),
    AgentProfile(
      command: "codex", resumeFlag: "resume", reportsIdleOnStart: false,
      headless: .refuses(.toolsNotAllowListable)),
    AgentProfile(
      command: "agy", resumeFlag: "--conversation", reportsIdleOnStart: false,
      headless: .refuses(.noToolOrSessionControl)),
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

/// 裏で非対話に回す能力。
enum HeadlessSupport {
  case runs(HeadlessCLI)
  case refuses(HeadlessRefusal)
}

/// 非対話の 1 回の起こし方。依頼文は標準入力で渡す。`environment` は子の環境に上書きする変数。`reply` は標準出力の 1 行から
/// 最終応答を取り出す（最終応答の行でなければ nil）。`availableTools` は始まりの出来事の行から、その回で使えるツールの名前を
/// 取り出す（始まりの行でなければ nil）。
struct HeadlessCLI {
  let arguments: (_ model: String, _ tools: [String]) -> [String]
  let environment: (_ tools: [String]) -> [String: String]
  let reply: (Data) -> BackgroundAgentReply?
  let availableTools: (Data) -> [String]?

  /// 指定した MCP のツールのうち、`available` に無いもの。`mcp__<サーバー>` はそのサーバーのツールが 1 つでもあれば揃っている。
  static func missingTools(_ requested: [String], available: [String]) -> [String] {
    requested.filter { name in
      name.hasPrefix("mcp__")
        && !available.contains { $0 == name || $0.hasPrefix(name + "__") }
    }
  }
}

/// 裏で回せない理由。
enum HeadlessRefusal: Equatable {
  /// 組み込みツールを「これだけ許可」と指定する手段が無い。禁止の列挙では、版が上がって増えたツールが漏れる。
  case toolsNotAllowListable
  /// 使えるツールの指定も、会話を残さない指定も無い。
  case noToolOrSessionControl
}

/// claude の非対話の契約。
enum ClaudeHeadless {
  /// MCP のツール（`mcp__` で始まる名前）を指定しない呼び出しは、利用者の設定・プラグイン・hook・MCP サーバーを一切読まず、
  /// 指定した組み込みツールだけで閉じる。MCP のツールを指定した呼び出しは、利用者が登録した MCP サーバーを名前で使うため
  /// 設定を読み、指定したもの以外は問わずに拒否する（`dontAsk`。利用者の bypassPermissions もこれで上書きする）。
  static func arguments(model: String, tools: [String]) -> [String] {
    let builtins = tools.filter { !$0.hasPrefix("mcp__") }
    var args = ["-p", "--model", model, "--tools", builtins.joined(separator: ",")]
    if !tools.isEmpty { args += ["--allowedTools", tools.joined(separator: ",")] }
    args += [
      "--permission-mode", "dontAsk", "--no-session-persistence",
      "--output-format", "stream-json", "--verbose",
    ]
    if builtins.count == tools.count { args += ["--setting-sources", "", "--strict-mcp-config"] }
    return args
  }

  /// どちらの呼び出しでも、利用者の CLAUDE.md と auto memory を読まない。`--setting-sources` は auto memory を止めず、
  /// 設定を読む呼び出しでは CLAUDE.md も読むため、環境で止める。MCP のツールを指定した呼び出しは、MCP サーバーの接続を
  /// 待ってから始める——待たないと、起動に数秒かかるサーバーのツールが無いまま始まる。待ちは agent の無出力の上限より短い。
  static func environment(tools: [String]) -> [String: String] {
    var env = [
      "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
      "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    ]
    if tools.contains(where: { $0.hasPrefix("mcp__") }) {
      env["CLAUDE_CODE_MCP_STARTUP_WAIT_MS"] = String(Int(mcpStartupWait * 1000))
    }
    return env
  }

  static let mcpStartupWait: TimeInterval = 60

  /// 出来事の流れの最初の `system`/`init` が、その回で使えるツールの名前を持つ。
  static func availableTools(_ line: Data) -> [String]? {
    guard
      let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      event["type"] as? String == "system", event["subtype"] as? String == "init"
    else { return nil }
    return event["tools"] as? [String] ?? []
  }

  /// 出来事の流れのうち、最後の `result` が最終応答。失敗で終わった回は本文を持たず、理由を `errors` に入れる。
  static func reply(_ line: Data) -> BackgroundAgentReply? {
    guard
      let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      event["type"] as? String == "result"
    else { return nil }
    let text =
      event["result"] as? String ?? (event["errors"] as? [String] ?? []).joined(separator: "\n")
    return BackgroundAgentReply(text: text, isError: event["is_error"] as? Bool ?? false)
  }
}
