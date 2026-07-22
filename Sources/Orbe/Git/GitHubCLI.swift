import Foundation

/// gh CLI で GitHub 実データを取得する可否。フォールバック 3 分岐（＋実データ）の分類。
enum GitHubAvailability: Equatable {
  /// gh 導入・認証済み。実データ取得可。
  case ready
  /// GitHub リポジトリだが gh が PATH に無い。
  case ghMissing
  /// gh はあるが認証情報を持っていない。
  case ghUnauthed
  /// 非 GitHub リポジトリ（origin が github.com でない）。Issues/PR セクションは出さない。
  case notGitHub
}

/// gh のサブプロセス口。`GitRunner` は `/usr/bin/git` 固定契約なので gh 用に別口を設ける。
/// PATH は `GitRunner.loginShellPATH()`（GUI の貧弱 PATH 対策の既存資産）を再利用して解決する。
final class GitHubCLI {
  static let shared = GitHubCLI()

  private let queue = DispatchQueue(label: "dev.orbe.gh", qos: .userInitiated)
  private let lock = DispatchQueue(label: "dev.orbe.gh.state")
  private var cachedEnv: [String: String]?
  private var cachedGh: String??  // 外: 解決済みか / 内: 見つかったか

  /// gh 呼び出しの時間上限（ネット待ちのハングを引きずらない）。
  private let timeout: TimeInterval = 15

  // MARK: - probe

  /// 認証情報の有無で判定する引数。`gh auth token` は keyring/config/`GH_TOKEN` を読むだけで
  /// ネットに触らない。`gh auth status` はトークンを GitHub API で検証するため、疎通不能を未認証と
  /// 誤判定し、キャッシュ済みの行を「gh 未認証」の誘導情報行に置き換えてしまう。
  /// `--hostname` は `originIsGitHub` が真のときだけ probe される前提に合わせ、実際に取得しに行く
  /// ホストを名指しする（default host が Enterprise の環境でも判定がずれない）。
  static let authProbeArguments = ["auth", "token", "--hostname", "github.com"]

  /// 取得可否を判定する。`isGitHub` は `GitRepo.originIsGitHub` の結果を渡す。
  /// 見るのはローカルの事実（gh の有無・認証情報の有無）だけ。今 GitHub に届くかは probe の責務では
  /// なく、届かなければ `issues`/`pullRequests` が `nil` を返して呼び出し側が前回結果を据え置く。
  /// `gh auth token` の stdout はトークンそのものなので `status` しか読まない。
  func probe(cwd: String, isGitHub: Bool, completion: @escaping (GitHubAvailability) -> Void) {
    guard isGitHub else {
      completion(.notGitHub)
      return
    }
    queue.async {
      guard let gh = self.resolveGh() else {
        DispatchQueue.main.async { completion(.ghMissing) }
        return
      }
      let out = self.runSync(gh, Self.authProbeArguments, cwd: cwd)
      let state: GitHubAvailability = out.status == 0 ? .ready : .ghUnauthed
      DispatchQueue.main.async { completion(state) }
    }
  }

  // MARK: - 取得

  /// open issue 一覧。`nil` = 取得失敗（gh 未解決・非 0 終了・タイムアウト・デコード失敗）で
  /// 呼び出し側は前回結果を据え置く。`[]` は「0 件」を意味する。
  func issues(cwd: String, limit: Int, completion: @escaping ([GitHubIssue]?) -> Void) {
    fetch(
      cwd: cwd,
      args: [
        "issue", "list", "--state", "open", "--limit", String(limit), "--json",
        "number,title",
      ], completion: completion)
  }

  /// open PR 一覧。`nil` = 取得失敗（呼び出し側は前回結果を据え置く）／`[]` = 0 件。
  func pullRequests(
    cwd: String, limit: Int, completion: @escaping ([GitHubPullRequest]?) -> Void
  ) {
    fetch(
      cwd: cwd,
      args: [
        "pr", "list", "--state", "open", "--limit", String(limit), "--json",
        "number,title,headRefName,reviewDecision,isCrossRepository",
      ], completion: completion)
  }

  /// 取得の共通口。失敗は `nil`（空配列に潰さない——空で潰すと呼び出し側のキャッシュを消してしまう）。
  private func fetch<T: Decodable>(
    cwd: String, args: [String], completion: @escaping ([T]?) -> Void
  ) {
    queue.async {
      guard let gh = self.resolveGh() else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let out = self.runSync(gh, args, cwd: cwd)
      let decoded: [T]? =
        out.status == 0 ? try? JSONDecoder().decode([T].self, from: out.stdout) : nil
      DispatchQueue.main.async { completion(decoded) }
    }
  }

  // MARK: - ブラウザで開く（fire-and-forget）

  func openIssueWeb(number: Int, cwd: String) { openWeb("issue", number: number, cwd: cwd) }
  func openPRWeb(number: Int, cwd: String) { openWeb("pr", number: number, cwd: cwd) }

  private func openWeb(_ kind: String, number: Int, cwd: String) {
    queue.async {
      guard let gh = self.resolveGh() else { return }
      _ = self.runSync(gh, [kind, "view", String(number), "--web"], cwd: cwd)
    }
  }

  // MARK: - 実行基盤

  private struct Output {
    let status: Int32
    let stdout: Data
  }

  private func runSync(_ executable: String, _ args: [String], cwd: String) -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    process.environment = environment()

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return Output(status: -1, stdout: Data())
    }
    // stdout/stderr は別スレッドで並行に吸い出す（片方だけ読むと相手の pipe 満杯で相互デッドロック）。
    var outData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      _ = try? err.fileHandleForReading.readToEnd()
      group.leave()
    }
    // ネット待ちのハングは時間上限で打ち切る（terminate で pipe が EOF に達し読みも解ける）。
    if group.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      group.wait()
      return Output(status: -1, stdout: Data())
    }
    process.waitUntilExit()
    return Output(status: process.terminationStatus, stdout: outData)
  }

  private func environment() -> [String: String] {
    lock.sync {
      if let cached = cachedEnv { return cached }
      var env = ProcessInfo.processInfo.environment
      if let path = GitRunner.loginShellPATH() { env["PATH"] = path }
      env["GIT_TERMINAL_PROMPT"] = "0"
      env["NO_COLOR"] = "1"
      cachedEnv = env
      return env
    }
  }

  /// gh の絶対パスを解決（解決済み PATH 上を走査）。一度だけ解決してキャッシュする。
  private func resolveGh() -> String? {
    lock.sync {
      if let cached = cachedGh { return cached }
      let path = GitRunner.loginShellPATH() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
      let found = path.split(separator: ":").map(String.init)
        .map { ($0 as NSString).appendingPathComponent("gh") }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
      cachedGh = .some(found)
      return found
    }
  }
}
