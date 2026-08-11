import Foundation

/// 子プロセスへ渡す PATH の唯一の出所。git・gh・エディタ・補完・agent が同じ 1 つの値を読む。
///
/// GUI から起動した Orbe のプロセス PATH はユーザーが導入したツールを含まないため、ユーザーの
/// デフォルトシェルを **login + interactive** で起こして PATH を取り出す。`.zshrc` は対話シェルしか
/// 読まないので `-i` を落とすと mise/asdf/nvm 等の shim を丸ごと取りこぼす（＝「起動には成功したが
/// PATH が不完全」という、失敗として検出できない degrade になる）。取り出しは `/usr/bin/env` の出力
/// から行うので、シェルの文法（fish の list 型 `$PATH` 等）に依存しない。
///
/// 得た PATH には既知の設置場所を必ず union する。シェル由来を先頭に置いたまま、欠けていたものだけを
/// 末尾へ足す——既知パスは「無いものを補う」役であって、ユーザーが意図した優先順を奪う役ではない。
///
/// probe はプロセスで 1 回だけ。結果は `app-state.json` にも温存し、次回起動はシェルを起こさずに済む。
final class ShellPATH {
  /// テストが seam を差し替えるため `var`。本番で置き換える者はいない。
  nonisolated(unsafe) static var shared = ShellPATH()

  /// union に足す既知の設置場所。この順で末尾へ追記する。
  static let knownPaths = [
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
  ]

  /// probe の硬い上限。rc がプロンプト描画や入力待ちで固まる病的ケースだけがここに届く
  /// （現実的に重い rc でも実測 1.5 秒前後）。短くしても得るものは無く、届けば既知パスだけに
  /// 落ちる＝解こうとしている degrade に戻るので、寛容側へ倒す。
  static let probeTimeout: TimeInterval = 10

  /// シェルの終了を観測してから、pipe に残った出力を汲み出すのに与える猶予。rc が起こした孫プロセスが
  /// 書き込み端を握ったままだと EOF は来ないので、汲み出しはここで有界にする。env の出力（十数 KB）は
  /// pipe バッファに収まり、シェルが終わる時点で読み手へ届き終えているため、この猶予が覆うのは
  /// 「読み手が最後の塊を配る」までの遅延だけ。孫を残さない実行がここを消費することはない。
  private static let drainGrace: TimeInterval = 0.5

  /// キャッシュが皆無のとき、`value(wait: .bounded)` が実行中の probe を待つ**プロセス全体の**予算。
  /// メインスレッドから呼ばれうる経路（エディタ起動・resume 復元・agent 起動）を止める合計時間の天井で、
  /// 呼び出しごとには配り直さない——起動復元は agent ペインの数だけ `value()` を呼ぶ。
  /// 超えても probe は走り続け、着地すれば以後の呼び出しが正しい値を得る（同一セッションで自己修復する）。
  static let syncWaitBudget: TimeInterval = 2

  /// probe の着地を待つ流儀。上限は `ShellPATH` の性質ではなく呼び出し側のレイテンシ要求なので、
  /// 呼び出し側が選ぶ。
  enum Wait {
    /// メインスレッドから呼ばれうる経路。`syncWaitBudget` を使い切ったら待たずに floor で答える。
    case bounded
    /// 既に背景で走っていて、待っても誰も困らない経路。probe の着地まで待つ。
    case settled
  }

  private let probe: () -> String?
  private let condition = NSCondition()
  /// 検査を通ったログインシェル由来の PATH。**floor は決して入れない**（起動直後のたまたま早い
  /// 呼び出しが、degrade した値をセッション全体へ固定してしまう）。
  private var loginPATH: String?
  private var probing = false
  private var probeSettled = false
  private var diskChecked = false
  /// `.bounded` の待ちが残している予算。待った分だけ減る。
  private var syncWaitRemaining = ShellPATH.syncWaitBudget

  init(probe: @escaping () -> String? = { ShellPATH.probeLoginShell() }) {
    self.probe = probe
  }

  /// 背景で probe を 1 回だけ開始する。冪等。起動最初期に呼んで、同期待ちが要る窓を潰す。
  func start() {
    condition.lock()
    let shouldRun = !probing && !probeSettled
    if shouldRun { probing = true }
    condition.unlock()
    guard shouldRun else { return }
    DispatchQueue.global(qos: .userInitiated).async { [self] in runProbe() }
  }

  /// 子プロセスへ渡す PATH。常に使える値を返す（既知パスだけになることはあっても空にはならない）。
  func value(wait: Wait = .bounded) -> String {
    start()  // 誰も start() を呼んでいなくても probe は 1 回起きる（`main.swift` の呼びは頭出し）
    return Self.compose(login: resolvedLogin(wait: wait))
  }

  /// メモリ → ディスクキャッシュ → 実行中 probe の順に、検査済み login PATH を探す。
  /// どれも得られなければ nil（呼び出し側が既知パスだけの floor へ落ちる）。
  private func resolvedLogin(wait: Wait) -> String? {
    condition.lock()
    defer { condition.unlock() }
    if let loginPATH { return loginPATH }
    if !diskChecked {
      diskChecked = true
      if let cached = Self.sanitize(AppStatePersistence.load()?.cachedShellPath) {
        loginPATH = cached
        return cached
      }
    }
    guard probing else { return loginPATH }
    switch wait {
    case .bounded:
      let started = Date()
      let deadline = started.addingTimeInterval(syncWaitRemaining)
      while probing, Date() < deadline { condition.wait(until: deadline) }
      syncWaitRemaining = max(0, syncWaitRemaining - Date().timeIntervalSince(started))
    case .settled:
      // probe 自身が `probeTimeout` で打ち切るので、着地待ちは有界。同じ上限をここにも置いて、
      // probe が戻らない実装事故に待ち手が巻き込まれないようにする。
      let deadline = Date().addingTimeInterval(Self.probeTimeout)
      while probing, Date() < deadline { condition.wait(until: deadline) }
    }
    return loginPATH
  }

  private func runProbe() {
    let resolved = Self.sanitize(probe())
    condition.lock()
    probing = false
    probeSettled = true
    if let resolved { loginPATH = resolved }
    condition.broadcast()
    condition.unlock()
    guard let resolved else { return }
    // 永続するのは union 前の login PATH。knownPaths は Orbe の版で変わるので、合成後を焼くと
    // 古い集合がディスクに固定される。読むときに union し直す。
    DispatchQueue.main.async {
      guard AppStatePersistence.load()?.cachedShellPath != resolved else { return }
      AppStatePersistence.update { $0.cachedShellPath = resolved }
    }
  }

  // MARK: - 純関数

  /// ログインシェル出力が PATH として読めるかの構造検査。読めない値は捨て、不正な要素だけを落とす。
  /// 実在するディレクトリかは見ない（後から作られる先を落とさないため・検査を環境非依存に保つため）。
  static func sanitize(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // 改行や NUL が残っているのは、env の出力解析が PATH 行以外まで掴んだ＝壊れた値。
    guard !trimmed.contains("\n"), !trimmed.contains("\r"), !trimmed.contains("\0") else {
      return nil
    }
    let dirs = trimmed.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    return dirs.isEmpty ? nil : dirs.joined(separator: ":")
  }

  /// 検査済み login PATH と既知パスの union。シェル由来が先、欠けていた既知パスを末尾へ追記する。
  /// 重複は初出だけ残す。`login` が nil なら既知パスだけ（floor）。
  static func compose(login: String?) -> String {
    let fromShell = login.map { $0.split(separator: ":").map(String.init) } ?? []
    var seen = Set<String>()
    var dirs: [String] = []
    for dir in fromShell + knownPaths {
      guard seen.insert(dir).inserted else { continue }
      dirs.append(dir)
    }
    return dirs.joined(separator: ":")
  }

  // MARK: - probe

  /// `$SHELL` を login + interactive で起こし、`/usr/bin/env` の出力から PATH を抜く。
  /// rc が `PATH=` を echo するノイズと混ざりうるので、採るのは**最後の** `PATH=` 行。
  /// 終了ステータスは見ない（対話シェルは rc のエラーで非 0 になりうるが PATH は正しく出ている）。
  static func probeLoginShell(
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
    timeout: TimeInterval = probeTimeout
  ) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-l", "-i", "-c", "/usr/bin/env"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardInput = FileHandle.nullDevice  // rc の入力待ちで固まらせない
    proc.standardError = FileHandle.nullDevice  // rc のノイズは捨てる

    let state = ProbeState()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        state.noteEOF()
      } else {
        state.append(data)
      }
    }
    proc.terminationHandler = { _ in state.noteExit() }
    do { try proc.run() } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }
    // 打ち切った後は EOF が来ないことがあるので、返る前に必ず読み手を外す（レーンも fd も残さない）。
    defer { pipe.fileHandleForReading.readabilityHandler = nil }

    awaitProbe(proc, state: state, timeout: timeout)
    // 不正バイトは U+FFFD へ落として読み進める。PATH と無関係な環境変数の 1 バイトで probe 全体を
    // 捨てると、失敗として検出できないまま floor に固定される。lint は「デコードの失敗を握り潰すな」と
    // 失敗しうる initializer を求めるが、ここで欲しいのは全か無かの成否ではなく、読めた分の PATH 行。
    // swiftlint:disable:next optional_data_string_conversion
    let out = String(decoding: state.collected(), as: UTF8.self)
    let line = out.split(separator: "\n").last { $0.hasPrefix("PATH=") }
    return line.map { String($0.dropFirst("PATH=".count)) }
  }

  /// シェルの終了と出力の汲み出しを待つ。**終わったことを決めるのはシェルの終了**であって EOF ではない
  /// ——EOF が来るかは pipe の書き込み端を握る第三者（rc が背景に残したプロセス）次第で、読み切りを
  /// 待つ形にすると、正しく取れた PATH を捨てて上限まで張り付く。終了後に残るのはバッファの汲み出し
  /// だけなので `drainGrace` で有界にする。`timeout` は「シェルが終わらない」ケース専用の硬い上限。
  private static func awaitProbe(_ proc: Process, state: ProbeState, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let progress = state.progress()
      if progress.finished { return }
      if let exitedAt = progress.exitedAt {
        let drain = min(exitedAt.addingTimeInterval(drainGrace), deadline)
        guard Date() < drain else { return }
        state.wait(until: drain)
        continue
      }
      guard Date() < deadline else { break }
      state.wait(until: deadline)
    }
    // 上限に達した＝シェルが終わらない。SIGTERM で切り、集まった分を持って返る
    // （PATH を出した後で固まった rc なら、その出力は読み手が既に届けている）。
    proc.terminate()
  }

  /// probe 1 回ぶんの共有状態。読み取りレーン・`terminationHandler`・待ち手が同時に触るので、
  /// 1 本のロックで束ねる。起こすのは状態が変わったとき（EOF・シェルの終了）だけで、出力の到着では
  /// 起こさない——待ち手は期限まで眠っていればよい。
  private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var output = Data()
    private var eof = false
    private var exitedAt: Date?

    func append(_ data: Data) { lock.withLock { output += data } }

    func noteEOF() {
      lock.withLock { eof = true }
      changed.signal()
    }

    func noteExit() {
      lock.withLock { if exitedAt == nil { exitedAt = Date() } }
      changed.signal()
    }

    /// 待ち手が 1 回の観測で見る状態。ばらばらに読むと組み合わせが食い違う。
    func progress() -> (finished: Bool, exitedAt: Date?) {
      lock.withLock { (eof && exitedAt != nil, exitedAt) }
    }

    /// 状態が変わるか期限が来るまで眠る。
    func wait(until deadline: Date) {
      _ = changed.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
    }

    func collected() -> Data { lock.withLock { output } }
  }
}
