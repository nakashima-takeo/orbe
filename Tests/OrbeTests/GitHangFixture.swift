import Foundation

@testable import Orbe

/// 「返らない git」をネットワーク無し・本番コードへのテスト専用フック無しで作る一時リポジトリ。
///
/// 手口は 1 つだけ: sentinel ファイルが現れるまで返らない sh を、git が起動する実行体として踏ませる
/// ——hook（`pre-commit` は `commit` を、`post-checkout` は `worktree add` を止める）・`ext::` transport
/// （clone は hook を持たないので止める手段がこれしかない）・clean フィルタなど。待ちは `release()` でも
/// `cleanup()`（fixture ディレクトリごと消す）でも解けるので、tearDown が確実に片付く。スクリプト側にも
/// 60 秒の上限を持たせてあり、どちらも呼び損ねてもテストプロセスに居座らない。
///
/// 実行体の形（シバンと priming のガード行）は `write(body:to:)` が決め、置いた実行体は返る時点で
/// 初回 exec の Gatekeeper 評価を払い終えている。呼び手が持つのは本体（`*Body`）だけでよく、
/// 短いアイドル上限で測るテストがその評価コストを踏まない。
///
/// レイアウト（すべて 1 つの一時ディレクトリの下＝`cleanup()` の 1 回で消える）:
/// ```
/// <tmp>/orbe-githang-<uuid>/
///   repo/      … git リポジトリ（commit 1 本入り）
///   sentinel   … これが現れると待ちが解ける
///   started    … 待ちに入ったことの目印（テストは「本当にハングしている」状態から測れる）
///   wt/        … worktree の作成先
/// ```
final class GitHangFixture {
  /// 一時ディレクトリの根。この 1 つを消せば全部消える。
  let dir: URL

  init() throws {
    dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("orbe-githang-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: dir.appendingPathComponent("repo"), withIntermediateDirectories: true)
    try makeRepository()
  }

  // MARK: - パス

  /// リポジトリ root。
  var root: String { dir.appendingPathComponent("repo").path }
  /// 待ちを解く目印。
  var sentinel: String { dir.appendingPathComponent("sentinel").path }
  /// 待ちに入ったことの目印。
  var started: String { dir.appendingPathComponent("started").path }
  /// worktree の作成先（fixture の下なので後始末に乗る）。
  var worktreePath: String { dir.appendingPathComponent("wt").path }

  // MARK: - ハングする sh

  /// 待ちの本体。`pipeHoldingBody` は孫を残したうえで同じ待ちへ入るので、両方をここから組み立てる。
  ///
  /// 解ける条件は 2 つ: sentinel が現れる（`release()`）か、fixture ディレクトリが消える
  /// （`cleanup()`）。後者が無いと、`cleanup()` は sentinel を作った直後にそれごと削除するため
  /// 待ちが解けず、上限まで回る sh が pipe を握ったまま残る。
  /// 暴走保険の 60 秒は**壁時計**で測る——`sleep 0.05` の反復回数で数えると fork/exec のコストが
  /// 乗ってマシンごとに実時間がずれ、ここに書いた秒数が嘘になる。
  var waitingBody: String {
    """
    : > "\(started)"
    end=$(( $(date +%s) + 60 ))
    while [ ! -f "\(sentinel)" ] && [ -d "\(dir.path)" ] && [ "$(date +%s)" -lt "$end" ]; do
      sleep 0.05
    done
    """
  }

  /// 待つ前に、**セッションごと抜けた孫**を残す sh（実測に基づく形）。
  ///
  /// `Process` は子へ新しいプロセスグループを与え、`terminate()` はそのグループごと届く。
  /// だから普通の子孫は git と一緒に死に、pipe も閉じる。閉じないのは、グループを離れた
  /// プロセス——daemon 化する hook の子（gpg-agent・言語サーバ等）がまさにこれで、
  /// stdout/stderr を継いだまま残るので **EOF が二度と来ない**。
  /// 「切ったのに返らない」を再現できるのはこの形だけ。
  var pipeHoldingBody: String {
    """
    /usr/bin/perl -e 'use POSIX; POSIX::setsid(); exec "sleep", "10";' &
    \(waitingBody)
    """
  }

  /// **セッションごと抜けた孫**を残したうえで、すぐ成功で終わる sh。
  ///
  /// git 自身は正常終了するのに孫が stdout/stderr を継いだままなので、EOF は二度と来ない。
  /// 「切ったのに返らない」（`pipeHoldingBody`）の対になる「**終わったのに返らない**」を作る。
  /// hook が `npm run dev &` のように背景へ 1 本投げるだけで起きる形で、setsid は不要だが、
  /// テストを孫の寿命に依存させないためここでは明示的にセッションを抜けさせる。
  static let daemonizingBody = """
    /usr/bin/perl -e 'use POSIX; POSIX::setsid(); exec "sleep", "10";' &
    exit 0
    """

  /// 0.2 秒ごとに 5 回（合計 1.0 秒）出力し続ける sh。「無出力の時間」で測っていることの検証に使う。
  static let streamingBody = """
    for i in 1 2 3 4 5; do echo tick; sleep 0.2; done
    """

  /// hook を置く（`pre-commit` / `post-checkout`）。
  func installHook(_ name: String, body: String) throws {
    let hooks = (root as NSString).appendingPathComponent(".git/hooks")
    try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
    try write(body: body, to: (hooks as NSString).appendingPathComponent(name))
  }

  /// 実行可能スクリプトを fixture 直下へ置き、パスを返す（`ext::` の相手・clean フィルタなど、
  /// git に踏ませる実行体を置く）。
  @discardableResult
  func installScript(_ name: String, body: String) throws -> String {
    let path = dir.appendingPathComponent(name).path
    try write(body: body, to: path)
    return path
  }

  /// 本体にシバンと priming のガード行を前置して置き、初回 exec の評価を払ってから返る。
  ///
  /// 置くたびに**新規 inode で作る**（既存を in-place で書き換えない）。同じパスへ置き直しても
  /// git から見れば初回 exec になる——`GitHangFixtureTests` の歯はこの性質に立っており、
  /// in-place 上書きに変えると priming が無くても差が出なくなる。
  ///
  /// ガード行は `ORBE_GITHANG_PRIME` が未設定なら status 1 になるだけで本体へ進む
  /// （`set -e` は使っていない）。
  private func write(body: String, to path: String) throws {
    let script = """
      #!/bin/sh
      [ -n "$ORBE_GITHANG_PRIME" ] && exit 0
      \(body)
      """
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    try prime(path)
  }

  /// 初回 exec の Gatekeeper 評価を、git に渡す前にここで払う。
  ///
  /// macOS は新規作成された実行体の**初回 exec** に評価を挟む——実測 150〜450 ms で変動し、
  /// **明確な上限は無い**。コストの大半は XProtect が中身を走査する CPU 時間で、新規 sh 20 本の
  /// 初回 exec は並列にしても直列と同じ時間しかかからず、ファイルサイズにも比例する。よって
  /// idleTimeout を延ばす対処では直せない。評価は inode 単位でシステム全体にキャッシュされるので、
  /// ここで一度 exec しておけば以後 git が踏んでも走らない。
  /// 払わないと、テストの短いアイドル上限（0.6 秒）がこの評価と競合して git が先に打ち切られ、
  /// hang スクリプトが 1 行も動かないまま落ちる。
  ///
  /// priming 実行は `ORBE_GITHANG_PRIME` でガード行から即終了し本体に入らない（`started` を作らず・
  /// sentinel を待たず・孫を残さない）。この変数はテストプロセスの環境には入れず、ここで起こす子の
  /// 環境にだけ載せる＝`GitRunner` が git に渡す環境には現れない。
  private func prime(_ path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.environment = ["ORBE_GITHANG_PRIME": "1"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure.setup("prime \(path)") }
  }

  // MARK: - 進行

  /// 待ちに入るまで待つ（ハングが本当に起きた状態からテストを始めるため）。
  func waitUntilHung(timeout: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: started) { return true }
      usleep(20_000)
    }
    return false
  }

  /// 待ちを解く。何度呼んでもよい。
  func release() {
    FileManager.default.createFile(atPath: sentinel, contents: Data())
  }

  /// 後始末。ディレクトリを消すこと自体が待ちを解く（`waitingBody` の継続条件）ので、
  /// 待ち手は次のポーリングで抜ける。孫プロセスが残っていても最終的に自ら終わる。
  func cleanup() {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - 準備

  /// arrange 用の git（打ち切りの対象にしないよう本番既定の runner を使う）。
  @discardableResult
  func git(_ args: [String]) -> GitRunner.Output {
    GitRunner.shared.runSync(args, cwd: root)
  }

  private func makeRepository() throws {
    for args in [
      ["init", "-q", "-b", "main"],
      ["config", "user.email", "t@example.com"],
      ["config", "user.name", "t"],
      ["config", "commit.gpgsign", "false"],
    ] {
      guard git(args).isSuccess else {
        throw Failure.setup(args.joined(separator: " "))
      }
    }
    try "x\n".write(
      toFile: (root as NSString).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    guard git(["add", "-A"]).isSuccess, git(["commit", "-qm", "init"]).isSuccess
    else { throw Failure.setup("initial commit") }
  }

  enum Failure: Error { case setup(String) }
}
