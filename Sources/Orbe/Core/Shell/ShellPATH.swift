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

  /// キャッシュが皆無のとき、`value()` が実行中の probe を待つ上限。メインスレッドから呼ばれうる
  /// 経路（エディタ起動・resume 復元・agent 起動）を probe の上限いっぱい止めないための天井。
  /// 超えても probe は走り続け、着地すれば以後の呼び出しが正しい値を得る（同一セッションで自己修復する）。
  static let syncWaitBudget: TimeInterval = 2

  private let probe: () -> String?
  private let condition = NSCondition()
  /// 検査を通ったログインシェル由来の PATH。**floor は決して入れない**（起動直後のたまたま早い
  /// 呼び出しが、degrade した値をセッション全体へ固定してしまう）。
  private var loginPATH: String?
  private var probing = false
  private var probeSettled = false
  private var diskChecked = false

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
  func value() -> String {
    start()  // 誰も start() を呼んでいなくても probe は 1 回起きる（`main.swift` の呼びは頭出し）
    return Self.compose(login: resolvedLogin())
  }

  /// メモリ → ディスクキャッシュ → 実行中 probe の順に、検査済み login PATH を探す。
  /// どれも得られなければ nil（呼び出し側が既知パスだけの floor へ落ちる）。
  private func resolvedLogin() -> String? {
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
    let deadline = Date().addingTimeInterval(Self.syncWaitBudget)
    while probing, Date() < deadline { condition.wait(until: deadline) }
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
    for dir in fromShell + knownPaths where !dir.isEmpty {
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
    do { try proc.run() } catch { return nil }

    // 読みは別レーンへ逃がす。rc が起こした孫プロセスが stdout を握ったまま残ると EOF が来ないので、
    // 読み切りを待つ形にすると上限が上限として働かない。
    let box = OutputBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      box.store((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      proc.terminate()
      return nil
    }
    guard let data = box.take(), let out = String(data: data, encoding: .utf8) else { return nil }
    let line = out.split(separator: "\n").last { $0.hasPrefix("PATH=") }
    return line.map { String($0.dropFirst("PATH=".count)) }
  }

  /// 読み取りレーンと呼び出し元の間で stdout を受け渡す箱。
  private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func store(_ value: Data) { lock.withLock { data = value } }
    func take() -> Data? { lock.withLock { data } }
  }
}
