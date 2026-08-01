import Foundation
import JavaScriptCore

/// ドロップダウン補完の 1 候補（表示値・説明・挿入値）。
/// `insertValue` は figspec の挿入値が表示名と異なる場合（`--flag=`・パス接頭辞付き等）に使う。
struct CompletionChoice: Equatable {
  let value: String
  let description: String
  let insertValue: String?
  /// fig の suggestion type（subcommand/option/file/folder/arg/…）。表示のグルーピング・グリフ導出に使う。
  /// generator 出力など type を持たない候補は nil。
  let type: String?
}

/// engine が返す候補集合と、accept で置換する現在トークンの文字長。
struct CompletionResult {
  let choices: [CompletionChoice]
  /// 現在トークン（activeToken）の文字数。accept は `cursor-replaceLength ..< cursor` を置換する。
  let replaceLength: Int
}

/// JavaScriptCore に埋め込んだ spec エンジン（inshellisense runtime 由来 + curated withfig spec）。
/// `app/completion-engine.js`（prebuilt バンドル）を専用 serial queue 上の JSContext で駆動する。
/// JS は解析・spec 走査・postProcess を担い、ファイルアクセスと generator のシェル実行は
/// Swift が注入する native 関数に委ねる（`__orbe_access` / `__orbe_readdir` は `FileManager` 直、
/// `__orbe_exec` は cwd 付き `zsh -c`・login PATH・2s 上限・stdout のみ）。
/// AppKit/libghostty 非依存なので main 規律の外（結果のみ main へ hop）。
final class CompletionEngine {
  nonisolated(unsafe) static let shared = CompletionEngine()

  private let queue = DispatchQueue(label: "dev.orbe.completion.js")
  private var context: JSContext?
  private var ready = false
  private var failed = false

  /// generator/template の同一 exec を短時間キャッシュし、トークン編集中の毎キー再実行を避ける。
  /// queue 上でのみ触る。
  private var execCache: [String: (value: String, expires: Date)] = [:]
  private let execTTL: TimeInterval = 3
  private let execTimeout: TimeInterval = 2

  /// login シェルの PATH（GUI の貧弱な PATH では brew 導入ツールが見えないため・一度だけ解決）。
  private lazy var loginPATH: String? = GitRunner.loginShellPATH()

  /// バンドル無し（`swift run`）では nil。存在時のみ engine をロードできる。
  static var bundlePath: String? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let path = resources.appendingPathComponent("completion-engine.js").path
    return FileManager.default.isReadableFile(atPath: path) ? path : nil
  }

  /// 候補を算出して main へ返す。バンドル未ロード/失敗時は空（クラッシュしない）。
  /// `buffer` はカーソル左側の編集テキスト、`cursor` は buffer 全体でのコードポイント（scalar）オフセット
  /// （zsh の $CURSOR・engine JS の `[...token].length` と単位を揃える。書記素単位だと NFD パスでずれる）。
  func suggestions(
    buffer: String, cursor: Int, cwd: String, _ done: @escaping (CompletionResult) -> Void
  ) {
    let chars = Array(buffer.unicodeScalars)
    let cur = max(0, min(cursor, chars.count))
    let leftText = String(String.UnicodeScalarView(chars[0..<cur]))
    queue.async { [weak self] in
      guard let self else { return }
      let result = self.compute(leftText: leftText, cwd: cwd)
      DispatchQueue.main.async { done(result) }
    }
  }

  /// queue 上で JSContext を駆動して候補を得る。
  private func compute(leftText: String, cwd: String) -> CompletionResult {
    guard let ctx = ensureContext() else { return CompletionResult(choices: [], replaceLength: 0) }

    ctx.setObject(leftText, forKeyedSubscript: "__orbe_buffer" as NSString)
    ctx.setObject(cwd, forKeyedSubscript: "__orbe_cwd" as NSString)
    ctx.evaluateScript("__orbe_run()")
    // complete() の await は同期 native（__orbe_exec）に解決するため、
    // evaluateScript 後の microtask drain で __orbe_result が確定する（同期化方式）。
    guard let value = ctx.objectForKeyedSubscript("__orbe_result"), !value.isNull,
      let json = value.toString()?.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    else { return CompletionResult(choices: [], replaceLength: 0) }

    let replaceLength = obj["replaceLength"] as? Int ?? 0
    let rawChoices = obj["suggestions"] as? [[String: Any]] ?? []
    let choices = rawChoices.compactMap { item -> CompletionChoice? in
      guard let value = item["value"] as? String ?? item["name"] as? String else { return nil }
      return CompletionChoice(
        value: value,
        description: item["description"] as? String ?? "",
        insertValue: item["insertValue"] as? String,
        type: item["type"] as? String)
    }
    return CompletionResult(choices: choices, replaceLength: replaceLength)
  }

  /// JSContext を lazy 初期化（プロセスに 1 つ共有・spec は初回 load）。queue 上で呼ぶ。
  private func ensureContext() -> JSContext? {
    if ready { return context }
    if failed { return nil }
    guard let path = Self.bundlePath,
      let source = try? String(contentsOfFile: path, encoding: .utf8)
    else {
      failed = true
      return nil
    }
    guard let ctx = JSContext() else {
      failed = true
      return nil
    }
    ctx.exceptionHandler = { _, _ in }
    installNativeBridge(ctx)
    ctx.evaluateScript(source)
    if ctx.objectForKeyedSubscript("__orbe_run")?.isUndefined ?? true {
      failed = true
      return nil
    }
    context = ctx
    ready = true
    return ctx
  }

  /// generator/template が叩く native 関数を JSContext へ install する。
  ///
  /// ディレクトリの到達確認と列挙は `FileManager` で直に行う。ここをシェルに委ねると、
  /// ディレクトリ名という**外部から与えられる文字列**を毎打鍵でコマンド行へ埋め込むことになり、
  /// 引用を一段でも誤れば `$(…)` が展開されて任意コード実行になる。そもそもシェルを介す必要が
  /// ないので、経路ごと断つ（上流 inshellisense も `fs.access` / `fs.readdir` を使う）。
  /// `__orbe_exec` が残るのは figspec の generator が任意コマンドを走らせる仕様のときだけ。
  private func installNativeBridge(_ ctx: JSContext) {
    let exec: @convention(block) (String, String) -> String = { [weak self] command, cwd in
      self?.runShell(command, cwd: cwd) ?? ""
    }
    ctx.setObject(exec, forKeyedSubscript: "__orbe_exec" as NSString)

    // 読めるディレクトリなら true。シンボリックリンクは辿った先で判定する。
    let access: @convention(block) (String) -> Bool = { path in
      let fm = FileManager.default
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
      return fm.isReadableFile(atPath: path)
    }
    ctx.setObject(access, forKeyedSubscript: "__orbe_access" as NSString)

    // `dir` 直下を列挙する（隠しファイルも含み `.`/`..` は含まない）。
    // 壊れた symlink は `fileExists` が false を返すためファイル扱いになる。
    let readdir: @convention(block) (String) -> [[String: Any]] = { dir in
      let fm = FileManager.default
      guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
      return names.map { name in
        var isDir: ObjCBool = false
        let full = (dir as NSString).appendingPathComponent(name)
        let exists = fm.fileExists(atPath: full, isDirectory: &isDir)
        return ["name": name, "isDirectory": exists && isDir.boolValue]
      }
    }
    ctx.setObject(readdir, forKeyedSubscript: "__orbe_readdir" as NSString)

    ctx.setObject(NSHomeDirectory(), forKeyedSubscript: "__orbe_home" as NSString)
  }

  /// cwd 付き `zsh -c` を同期実行し stdout を返す（login PATH・stdin 無し・stdout のみ・2s 上限）。
  /// 失敗/タイムアウトは空文字列。queue 上で呼ばれ block してよい（main ではない）。
  ///
  /// 子は `posix_spawn` で自分のプロセスグループのリーダーとして起こす。タイムアウト時は
  /// `terminate()`（=子への SIGTERM）では孫（generator が起こす node 等）が pipe を握ったまま
  /// 生き残り readToEnd が EOF を得られず永久ハング→補完 queue が恒久停止しうる。そこで
  /// `kill(-pid, SIGKILL)` でグループごと落とし、書き手を全滅させて必ず EOF を起こす。
  private func runShell(_ command: String, cwd: String) -> String {
    let key = cwd + "\u{0}" + command
    let now = Date()
    if let hit = execCache[key], now < hit.expires { return hit.value }
    pruneExecCache(now: now)

    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return cache(key, "") }
    let readFD = fds[0]
    let writeFD = fds[1]

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, writeFD, 1)  // stdout → pipe
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)  // stdin 無し
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)  // stderr 捨てる
    posix_spawn_file_actions_addclose(&actions, readFD)  // 子は pipe 生 fd を持たない
    posix_spawn_file_actions_addclose(&actions, writeFD)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
      posix_spawn_file_actions_addchdir_np(&actions, cwd)
    }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)  // 0 = 子の pid を pgid に（グループのリーダー化）

    var env = ProcessInfo.processInfo.environment
    if let loginPATH { env["PATH"] = loginPATH }
    let cArgs = ["/bin/zsh", "-c", command].map { $0.withCString(strdup) } + [nil]
    let cEnv = env.map { "\($0.key)=\($0.value)".withCString(strdup) } + [nil]

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, "/bin/zsh", &actions, &attr, cArgs, cEnv)

    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    cArgs.forEach { free($0) }
    cEnv.forEach { free($0) }
    close(writeFD)  // 親は書かない。閉じないと子の EOF が起きない
    guard rc == 0 else {
      close(readFD)
      return cache(key, "")
    }

    // stdout を別 queue で並行 drain する。pipe を読まずに終了を待つと、出力が pipe バッファ
    // （数十 KB）を超えた generator が write(2) でブロックして終わらず、2s を浪費して空になる
    // （node_modules 等の大きな dir のパス補完で現実に起きる）。drain しつつ 2s で打ち切る。
    let box = DataBox()
    let sem = DispatchSemaphore(value: 0)
    let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
    DispatchQueue.global(qos: .userInitiated).async {
      box.data = (try? handle.readToEnd()) ?? Data()
      sem.signal()
    }
    if sem.wait(timeout: .now() + execTimeout) == .timedOut {
      kill(-pid, SIGKILL)  // プロセスグループごと（孫まで）殺し、書き手を全滅させて EOF を起こす
      sem.wait()  // 読み取り完了を待ち FileHandle を漏らさない
      _ = waitpid(pid, nil, 0)  // reap（ゾンビ防止）
      return cache(key, "")  // タイムアウトも cache し同一トークン編集中の毎キー再ハングを防ぐ
    }
    _ = waitpid(pid, nil, 0)
    return cache(key, String(data: box.data, encoding: .utf8) ?? "")
  }

  /// 結果を execCache へ格納して返す（失敗/タイムアウトの空も含めて格納する）。
  private func cache(_ key: String, _ value: String) -> String {
    execCache[key] = (value, Date().addingTimeInterval(execTTL))
    return value
  }

  /// 失効エントリを掃除し execCache の単調増加を防ぐ（cache miss 時に一度だけ走る・queue 上）。
  private func pruneExecCache(now: Date) {
    execCache = execCache.filter { now < $0.value.expires }
  }
}

/// 別 queue で読んだ stdout を runShell へ受け渡す箱（v5 言語モード・queue 越え用）。
private final class DataBox: @unchecked Sendable {
  var data = Data()
}
