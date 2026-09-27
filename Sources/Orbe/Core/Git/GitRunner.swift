import Foundation

/// git CLI の実行基盤。GUI アプリの貧弱な環境変数でも hooks・署名がユーザーの
/// シェル環境と同等に動くよう、`ShellPATH` の PATH を全呼び出しへ引き継ぐ。
///
/// 排他は**インスタンス内で閉じる**（キューがインスタンスの持ち物のため）。同じリポジトリを
/// 別インスタンスから書くと直列化が効かないので、**本番は必ず `shared` を通す**——`GitRepo` は
/// runner を既定引数 `.shared` で受けており、明示的に別インスタンスを渡すのはテストだけ。
final class GitRunner {
  struct Output {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// 終わり方。`status` の値で見分けさせない（`-1` は起動失敗にも打ち切りにも使う）。
    let ending: Ending
    /// git の終了を観測できたか。打ち切った後に「作りかけの成果物が残っているか」で成否を
    /// 読み替える呼び出し側は、その判定が意味を持つ前提としてこれを見る。
    let exited: Bool

    var timedOut: Bool { ending == .timedOut }
    var stdoutText: String { String(bytes: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(bytes: stderr, encoding: .utf8) ?? "" }
    var isSuccess: Bool { status == 0 }
  }

  /// 実行の終わり方。
  enum Ending: Equatable {
    /// git が自分で終わった（成否は `status`）。
    case completed
    /// 無出力が続いて打ち切った。
    case timedOut
    /// 止めた（`Stream.cancel`）。
    case cancelled
    /// 起動できなかった（`stderr` にその理由）。
    case launchFailed
  }

  /// git 実行の並行レーン。「何と競合するか」で選ぶ。
  enum Lane {
    /// 読み取り。共有 queue で並行に走る。
    case read
    /// 同一リポジトリの ref・作業ツリーを書く操作。共有 queue の barrier で単独直列化する
    /// （git のロックは待たずに即 fatal するため、順番はアプリ側で作る）。
    case exclusive
    /// 共有チェックアウトと領域が交わらない操作、または結果が古くても取り直せる観測（status・index の
    /// 読み。監視が取り直す）。独立レーンで走らせ、barrier チェーンに載せない。
    case independent
  }

  static let shared = GitRunner()

  /// 読み取り系の同時実行を許す。書き込み系は barrier で排他直列化する
  /// （concurrent キュー上の read-write lock）。
  private let queue = DispatchQueue(
    label: "dev.orbe.git", qos: .userInitiated, attributes: .concurrent)
  /// 共有 `queue` の read-write lock から切り離した独立レーン（`.independent`）。
  /// 所要時間が不定の操作をここで走らせ、共有 queue の barrier チェーンに載せない。
  /// GCD barrier は「submit 済みの全ブロックの完了」を待つため、共有 queue で長い操作を
  /// 走らせると（`.read` でも）後続の `.exclusive` がその完了を待つ。
  /// 独立 queue に逃がすことで、barrier が長い操作を待たなくなる。
  private let independentQueue = DispatchQueue(
    label: "dev.orbe.git.independent", qos: .userInitiated, attributes: .concurrent)
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
    case .independent: independentQueue.async(execute: work)
    }
  }

  /// 同期実行。呼び出し元スレッドでブロックする（背景キュー・テスト用）。
  /// 1 バイトも出力が無いまま `idleTimeout` が過ぎたら SIGTERM で打ち切り、`timedOut` を立てて返る。
  func runSync(_ args: [String], cwd: String, stdin: Data? = nil) -> Output {
    execute(
      args, cwd: cwd, stdin: stdin, environment: [:], state: RunState(idleTimeout: idleTimeout))
  }

  /// 流しながら読む実行（独立レーン）。stdout は届いた塊ごとに `onOutput`（裏のスレッド、届いた順）へ渡し、溜めない。
  /// 終わったら `completion`（裏のスレッド。`stdout` は空）。`environment` は共通の環境に足す変数。返る手の `cancel` で
  /// SIGTERM で止める（止めた後の `completion` も届く）。EOF の猶予は `runSync` と同じだが、無出力では打ち切らない——
  /// 一致の無い間は何も出さない grep のような実行を黙って切らないため、寿命は止める側が持つ。`onOutput` は終わったら
  /// 手放す（呼び出し側が手を持ち、閉包が呼び出し側を掴んでも輪にならない）。
  func stream(
    _ args: [String], cwd: String, environment: [String: String] = [:],
    onOutput: @escaping (Data) -> Void, completion: @escaping (Output) -> Void
  ) -> Stream {
    let state = RunState(idleTimeout: nil, onStdout: onOutput)
    independentQueue.async {
      completion(self.execute(args, cwd: cwd, stdin: nil, environment: environment, state: state))
    }
    return Stream(state: state)
  }

  /// 流しながら読む実行の手。
  final class Stream {
    private let state: RunState

    fileprivate init(state: RunState) {
      self.state = state
    }

    /// 止める（SIGTERM）。何度呼んでもよい。
    func cancel() {
      state.cancel()
    }
  }

  private func execute(
    _ args: [String], cwd: String, stdin: Data?, environment extra: [String: String],
    state: RunState
  ) -> Output {
    defer { state.releaseOutput() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    process.environment = Self.environment().merging(extra) { _, added in added }

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let input: Pipe? = stdin != nil ? Pipe() : nil
    if let input { process.standardInput = input }

    collect(out, into: state, isStdout: true)
    collect(err, into: state, isStdout: false)
    process.terminationHandler = { _ in state.noteExit() }

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
    if let input, let stdin {
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
  /// 無出力が実行の `idleTimeout`（nil なら打ち切らない）続くか、止められたら（`Stream.cancel`）SIGTERM で切る。EOF 待ちは
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
    /// 止められた（`Stream.cancel`）。
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

    init(idleTimeout: TimeInterval?, onStdout: ((Data) -> Void)? = nil) {
      self.idleTimeout = idleTimeout
      streams = onStdout != nil
      self.onStdout = onStdout
    }

    /// プロセスが終了済みか（`terminationStatus` を読んでよいか）。
    var hasExited: Bool { lock.withLock { exitedAt != nil } }

    /// 読み手（pipe ごとに 1 本、到着順に直列）から呼ばれる。`onStdout` はロックの外で呼ぶ。
    func append(_ data: Data, isStdout: Bool) {
      let forward = lock.withLock { () -> ((Data) -> Void)? in
        lastActivity = Date()
        guard isStdout else {
          stderr += data
          return nil
        }
        guard streams else {
          stdout += data
          return nil
        }
        return onStdout
      }
      forward?(data)
    }

    func releaseOutput() {
      lock.withLock { onStdout = nil }
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

  /// 呼び出し共通の環境変数。PATH は毎回 `ShellPATH` から取る（プロセスの事実を焼き付けない）。
  private static func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ShellPATH.shared.value()
    env["GIT_TERMINAL_PROMPT"] = "0"  // 資格情報等の対話でハングさせない
    // pathspec の解釈を環境に変えさせない。LITERAL は `:(literal)` ごと literal にして黙って 0 件にし、
    // ICASE は `:(literal)` を貫通して別の綴りのパスに当てる。GLOB / NOGLOB は明示 magic には効かないが、
    // 両方立っていると pathspec を取る git が丸ごと fatal になる。
    for key in [
      "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
    ] {
      env.removeValue(forKey: key)
    }
    return env
  }
}
