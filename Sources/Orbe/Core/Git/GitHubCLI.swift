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
/// gh の探索も子プロセスの PATH も `ShellPATH` の値 1 つで賄う（git と同じ PATH で動く）。
final class GitHubCLI {
  static let shared = GitHubCLI()

  private let queue = DispatchQueue(label: "dev.orbe.gh", qos: .userInitiated)
  /// ブラウザで開く操作の口。取得（`queue`）とは分ける——結果を待たない即時操作なので取得と
  /// 直列化する理由が無く、同じ列に載せると閉じた PR の取得（worktree 本数ぶんの往復）が
  /// 捌けるまでブラウザが開かない。決定は Enter 一発という前提がそこで崩れる。
  private let webQueue = DispatchQueue(label: "dev.orbe.gh.web", qos: .userInitiated)
  private let lock = DispatchQueue(label: "dev.orbe.gh.state")
  /// 見つかった gh の絶対パス。**見つからなかったことは覚えない**——起動直後のまだ痩せた PATH で
  /// 一度外した結果を焼くと、PATH が整った後も gh が永久に「未導入」のままになる。
  private var cachedGh: String?

  /// gh 呼び出しの時間上限（ネット待ちのハングを引きずらない）。
  private let timeout: TimeInterval = 15

  /// 打ち切り後に EOF を待つ猶予。pipe の書き込み端を握る子孫がいると EOF は来ないことがあり、
  /// **無期限に待つと、待ちそのものが新しいハングになる**（`GitRunner.terminationGrace` と同じ規範）。
  private static let terminationGrace: TimeInterval = 2

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

  /// ブランチ名指しの PR 取得引数（open/closed を `--state all` の 1 往復で。作成日時の降順）。
  /// **直近 N 件の一覧窓は使わない**——古くにマージされた PR も、古くから開いたままの PR も、
  /// 窓から溢れると「merged チップが出ない」「レビュー中なのに安全確認を素通りする」という
  /// 取りこぼしになる。`--head` は remote 側でブランチが削除済み（`[gone]`）でも headRefName で
  /// PR を返す。
  ///
  /// `--limit 100` は gh が 1 往復で取れる上限。**往復コストは limit に依らない**（実測で 5／30／100
  /// が同じ）ので、ここを絞る動機が無い一方、絞ると `--head` に混ざる fork の同名ブランチの PR
  /// （呼び出し側が落とす）で埋まって自リポジトリの PR が窓落ちしうる。上限まで取れば、この
  /// ブランチの PR が 100 件を超えない限り窓落ちは起きない。
  static func branchPRArguments(head: String) -> [String] {
    [
      "pr", "list", "--state", "all", "--head", head, "--limit", "100", "--json",
      "number,headRefName,state,baseRefName,isCrossRepository",
    ]
  }

  /// 指定ブランチ群に紐づく PR（ブランチごとに open/closed 両方）。worktree の掃除で
  /// 「レビュー中か／マージ済みか／未マージのまま閉じられたか」を見る。`nil` = 取得失敗／`[]` = 該当なし。
  func branchPullRequests(
    cwd: String, heads: [String], completion: @escaping ([GitHubBranchPR]?) -> Void
  ) {
    fetch(cwd: cwd, argsList: heads.map(Self.branchPRArguments(head:)), completion: completion)
  }

  /// 取得の共通口（1 コマンド）。
  private func fetch<T: Decodable>(
    cwd: String, args: [String], completion: @escaping ([T]?) -> Void
  ) {
    fetch(cwd: cwd, argsList: [args], completion: completion)
  }

  /// 取得の共通口（複数コマンドを直列に叩いて連結する）。失敗は `nil`（空配列に潰さない——
  /// 空で潰すと呼び出し側のキャッシュを消してしまう）。**1 本でも失敗したら全体を `nil`** に
  /// するのが要点で、部分結果で差し替えると失敗したぶんの前回結果だけが静かに消える
  /// （据え置き契約は配列まるごとの置換が前提）。
  private func fetch<T: Decodable>(
    cwd: String, argsList: [[String]], completion: @escaping ([T]?) -> Void
  ) {
    queue.async {
      guard let gh = self.resolveGh() else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var results: [T] = []
      for args in argsList {
        let out = self.runSync(gh, args, cwd: cwd)
        guard out.status == 0,
          let decoded = try? JSONDecoder().decode([T].self, from: out.stdout)
        else {
          DispatchQueue.main.async { completion(nil) }
          return
        }
        results.append(contentsOf: decoded)
      }
      DispatchQueue.main.async { completion(results) }
    }
  }

  // MARK: - ブラウザで開く（fire-and-forget）

  func openIssueWeb(number: Int, cwd: String) { openWeb("issue", number: number, cwd: cwd) }
  func openPRWeb(number: Int, cwd: String) { openWeb("pr", number: number, cwd: cwd) }

  private func openWeb(_ kind: String, number: Int, cwd: String) {
    webQueue.async {
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
    // ネット待ちのハングは時間上限で打ち切る（通常は terminate で pipe が EOF に達し読みも解ける）。
    // EOF が来るかは書き込み端を握る子孫次第なので、打ち切り後の読み終わり待ちも猶予で有界にする
    // ——ここを無期限にすると、打ち切ったのに返らないという新しいハングになる。
    if group.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = group.wait(timeout: .now() + Self.terminationGrace)
      return Output(status: -1, stdout: Data())
    }
    process.waitUntilExit()
    return Output(status: process.terminationStatus, stdout: outData)
  }

  private func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ShellPATH.shared.value()
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["NO_COLOR"] = "1"
    return env
  }

  /// gh の絶対パスを解決（子プロセスへ渡すのと同じ PATH 上を走査）。
  /// 見つかったときだけ覚え、見つからない間は毎回走査し直す（数回の `isExecutableFile`）。
  private func resolveGh() -> String? {
    lock.sync {
      if let cached = cachedGh { return cached }
      let found = ShellPATH.shared.value().split(separator: ":").map(String.init)
        .map { ($0 as NSString).appendingPathComponent("gh") }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
      cachedGh = found
      return found
    }
  }
}
