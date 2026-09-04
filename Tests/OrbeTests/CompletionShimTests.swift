import XCTest

@testable import Orbe

/// ZDOTDIR shim（`app/zsh/`）の契約を実 `/bin/zsh` で機械検証する。
/// ユーザー rc の source 順・widget bind の最終勝ち・ZDOTDIR のユーザー値復元・
/// ORBE_USER_ZDOTDIR の消費、という「ブリッジ」を fake HOME で決定論的に確かめる。
/// env は明示辞書のみ（継承しない）・`NO_GLOBAL_RCS` で global rc を断つ（開発機 dotfiles で flake させない）。
final class CompletionShimTests: OrbeTestCase {
  /// リポジトリ実体の shim dir（`app/zsh`）。テストは同梱物でなくソースを直接検証する。
  private static let shimDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // OrbeTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
    .appendingPathComponent("app/zsh")

  private var home: URL!
  private var log: URL!

  override func setUpWithError() throws {
    home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("CompletionShimTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    log = home.appendingPathComponent("source-order.log")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
  }

  /// rc ファイルを書く。`marker` 指定時は共有ログへ自分の名前を追記する行を先頭に置く（source 順の証跡）。
  private func writeRc(_ name: String, in dir: URL, marker: String, extra: String = "") throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let content = "echo \(marker) >> \"\(log.path)\"\n" + extra
    try Data(content.utf8).write(to: dir.appendingPathComponent(name))
  }

  private func sourceOrder() -> [String] {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  /// 最初のプロンプト後（＝全 startup file と最初の precmd の後）の bind と env を印字する検証コマンド。
  private static let probe = """
    print -r -- "TAB:${${(z)$(bindkey '^I')}[2]}"
    print -r -- "CR:${${(z)$(bindkey '^M')}[2]}"
    print -r -- "FB:${_ORBE_TAB_FALLBACK-unset}"
    print -r -- "ZDOTDIR:${ZDOTDIR-unset}"
    print -r -- "OUZ:${ORBE_USER_ZDOTDIR-unset}"
    """

  /// 実 zsh を interactive で起こし、probe を stdin から 1 コマンド目として流して出力を返す。
  /// widget は最初のプロンプト直前の precmd で入るため、プロンプトを出さない `-c` では観測できない。
  /// pipe 駆動の `zsh -i` はプロンプトを stderr に出すので stdout は probe の出力だけになる。
  /// env は明示辞書のみ（継承しない）。`NO_GLOBAL_RCS` で `/etc/zshrc`・`/etc/zprofile`（path_helper）を
  /// 断ち決定論化する。
  private func runZsh(extraEnv: [String: String] = [:], login: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    var args = ["-o", "NO_GLOBAL_RCS"]
    if login { args.append("-l") }
    args.append("-i")
    process.arguments = args
    var env = [
      "HOME": home.path,
      "TERM": "dumb",
      "PATH": "/usr/bin:/bin",
      "ZDOTDIR": Self.shimDir.path,
      // widget guard を通す（zsocket は遅延接続なので bind 検証に実 socket は不要）。
      "ORBE_SOCK": home.appendingPathComponent("nosock").path,
      "ORBE_PANE": "1",
    ]
    env.merge(extraEnv) { _, new in new }
    process.environment = env
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice  // 未読 Pipe はバッファ満杯で子を block しうる。捨てる意図を明示
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data((Self.probe + "\n").utf8))
    try stdin.fileHandleForWriting.close()  // EOF で zsh が終了する
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
  }

  private func assertProbe(_ out: String, contains line: String, _ message: String = "") {
    XCTAssertTrue(
      out.split(separator: "\n").map(String.init).contains(line),
      "expected \"\(line)\" in:\n\(out)\n\(message)")
  }

  // MARK: - shim 契約

  func testPlainHomeSourcesUserRcAndBindsWidgets() throws {
    // 素の HOME 構成: ユーザー rc が順に読まれ、widget が最終 bind され、ZDOTDIR が復元（unset）される。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    let out = try runZsh()
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "user-zshrc"])
    assertProbe(out, contains: "TAB:_orbe_complete")
    assertProbe(out, contains: "CR:_orbe_accept_line")
    assertProbe(out, contains: "ZDOTDIR:unset", "元の env に無かった ZDOTDIR は unset へ復元")
    assertProbe(out, contains: "OUZ:unset", "ORBE_USER_ZDOTDIR は shim が読んだ時点で消える")
  }

  func testUserZshenvSettingZdotdirIsHonored() throws {
    // ZDOTDIR 派構成: ユーザー .zshenv が設定した ZDOTDIR の .zshrc が読まれ、最終値も復元される。
    let cfg = home.appendingPathComponent("cfg")
    try writeRc(".zshenv", in: home, marker: "user-zshenv", extra: "export ZDOTDIR=\"$HOME/cfg\"\n")
    try writeRc(".zshrc", in: cfg, marker: "cfg-zshrc")
    let out = try runZsh()
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "cfg-zshrc"])
    assertProbe(out, contains: "TAB:_orbe_complete")
    assertProbe(out, contains: "ZDOTDIR:\(cfg.path)", "ユーザーが設定した ZDOTDIR へ復元")
  }

  func testLateBindingPluginFallsBackViaOrbeTab() throws {
    // 後乗り bind との共存（fzf-tab 相当）: ユーザー .zshrc 末尾の bind に、最初の precmd で入る
    // widget が後勝ちし、元 widget はフォールバックへ退避される。
    try writeRc(
      ".zshrc", in: home, marker: "user-zshrc",
      extra: "my-tab() { :; }\nzle -N my-tab\nbindkey '^I' my-tab\n")
    let out = try runZsh()
    assertProbe(out, contains: "TAB:_orbe_complete", "全 startup file の後に bind＝後勝ち")
    assertProbe(out, contains: "FB:my-tab", "既存 bind はフォールバックへ退避")
  }

  func testOrbeUserZdotdirPassthrough() throws {
    // ghostty 連鎖の shim 側半分: ORBE_USER_ZDOTDIR が与えられた状態（ghostty .zshenv が ZDOTDIR を
    // 復元した直後・GUI がターミナル起動された状態）で、その dir の rc が読まれ最終値へ復元される。
    let cfg = home.appendingPathComponent("cfg")
    try writeRc(".zshenv", in: cfg, marker: "cfg-zshenv")
    try writeRc(".zshrc", in: cfg, marker: "cfg-zshrc")
    let out = try runZsh(extraEnv: ["ORBE_USER_ZDOTDIR": cfg.path])
    XCTAssertEqual(sourceOrder(), ["cfg-zshenv", "cfg-zshrc"])
    assertProbe(out, contains: "ZDOTDIR:\(cfg.path)", "ユーザー値へ復元")
  }

  func testLoginShellSourcesZprofileBetweenEnvAndRc() throws {
    // login shell: .zshenv → .zprofile → .zshrc の順でユーザー rc が読まれる
    // （shim が復元した ZDOTDIR から zsh が自力で読む）。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zprofile", in: home, marker: "user-zprofile")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    _ = try runZsh(login: true)
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "user-zprofile", "user-zshrc"])
  }

  func testDirectoryPathIsNilWithoutBundle() {
    // 同梱物が無い状態（ハーネスが BundledResources.root を管理下の空ディレクトリへ向けている）では
    // shim dir が解決されない＝ activate() は no-op。
    XCTAssertNil(CompletionShim.directoryPath)
  }
}
