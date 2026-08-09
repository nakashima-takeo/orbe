import Foundation

/// git CLI の実行基盤。GUI アプリの貧弱な環境変数でも hooks・署名がユーザーの
/// シェル環境と同等に動くよう、ログインシェルの PATH を一度だけ解決して
/// 全呼び出しへ引き継ぐ。
///
/// 排他は**インスタンス内で閉じる**（キューがインスタンスの持ち物のため）。同じリポジトリを
/// 別インスタンスから書くと直列化が効かないので、**本番は必ず `shared` を通す**——`GitRepo` は
/// runner を既定引数 `.shared` で受けており、明示的に別インスタンスを渡すのはテストだけ。
final class GitRunner {
  struct Output {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(bytes: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(bytes: stderr, encoding: .utf8) ?? "" }
    var isSuccess: Bool { status == 0 }
  }

  /// git 実行の並行レーン。「何と競合するか」で選ぶ。
  enum Lane {
    /// 読み取り。共有 queue で並行に走る。
    case read
    /// 同一チェックアウトの index・作業ツリーを書く操作。共有 queue の barrier で単独直列化する
    /// （`.git/index.lock` は待たずに即 fatal するため、順番はアプリ側で作る）。
    case exclusive
    /// 共有チェックアウトと領域が交わらない操作。独立レーンで走らせ、barrier チェーンに載せない。
    case independent
  }

  static let shared = GitRunner()

  /// 読み取り系の同時実行を許す。書き込み系は barrier で排他直列化する
  /// （concurrent キュー上の read-write lock）。env 解決だけ envLock で直列に守る。
  private let queue = DispatchQueue(
    label: "dev.orbe.git", qos: .userInitiated, attributes: .concurrent)
  /// 共有 `queue` の read-write lock から切り離した独立レーン（`.independent`）。
  /// 所要時間が不定の操作をここで走らせ、共有 queue の barrier チェーンに載せない。
  /// GCD barrier は「submit 済みの全ブロックの完了」を待つため、共有 queue で長い操作を
  /// 走らせると（`.read` でも）後続の `.exclusive` がその完了を待つ。
  /// 独立 queue に逃がすことで、barrier が長い操作を待たなくなる。
  private let isolatedQueue = DispatchQueue(
    label: "dev.orbe.git.isolated", qos: .userInitiated, attributes: .concurrent)
  /// 環境変数はプロセスの事実（ログインシェルの PATH）でありインスタンスの事実ではない。
  /// インスタンスごとに持つと、`GitRunner()` を作るたびにログインシェルを起動して待つことになる。
  private static let envLock = DispatchQueue(label: "dev.orbe.git.env")
  private nonisolated(unsafe) static var cachedEnvironment: [String: String]?

  /// git を背景で実行し、結果をメインキューへ返す。レーンの意味は `Lane` を見る。
  func run(
    _ args: [String], cwd: String, stdin: Data? = nil, lane: Lane = .read,
    completion: @escaping (Output) -> Void
  ) {
    let work = {
      let output = self.runSync(args, cwd: cwd, stdin: stdin)
      DispatchQueue.main.async { completion(output) }
    }
    switch lane {
    case .read: queue.async(execute: work)
    case .exclusive: queue.async(flags: .barrier, execute: work)
    case .independent: isolatedQueue.async(execute: work)
    }
  }

  /// 同期実行。呼び出し元スレッドでブロックする（背景キュー・テスト用）。
  func runSync(_ args: [String], cwd: String, stdin: Data? = nil) -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    process.environment = Self.environment()

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let input: Pipe? = stdin != nil ? Pipe() : nil
    if let input { process.standardInput = input }

    do {
      try process.run()
    } catch {
      return Output(
        status: -1, stdout: Data(), stderr: Data("\(error.localizedDescription)\n".utf8))
    }
    if let input, let stdin {
      input.fileHandleForWriting.write(stdin)
      input.fileHandleForWriting.closeFile()
    }

    // stderr は別スレッドで吸い出す（両 pipe が埋まる相互デッドロックの防止）。
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
      group.leave()
    }
    let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    group.wait()
    process.waitUntilExit()
    return Output(status: process.terminationStatus, stdout: outData, stderr: errData)
  }

  /// 呼び出し共通の環境変数（プロセス内で初回に一度だけ構築）。
  private static func environment() -> [String: String] {
    envLock.sync {
      if let cached = cachedEnvironment { return cached }
      var env = ProcessInfo.processInfo.environment
      env["PATH"] = Self.loginShellPATH() ?? Self.fallbackPATH(env["PATH"])
      env["GIT_TERMINAL_PROMPT"] = "0"  // 資格情報等の対話でハングさせない
      cachedEnvironment = env
      return env
    }
  }

  private static func fallbackPATH(_ current: String?) -> String {
    let base = current ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let parts = base.split(separator: ":").map(String.init)
    let extra = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !parts.contains($0) }
    return (extra + parts).joined(separator: ":")
  }

  /// ログインシェルから PATH を取る（hooks が brew 導入ツールへ届くように）。
  /// GUI アプリの貧弱な PATH ではユーザー導入ツールが見えないため、エディタ検出等も再利用する。
  static func loginShellPATH() -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    // 壊れた rc ファイル等でハングしたら諦める（fallback が引き受ける）。
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning {
      process.terminate()
      return nil
    }
    guard process.terminationStatus == 0,
      let data = try? out.fileHandleForReading.readToEnd(),
      let raw = String(bytes: data, encoding: .utf8)
    else { return nil }
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }
}
