import Foundation

/// 裏の 1 回。子を専用のプロセスグループで起こし、経過時間・無出力・出力量の上限で打ち切り、グループごと片付けてから返る。
///
/// 実行の寿命＝グループの寿命。リーダーの終了は回収せずに観測し（`waitid` の `WNOWAIT`）、グループへ SIGTERM を送って
/// 背景に残った孫を片付けてから、最後にリーダーを回収する。回収してから `killpg` すると、空いた pgid が再利用されたときに
/// 無関係なグループへシグナルが届くため、この順序は崩さない。打ち切り・停止は SIGTERM → 猶予 → SIGKILL。
///
/// 出力の EOF は無期限には待たない。グループから逃げた孫が pipe の書き込み端を握っていても、リーダーの終了から
/// `drainGrace` で返る。
final class BackgroundProcess {
  /// SIGTERM から SIGKILL までの猶予。
  static let killGrace: TimeInterval = 1
  /// リーダーの終了後、pipe に残った出力を汲み出す猶予。
  static let drainGrace: TimeInterval = 1

  private let spec: Spec
  private let queue = DispatchQueue(label: "dev.orbe.background.process")
  private let done = DispatchSemaphore(value: 0)

  private var pid: pid_t = 0
  private var launched = false
  private var stopRequested = false
  private var leaderExited = false
  private var finished = false
  private var ending: Ending?
  private var stopReason: Ending?

  private var stdoutCaptured = Captured()
  private var stderrCaptured = Captured()
  private var lines: LineSplitter?
  private var stdoutEOF = false
  private var stderrEOF = false

  private var startedAt = DispatchTime.now()
  private var lastActivity = DispatchTime.now()
  private var limitTimer: DispatchSourceTimer?
  private var sources: [DispatchSourceProtocol] = []

  init(_ spec: Spec) {
    self.spec = spec
    if case .lines(let maxLength, _) = spec.stdout { lines = LineSplitter(maxLength: maxLength) }
  }

  /// 実行して終わりまで待つ。呼び出し元スレッドを塞ぐので、裏のスレッドから呼ぶ。1 インスタンスにつき 1 回だけ。
  func run() -> Outcome {
    let started = queue.sync { () -> Bool in
      if stopRequested {
        ending = .stopped
        return false
      }
      if let errno = launch() {
        ending = .launchFailed(errno)
        return false
      }
      return true
    }
    if started { done.wait() }
    return queue.sync {
      Outcome(
        ending: ending ?? .stopped, stdout: stdoutCaptured, stderr: stderrCaptured,
        droppedLines: lines?.dropped ?? 0)
    }
  }

  /// 止める（SIGTERM → 猶予 → SIGKILL）。どのスレッドからでも、何度呼んでもよい。起こす前なら起こさない。
  func stop() {
    queue.async { [self] in
      guard launched else {
        stopRequested = true
        return
      }
      terminate(.stopped)
    }
  }

  // MARK: - 起こす

  /// 子を起こし、観測を仕掛ける。失敗したら errno を返す。`queue` の上で呼ぶ。
  private func launch() -> Int32? {
    guard let out = Self.makePipe() else { return errno }
    guard let err = Self.makePipe() else {
      let failure = errno
      Self.close(out)
      return failure
    }
    let input = spec.stdin == nil ? nil : Self.makePipe()
    if spec.stdin != nil, input == nil {
      let failure = errno
      Self.close(out, err)
      return failure
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let input {
      posix_spawn_file_actions_adddup2(&actions, input.read, 0)
    } else {
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&actions, out.write, 1)
    posix_spawn_file_actions_adddup2(&actions, err.write, 2)
    posix_spawn_file_actions_addchdir_np(&actions, spec.directory)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    Self.configure(&attr)

    let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
    let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }
    var child: pid_t = 0
    let rc = posix_spawn(&child, spec.executable, &actions, &attr, argv, envp)
    Darwin.close(out.write)
    Darwin.close(err.write)
    if let input { Darwin.close(input.read) }
    guard rc == 0 else {
      Darwin.close(out.read)
      Darwin.close(err.read)
      if let input { Darwin.close(input.write) }
      return rc
    }

    pid = child
    launched = true
    startedAt = .now()
    lastActivity = startedAt
    watchExit()
    read(out.read, isStdout: true)
    read(err.read, isStdout: false)
    if let input, let data = spec.stdin { write(data, to: input.write) }
    armLimitTimer()
    return nil
  }

  /// 子は専用のグループで起こし、fd を漏らさず、Orbe から継ぐシグナルの扱いを素に戻す。
  private static func configure(_ attr: inout posix_spawnattr_t?) {
    // CLOEXEC_DEFAULT: Orbe が持つソケット・pty・他の実行の pipe を子に漏らさない（file actions で dup2 した 0〜2 だけが渡る）。
    posix_spawnattr_setflags(
      &attr,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
          | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attr, 0)
    // Orbe は SIGPIPE を無視している。無視は exec を越えて継がれるので、子では既定に戻す。
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGPIPE)
    posix_spawnattr_setsigdefault(&attr, &defaults)
    // シグナルマスクも exec を越えて継がれる。起こすのは GCD のワーカーで、そのマスクを継ぐと SIGTERM が届かない。
    var unblocked = sigset_t()
    sigemptyset(&unblocked)
    posix_spawnattr_setsigmask(&attr, &unblocked)
  }

  private static func makePipe() -> (read: Int32, write: Int32)? {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }
    // 他の起こし口（CLOEXEC_DEFAULT を付けないもの）が同時に起こした子へ継がれると、EOF が来なくなる。
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
  }

  private static func close(_ pipes: (read: Int32, write: Int32)...) {
    for pipe in pipes {
      Darwin.close(pipe.read)
      Darwin.close(pipe.write)
    }
  }

  /// リーダーの終了を、回収せずに待つ。
  private func watchExit() {
    let child = pid
    DispatchQueue.global(qos: .utility).async { [self] in
      var info = siginfo_t()
      while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
      queue.async { self.noteLeaderExit() }
    }
  }

  private func read(_ fd: Int32, isStdout: Bool) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [unowned self, unowned source] in
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
          lastActivity = .now()
          receive(Data(buffer[0..<count]), isStdout: isStdout)
          continue
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN { return }
        source.cancel()
        noteEOF(isStdout: isStdout)
        return
      }
    }
    source.setCancelHandler { Darwin.close(fd) }
    sources.append(source)
    source.resume()
  }

  private func write(_ data: Data, to fd: Int32) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    var remaining = data
    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [unowned source] in
      while !remaining.isEmpty {
        let count = remaining.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if count > 0 {
          remaining.removeFirst(count)
          continue
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN { return }
        break
      }
      source.cancel()
    }
    source.setCancelHandler { Darwin.close(fd) }
    sources.append(source)
    source.resume()
  }

  // MARK: - 出力

  private func receive(_ data: Data, isStdout: Bool) {
    guard isStdout else {
      capture(data, into: &stderrCaptured, spec.stderr)
      return
    }
    switch spec.stdout {
    case .collect(let rule): capture(data, into: &stdoutCaptured, rule)
    case .lines: deliverLines { $0.feed(data, onLine: $1) }
    }
  }

  /// 行を受け手へ渡し、受け手が終わり方を返したらそれで打ち切る。
  private func deliverLines(_ body: (inout LineSplitter, (Data) -> Bool) -> Bool) {
    guard case .lines(_, let onLine) = spec.stdout, lines != nil else { return }
    var cut: Ending?
    let proceeds = body(&lines!) { line in
      cut = onLine(line)
      return cut == nil
    }
    if !proceeds, let cut { terminate(cut) }
  }

  private func capture(_ data: Data, into captured: inout Captured, _ rule: Capture) {
    guard !captured.truncated else { return }
    let room = rule.limit - captured.data.count
    guard data.count > room else {
      captured.data.append(data)
      return
    }
    captured.data.append(data.prefix(max(0, room)))
    captured.truncated = true
    if rule.overflowStops { terminate(.limited(.output)) }
  }

  private func noteEOF(isStdout: Bool) {
    if isStdout {
      stdoutEOF = true
      deliverLines { $0.finish(onLine: $1) }
    } else {
      stderrEOF = true
    }
    if leaderExited, stdoutEOF, stderrEOF { finish() }
  }

  // MARK: - 上限と停止

  private func armLimitTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [unowned self] in checkLimits() }
    limitTimer = timer
    timer.schedule(deadline: nextLimitDeadline())
    timer.resume()
  }

  private func nextLimitDeadline() -> DispatchTime {
    min(startedAt + spec.elapsedLimit, lastActivity + spec.idleLimit)
  }

  /// 期限で目覚めたら測り直す。出力が来ていれば無出力の期限は延びている。
  private func checkLimits() {
    let now = DispatchTime.now()
    if now >= startedAt + spec.elapsedLimit {
      terminate(.limited(.elapsed))
    } else if now >= lastActivity + spec.idleLimit {
      terminate(.limited(.idle))
    } else {
      limitTimer?.schedule(deadline: nextLimitDeadline())
    }
  }

  private func terminate(_ reason: Ending) {
    guard !finished, stopReason == nil else { return }
    stopReason = reason
    limitTimer?.cancel()
    killpg(pid, SIGTERM)
    queue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
      if !finished, !leaderExited { killpg(pid, SIGKILL) }
    }
  }

  private func noteLeaderExit() {
    leaderExited = true
    limitTimer?.cancel()
    // 背景に残った孫を片付ける。リーダーは未回収なので、pgid は他へ渡っていない。
    if stopReason == nil { killpg(pid, SIGTERM) }
    if stdoutEOF, stderrEOF {
      finish()
      return
    }
    queue.asyncAfter(deadline: .now() + Self.drainGrace) { [self] in finish() }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    killpg(pid, SIGKILL)
    for source in sources where !source.isCancelled { source.cancel() }
    var status: Int32 = 0
    let reaped = waitpid(pid, &status, 0) == pid
    ending = stopReason ?? (reaped ? Self.ending(fromWaitStatus: status) : .exited(-1))
    done.signal()
  }

  static func ending(fromWaitStatus status: Int32) -> Ending {
    let signal = status & 0x7f
    return signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
  }
}

extension BackgroundProcess {
  struct Spec {
    var executable: String
    /// argv[1...]。
    var arguments: [String]
    var environment: [String: String]
    var directory: String
    var stdin: Data?
    var elapsedLimit: TimeInterval
    var idleLimit: TimeInterval
    var stdout: Stdout
    var stderr: Capture
  }

  /// 標準出力の扱い。
  enum Stdout {
    /// 上限まで貯める。
    case collect(Capture)
    /// 1 行ずつ渡し、貯めない。`maxLength` を超えた行は渡さずに捨て、`Outcome.droppedLines` に数える。
    /// `onLine` が終わり方（出力量の上限・止めた）を返したら、それで打ち切る。nil なら続ける。呼ばれるのは裏の直列キュー。
    case lines(maxLength: Int, onLine: (Data) -> Ending?)
  }

  /// 貯める出力の上限。`overflowStops` が偽なら、超えた分を捨てて走らせ続ける。
  struct Capture {
    var limit: Int
    var overflowStops: Bool
  }

  struct Captured: Equatable {
    var data = Data()
    var truncated = false
  }

  enum Limit: Equatable, CaseIterable {
    case elapsed
    case idle
    case output
  }

  enum Ending: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case limited(Limit)
    case stopped
    /// `posix_spawn` の失敗（errno）。
    case launchFailed(Int32)
  }

  struct Outcome {
    let ending: Ending
    let stdout: Captured
    let stderr: Captured
    let droppedLines: Int
  }
}
