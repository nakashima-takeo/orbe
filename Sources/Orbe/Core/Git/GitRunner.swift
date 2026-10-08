import Foundation

/// git CLI の実行基盤。GUI アプリの貧弱な環境変数でも hooks・署名がユーザーの
/// シェル環境と同等に動くよう、`ShellPATH` の PATH を全呼び出しへ引き継ぐ。
///
/// 実行は並ばない——すべて 1 本の並行キューで走る。git が待たずに落ちるロックは index.lock と config.lock だけで
/// （ref・packed-refs は git 自身が再試行する）、index を書くのはその worktree の根のサービスだけなので、順番は
/// そこが持つ（`RootFiles`）。ここで並べると、長い hook 1 本が無関係なリポジトリの git まで止める。
final class GitRunner {
  static let shared = GitRunner()

  private let queue = DispatchQueue(
    label: "dev.orbe.git", qos: .userInitiated, attributes: .concurrent)
  /// 「1 バイトも出力が無いまま」この時間が過ぎたら打ち切る上限。経過時間ではなく無出力時間で
  /// 測るのは、巨大リポジトリの clone のような正当な長時間実行を切らないため——出力が流れている
  /// 間は延命し、何も起きていないときだけ切る。
  private let idleTimeout: TimeInterval

  /// EOF を待つ猶予。孫プロセス（hook が背景に残した子・`git remote-ext`・gpg）は pipe の
  /// 書き込み端を握ったまま git より長生きするため、EOF が来ないことがある。打ち切った後と、
  /// git が自力で終わった後の両方でこの猶予を使う。**無期限に待つと、待ちそのものが新しい
  /// ハングになる**（切ったのに返らない／終わったのに返らない）。EOF が来ればそこで抜けるので、
  /// 孫を残さない実行がこの猶予を消費することはない。
  private static let terminationGrace: TimeInterval = 2

  /// テストだけが短い `idleTimeout` を渡す（本番の 120 秒を待つテストは書けないため）。
  init(idleTimeout: TimeInterval = 120) {
    self.idleTimeout = idleTimeout
  }

  /// git を背景で実行し、結果をメインキューへ返す。
  ///
  /// - `timesOut`: 無出力が `idleTimeout` 続いたら打ち切るか。止められる人が見ている実行（利用者が起こした書き込み）は
  ///   打ち切らず、返る手で止めさせる——hook・filter・署名・ネットの沈黙は「何も起きていない」ことを意味しない。
  /// - `environment`: 共通の環境に足す変数。
  /// - `onProgress`: stderr の行（`\r` と `\n` で割る）を届いた順に main で渡す。最後の行は `completion` より先に届く。
  /// - `handle`: 止める手。同じ手を続けて渡せば、何段かの実行を 1 つの手で止められる（止めた後の実行は起こさない）。
  @discardableResult
  func run(
    _ args: [String], cwd: String, stdin: Data? = nil, environment: [String: String] = [:],
    timesOut: Bool = true, onProgress: ((String) -> Void)? = nil, handle: Handle = Handle(),
    completion: @escaping (Output) -> Void
  ) -> Handle {
    run(
      args, cwd: cwd, stdin: stdin, environment: environment, timesOut: timesOut,
      onProgress: onProgress, handle: handle, transform: { $0 }, completion: completion)
  }

  /// `run` の、結果を裏のスレッドで変換してから main へ返す形（大きな出力の解析を main に載せない）。
  @discardableResult
  func run<Result>(
    _ args: [String], cwd: String, stdin: Data? = nil, environment: [String: String] = [:],
    timesOut: Bool = true, onProgress: ((String) -> Void)? = nil, handle: Handle = Handle(),
    transform: @escaping (Output) -> Result, completion: @escaping (Result) -> Void
  ) -> Handle {
    let state = RunState(
      idleTimeout: timesOut ? idleTimeout : nil,
      onStderrLine: onProgress.map { deliver in
        { line in DispatchQueue.main.async { deliver(line) } }
      })
    queue.async {
      let result = transform(
        self.execute(
          args, cwd: cwd, launch: Launch(stdin: stdin, environment: environment), state: state,
          handle: handle))
      DispatchQueue.main.async { completion(result) }
    }
    return handle
  }

  /// 同期実行。呼び出し元スレッドでブロックする（背景キュー・テスト用）。
  /// 1 バイトも出力が無いまま `idleTimeout` が過ぎたら SIGTERM で打ち切り、`timedOut` を立てて返る。
  func runSync(_ args: [String], cwd: String, stdin: Data? = nil) -> Output {
    execute(
      args, cwd: cwd, launch: Launch(stdin: stdin), state: RunState(idleTimeout: idleTimeout),
      handle: Handle())
  }

  /// 流しながら読む実行。stdout は届いた塊ごとに `onOutput`（裏のスレッド、届いた順）へ渡し、溜めない。
  /// 終わったら `completion`（裏のスレッド。`stdout` は空）。`environment` は共通の環境に足す変数。返る手の `cancel` で
  /// SIGTERM で止める（止めた後の `completion` も届く）。EOF の猶予は `runSync` と同じだが、無出力では打ち切らない——
  /// 一致の無い間は何も出さない grep のような実行を黙って切らないため、寿命は止める側が持つ。`onOutput` は終わったら
  /// 手放す（呼び出し側が手を持ち、閉包が呼び出し側を掴んでも輪にならない）。`qualityOfService` は git のプロセスの QoS。
  func stream(
    _ args: [String], cwd: String, environment: [String: String] = [:],
    qualityOfService: QualityOfService = .default,
    onOutput: @escaping (Data) -> Void, completion: @escaping (Output) -> Void
  ) -> Handle {
    let state = RunState(idleTimeout: nil, onStdout: onOutput)
    let handle = Handle()
    queue.async {
      completion(
        self.execute(
          args, cwd: cwd,
          launch: Launch(environment: environment, qualityOfService: qualityOfService),
          state: state, handle: handle))
    }
    return handle
  }

  /// 実行を止める手。どのスレッドから何度呼んでもよい。止めると、走っている実行は SIGTERM で切り、
  /// まだ起こしていない実行（この手を渡した後続の段も含む）は起こさずに「止めた」で返る。
  final class Handle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running: [ObjectIdentifier: RunState] = [:]

    init() {}

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
      let states = lock.withLock { () -> [RunState] in
        cancelled = true
        return Array(running.values)
      }
      for state in states { state.cancel() }
    }

    /// 実行を手に結ぶ。既に止めていれば結ばずに false。
    fileprivate func attach(_ state: RunState) -> Bool {
      lock.withLock {
        guard !cancelled else { return false }
        running[ObjectIdentifier(state)] = state
        return true
      }
    }

    fileprivate func detach(_ state: RunState) {
      _ = lock.withLock { running.removeValue(forKey: ObjectIdentifier(state)) }
    }
  }

  /// git の起こし方——標準入力・共通の環境に足す変数・プロセスの QoS。
  private struct Launch {
    var stdin: Data?
    var environment: [String: String] = [:]
    var qualityOfService: QualityOfService = .default
  }

  private func execute(
    _ args: [String], cwd: String, launch: Launch, state: RunState, handle: Handle
  ) -> Output {
    defer { state.releaseOutput() }
    let notStarted = Output(
      status: -1, stdout: Data(), stderr: Data(), ending: .cancelled, exited: false)
    guard handle.attach(state) else { return notStarted }
    defer { handle.detach(state) }
    let process = Process()
    process.qualityOfService = launch.qualityOfService
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    process.environment = Self.environment().merging(launch.environment) { _, added in added }

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let input: Pipe? = launch.stdin != nil ? Pipe() : nil
    if let input { process.standardInput = input }

    collect(out, into: state, isStdout: true)
    collect(err, into: state, isStdout: false)
    process.terminationHandler = { _ in state.noteExit() }

    // 結んだ後・起こす前に止められたら、起こさない。
    guard !state.progress().cancelled else {
      detach(out, err)
      return notStarted
    }
    do {
      try process.run()
    } catch {
      detach(out, err)
      return Output(
        status: -1, stdout: Data(), stderr: Data("\(error.localizedDescription)\n".utf8),
        ending: .launchFailed, exited: false)
    }
    // stdin は背景で書く。呼び出しスレッドで書くと、子が読まないまま pipe バッファ（64KB）を
    // 超えたときに**待ちへ入る前に**固まり、打ち切りが一切効かなくなる。
    if let input, let stdin = launch.stdin {
      DispatchQueue.global(qos: .userInitiated).async {
        try? input.fileHandleForWriting.write(contentsOf: stdin)
        try? input.fileHandleForWriting.close()
      }
    }

    let ending = awaitCompletion(of: process, state: state)
    detach(out, err)
    let collected = state.collected()
    let exited = state.hasExited
    // 打ち切りで子がまだ生きている場合、`terminationStatus` は読めない（例外になる）。
    return Output(
      status: exited ? process.terminationStatus : -1,
      stdout: collected.stdout, stderr: collected.stderr, ending: ending, exited: exited)
  }

  /// プロセスの終了を待ち、残った出力を汲み出して終わり方を返る。
  /// 無出力が実行の `idleTimeout`（nil なら打ち切らない）続くか、止められたら（`Handle.cancel`）SIGTERM で切る。EOF 待ちは
  /// 終了の前後どちらでも `terminationGrace` で有界にし、pipe を握る孫がいても待ち続けない。
  ///
  /// 待ちは semaphore で行い、ポーリングしない——`status` は worktree ごとに撒くので、
  /// 数十 ms のポーリング遅延を全 git 呼び出しへ載せるのは退行になる。
  private func awaitCompletion(of process: Process, state: RunState) -> Ending {
    while true {
      let progress = state.progress()
      if progress.finished { return .completed }
      if progress.cancelled, progress.exitedAt == nil { break }
      // 実行が終わったことを決めるのは**子の終了**であって EOF ではない。EOF が来るかは pipe の
      // 書き込み端を握る第三者（hook が背景に残したプロセス）次第で、待ち続けると git ではなく
      // 他人の寿命に縛られる。終了後に残るのはバッファの汲み出しだけなので猶予で有界にする。
      // ここは打ち切りではないので `terminate()` を通さず、集めた分を持って返る。
      if let exitedAt = progress.exitedAt {
        let drain = exitedAt.addingTimeInterval(Self.terminationGrace)
        guard Date() < drain else { return .completed }
        state.wait(until: drain)
        continue
      }
      guard let idleTimeout = state.idleTimeout else {
        state.waitForChange()
        continue
      }
      let deadline = progress.lastActivity.addingTimeInterval(idleTimeout)
      guard Date() < deadline else { break }
      state.wait(until: deadline)  // 出力が来れば期限が延びるので、目覚めたら測り直す
    }
    let cancelled = state.progress().cancelled
    // SIGTERM で切る。SIGKILL だと git が `.git/index.lock` と作りかけの clone 先を掃除できない。
    // `Process` は子へ新しいプロセスグループを与えるため、この 1 発は git の子孫（hook・
    // transport helper）にも届く。届かないのはセッションごと抜けた孫（daemon 化した hook の子・
    // gpg-agent 等）だけで、そいつらは pipe を握ったまま残る。だから下の猶予が要る。
    process.terminate()
    // 握られたままなら EOF は二度と来ない。猶予だけ与え、来なければ集めた分を持って返る。
    let grace = Date().addingTimeInterval(Self.terminationGrace)
    while !state.progress().finished, Date() < grace { state.wait(until: grace) }
    return cancelled ? .cancelled : .timedOut
  }

  /// pipe の到着を `state` へ流し込む（EOF で読み手を外す）。
  private func collect(_ pipe: Pipe, into state: RunState, isStdout: Bool) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        state.noteEOF()
      } else {
        state.append(data, isStdout: isStdout)
      }
    }
  }

  /// 読み手を外す。打ち切り後は EOF が来ないことがあるので、返る前に必ず通す。
  private func detach(_ pipes: Pipe...) {
    for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
  }

  /// 待ち手が 1 回の観測で見る状態。ばらばらに読むと組み合わせが食い違うので、
  /// 1 度のロックで一貫した組として取り出す。
  fileprivate struct RunProgress {
    /// 終了かつ両 pipe が EOF。
    let finished: Bool
    /// 最後に出力があった時刻（アイドル期限の起点）。
    let lastActivity: Date
    /// 終了を観測した時刻。未終了なら nil。
    let exitedAt: Date?
    /// 止められた（`Handle.cancel`）。
    let cancelled: Bool
  }

  /// git 実行（`execute`）1 回ぶんの共有状態。読み手 2 本（GCD のグローバルキューで発火）・
  /// `terminationHandler`・待ち手が同時に触るので、1 本のロックで束ねる。
  ///
  /// 起こすのは**状態が変わったとき（EOF・プロセス終了・止める）だけ**。出力の到着は期限を延ばすだけで
  /// signal しない——待ち手は期限まで眠っていればよく、起こす必要が無い。
  ///
  /// `idleTimeout` は無出力で打ち切るまでの時間（nil なら打ち切らない）。`onStdout` があれば stdout は溜めずに届いた塊を
  /// そのまま渡す（流しながら読む実行）。実行が返るときに手放し、以後に届いた塊は捨てる。
  fileprivate final class RunState {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var stdout = Data()
    private var stderr = Data()
    private var openPipes = 2
    private var exitedAt: Date?
    private var lastActivity = Date()
    private var cancelled = false
    let idleTimeout: TimeInterval?
    private let streams: Bool
    private var onStdout: ((Data) -> Void)?

    /// stderr の行の受け手と、まだ行になっていない残り。
    private var onStderrLine: ((String) -> Void)?
    private var stderrRest = Data()

    init(
      idleTimeout: TimeInterval?, onStdout: ((Data) -> Void)? = nil,
      onStderrLine: ((String) -> Void)? = nil
    ) {
      self.idleTimeout = idleTimeout
      streams = onStdout != nil
      self.onStdout = onStdout
      self.onStderrLine = onStderrLine
    }

    /// プロセスが終了済みか（`terminationStatus` を読んでよいか）。
    var hasExited: Bool { lock.withLock { exitedAt != nil } }

    /// 読み手（pipe ごとに 1 本、到着順に直列）から呼ばれる。受け手はロックの外で呼ぶ。
    func append(_ data: Data, isStdout: Bool) {
      let forward = lock.withLock { () -> (() -> Void)? in
        lastActivity = Date()
        guard isStdout else {
          stderr += data
          guard let onStderrLine else { return nil }
          stderrRest += data
          let lines = takeStderrLines()
          return { lines.forEach(onStderrLine) }
        }
        guard streams else {
          stdout += data
          return nil
        }
        return onStdout.map { deliver in { deliver(data) } }
      }
      forward?()
    }

    /// 受け手を手放す。stderr に行になりきらない残りがあれば、最後の行として渡してから。
    func releaseOutput() {
      let rest = lock.withLock { () -> (String, (String) -> Void)? in
        onStdout = nil
        defer {
          onStderrLine = nil
          stderrRest = Data()
        }
        let text = String(bytes: stderrRest, encoding: .utf8) ?? ""
        guard let onStderrLine, !text.isEmpty else { return nil }
        return (text, onStderrLine)
      }
      if let (line, deliver) = rest { deliver(line) }
    }

    /// `stderrRest` から `\r` か `\n` で終わった行を取り出す（空行は捨てる）。ロックの中で呼ぶ。
    private func takeStderrLines() -> [String] {
      guard let last = stderrRest.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return [] }
      let complete = stderrRest[..<last]
      stderrRest = Data(stderrRest[stderrRest.index(after: last)...])
      return complete.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
        .map { String(bytes: $0, encoding: .utf8) ?? "" }
    }

    func cancel() {
      lock.withLock { cancelled = true }
      changed.signal()
    }

    func noteEOF() {
      lock.withLock { openPipes -= 1 }
      changed.signal()
    }

    func noteExit() {
      lock.withLock { if exitedAt == nil { exitedAt = Date() } }
      changed.signal()
    }

    func progress() -> RunProgress {
      lock.withLock {
        RunProgress(
          finished: exitedAt != nil && openPipes == 0, lastActivity: lastActivity,
          exitedAt: exitedAt, cancelled: cancelled)
      }
    }

    /// 状態が変わるか期限が来るまで眠る。
    func wait(until deadline: Date) {
      _ = changed.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
    }

    /// 状態が変わるまで眠る（期限なし）。
    func waitForChange() {
      changed.wait()
    }

    func collected() -> (stdout: Data, stderr: Data) { lock.withLock { (stdout, stderr) } }
  }
}
