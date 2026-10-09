import Foundation

/// 実行の係。アプリに 1 つ。仕事を受け取ると止める手を返し、結果を main へ届ける。
///
/// 同時に走る数は種類ごとの別々の枠で絞り、溢れた分は来た順に待つ（軽いコマンドが重い agent の後ろで待たされない）。
/// 予定から来た実行も、予定ではない単発の実行も、ここを通る。終了時の全停止もここが受け持つ。
///
/// 子の環境は「プロセスの環境＋子プロセス PATH」。PATH と agent の絶対パスは実行のたびに裏で解決し、PATH の確定を待つ
/// ——起動直後の「検出中」を「無い」と取り違えず、後から入れた CLI も拾うため。
final class BackgroundRuns {
  static let shared = BackgroundRuns()

  static let defaultSlots: [BackgroundJob.Kind: Int] = [.agent: 2, .command: 4]
  /// agent の出来事 1 行の上限。超えた行は捨てる（大きなツールの結果だけで応答を失わないため、最終応答の上限とは別に持つ）。
  static let eventLineLimit = 16 << 20
  /// 全停止が待つ上限。各実行は SIGTERM → SIGKILL → 汲み出しの猶予で必ず終わるので、その合計に余裕を足す。
  static let shutdownTimeout =
    BackgroundProcess.killGrace + BackgroundProcess.drainGrace + 1

  private let slots: [BackgroundJob.Kind: Int]
  private let resolvePATH: () -> String
  private let lock = NSLock()
  private var running: [BackgroundJob.Kind: Int] = [:]
  private var waiting: [Entry] = []
  private var inFlight: [Entry] = []
  private var shuttingDown = false
  private let activity = DispatchGroup()

  init(
    slots: [BackgroundJob.Kind: Int] = BackgroundRuns.defaultSlots,
    resolvePATH: @escaping () -> String = { ShellPATH.shared.value(wait: .settled) }
  ) {
    self.slots = slots
    self.resolvePATH = resolvePATH
  }

  /// 走らせる。結果は main で 1 度だけ届く（全停止で捨てた順番待ちの分と、全停止の後に渡した分には届かない）。返る手で止めると「止められた」が届く。
  func run(
    _ job: BackgroundJob, completion: @escaping (BackgroundRunResult) -> Void
  ) -> BackgroundRunHandle {
    let entry = Entry(job: job, completion: completion)
    let accepted = lock.withLock {
      guard !shuttingDown else { return false }
      waiting.append(entry)
      return true
    }
    if accepted { pump() }
    return BackgroundRunHandle { [weak self] in self?.stop(entry) }
  }

  /// 走っている全グループを止め、回収してから返る。順番待ちの分は捨てる。終了時に main から呼ぶ。
  func stopAll() {
    let processes = lock.withLock {
      shuttingDown = true
      waiting.removeAll()
      for entry in inFlight { entry.stopRequested = true }
      return inFlight.compactMap(\.process)
    }
    for process in processes { process.stop() }
    _ = activity.wait(timeout: .now() + Self.shutdownTimeout)
  }

  // MARK: - 枠

  private func pump() {
    let starting = lock.withLock {
      var picked: [Entry] = []
      var rest: [Entry] = []
      for entry in waiting {
        let kind = entry.job.kind
        if running[kind, default: 0] < slots[kind, default: 0] {
          running[kind, default: 0] += 1
          inFlight.append(entry)
          picked.append(entry)
        } else {
          rest.append(entry)
        }
      }
      waiting = rest
      return picked
    }
    for entry in starting {
      activity.enter()
      DispatchQueue.global(qos: .utility).async { self.execute(entry) }
    }
  }

  private func stop(_ entry: Entry) {
    enum Action {
      case none
      case dropWaiting
      case stopProcess(BackgroundProcess)
    }
    let action: Action = lock.withLock {
      if let index = waiting.firstIndex(where: { $0 === entry }) {
        waiting.remove(at: index)
        return .dropWaiting
      }
      guard inFlight.contains(where: { $0 === entry }) else { return .none }
      entry.stopRequested = true
      return entry.process.map(Action.stopProcess) ?? .none
    }
    switch action {
    case .none: break
    case .dropWaiting:
      let now = Date()
      let result = BackgroundRunResult(
        commandLine: Self.describe(entry.job), startedAt: now, endedAt: now, ending: .stopped,
        output: .none)
      DispatchQueue.main.async { entry.completion(result) }
    case .stopProcess(let process): process.stop()
    }
  }

  // MARK: - 1 回

  private func execute(_ entry: Entry) {
    let startedAt = Date()
    let result: BackgroundRunResult
    switch prepare(entry.job) {
    case .failure(let failure):
      result = BackgroundRunResult(
        commandLine: Self.describe(entry.job), startedAt: startedAt, endedAt: Date(),
        ending: .notStarted(failure), output: .none)
    case .success(let prepared):
      let process = BackgroundProcess(prepared.spec)
      let proceed = lock.withLock {
        guard !entry.stopRequested else { return false }
        entry.process = process
        return true
      }
      if proceed {
        let outcome = process.run()
        result = prepared.makeResult(outcome, startedAt, Date())
      } else {
        result = BackgroundRunResult(
          commandLine: prepared.commandLine, startedAt: startedAt, endedAt: Date(),
          ending: .stopped, output: .none)
      }
    }
    lock.withLock {
      running[entry.job.kind, default: 0] -= 1
      inFlight.removeAll { $0 === entry }
      entry.process = nil
    }
    DispatchQueue.main.async { entry.completion(result) }
    activity.leave()
    pump()
  }

  private func prepare(_ job: BackgroundJob) -> Result<Prepared, BackgroundStartFailure> {
    do {
      try job.validate()
    } catch {
      return .failure(.invalid(error))
    }
    switch job.work {
    case .command(let command):
      let directory = command.directory ?? NSHomeDirectory()
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { return .failure(.directoryMissing(directory)) }
      return .success(
        .command(command, directory: directory, limits: job.limits, env: environment()))
    case .agent(let call):
      let cli: HeadlessCLI
      switch AgentCatalog.profile(call.cli)?.headless {
      case .runs(let found): cli = found
      case .refuses(let reason): return .failure(.agentUnsupported(cli: call.cli, reason: reason))
      case nil: return .failure(.invalid(.unknownAgent(call.cli)))
      }
      let env = environment()
      guard
        let found = AgentCatalog.resolve(in: env["PATH"] ?? "").first(where: {
          $0.command == call.cli
        })
      else { return .failure(.agentNotFound(call.cli)) }
      return .success(
        .agent(call, cli: cli, executable: found.path, limits: job.limits, env: env))
    }
  }

  private func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = resolvePATH()
    return env
  }

  /// 走らせる前に終わった回の表示用のコマンド行。
  private static func describe(_ job: BackgroundJob) -> String {
    switch job.work {
    case .command(let command): command.script
    case .agent(let call): call.cli
    }
  }

  // MARK: - 型

  private final class Entry {
    let job: BackgroundJob
    let completion: (BackgroundRunResult) -> Void
    var process: BackgroundProcess?
    var stopRequested = false

    init(job: BackgroundJob, completion: @escaping (BackgroundRunResult) -> Void) {
      self.job = job
      self.completion = completion
    }
  }
}

/// 実行を止める手。何度呼んでもよい。
final class BackgroundRunHandle {
  private let onStop: () -> Void

  init(stop: @escaping () -> Void) {
    onStop = stop
  }

  func stop() {
    onStop()
  }
}

/// 起こす直前まで組み立てた 1 回。
private struct Prepared {
  let commandLine: String
  let spec: BackgroundProcess.Spec
  let makeResult:
    (BackgroundProcess.Outcome, _ startedAt: Date, _ endedAt: Date) -> BackgroundRunResult

  static func command(
    _ command: BackgroundCommand, directory: String, limits: BackgroundLimits,
    env: [String: String]
  ) -> Prepared {
    let spec = BackgroundProcess.Spec(
      executable: "/bin/sh", arguments: ["-c", command.script], environment: env,
      directory: directory, stdin: nil, elapsedLimit: limits.elapsed, idleLimit: limits.idle,
      stdout: .collect(.init(limit: limits.output, overflowStops: true)),
      stderr: .init(limit: limits.stderr, overflowStops: true))
    return Prepared(commandLine: command.script, spec: spec) { outcome, startedAt, endedAt in
      BackgroundRunResult(
        commandLine: command.script, startedAt: startedAt, endedAt: endedAt,
        ending: ending(outcome.ending),
        output: launched(outcome)
          ? .command(stdout: outcome.stdout, stderr: outcome.stderr) : .none)
    }
  }

  static func agent(
    _ call: BackgroundAgentCall, cli: HeadlessCLI, executable: String, limits: BackgroundLimits,
    env: [String: String]
  ) -> Prepared {
    let arguments = cli.arguments(call.model, call.tools)
    let commandLine = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    let box = ReplyBox()
    let watched = call.tools.filter { $0.hasPrefix("mcp__") }
    let spec = BackgroundProcess.Spec(
      executable: executable, arguments: arguments,
      environment: env.merging(cli.environment(call.tools)) { $1 }, directory: NSHomeDirectory(),
      stdin: Data(call.prompt.utf8), elapsedLimit: limits.elapsed,
      idleLimit: limits.idle,
      stdout: .lines(maxLength: BackgroundRuns.eventLineLimit) { line in
        // 指定した MCP のツールが揃わないまま始まったら、モデルを呼ぶ前に止める（ツール無しで別の答えを作らせない）。
        if !watched.isEmpty, !box.checkedTools, let available = cli.availableTools(line) {
          box.checkedTools = true
          let missing = HeadlessCLI.missingTools(watched, available: available)
          if !missing.isEmpty {
            box.missingTools = missing
            return .stopped
          }
        }
        guard let reply = cli.reply(line) else { return nil }
        guard reply.text.utf8.count <= limits.output else { return .limited(.output) }
        box.reply = reply
        return nil
      },
      // agent の標準エラーは成果ではない。上限は貯める量だけを抑え、走らせ続ける。
      stderr: .init(limit: limits.stderr, overflowStops: false))
    return Prepared(commandLine: commandLine, spec: spec) { outcome, startedAt, endedAt in
      var result = ending(outcome.ending)
      if let missing = box.missingTools {
        result = .toolsUnavailable(missing)
      } else if box.reply == nil, outcome.droppedLines > 0, result.isProcessExit {
        // 捨てた行が最終応答だった——応答を失ったのは出力の上限による。
        result = .limited(.output)
      }
      return BackgroundRunResult(
        commandLine: commandLine, startedAt: startedAt, endedAt: endedAt, ending: result,
        output: launched(outcome) ? .agent(reply: box.reply, stderr: outcome.stderr) : .none)
    }
  }

  private static func launched(_ outcome: BackgroundProcess.Outcome) -> Bool {
    if case .launchFailed = outcome.ending { return false }
    return true
  }

  private static func ending(_ ending: BackgroundProcess.Ending) -> BackgroundEnding {
    switch ending {
    case .exited(let code): .exited(code)
    case .signaled(let signal): .signaled(signal)
    case .limited(let limit): .limited(limit)
    case .stopped: .stopped
    case .launchFailed(let errno): .notStarted(.launchFailed(errno))
    }
  }

  private static func shellQuoted(_ word: String) -> String {
    let safe = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@+%")
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// 裏の直列キューで書き、プロセスの終了後に読む。
  private final class ReplyBox: @unchecked Sendable {
    var reply: BackgroundAgentReply?
    var checkedTools = false
    var missingTools: [String]?
  }
}

extension BackgroundEnding {
  fileprivate var isProcessExit: Bool {
    switch self {
    case .exited, .signaled: true
    default: false
    }
  }
}
