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
  // `activate()` が書くプロセス env はハーネスの管轄外＝自分で戻す（zsh 駆動側は env を継承しないので無関係）。
  private var savedZdotdir: String?
  private var savedOrbeUserZdotdir: String?

  override func setUpWithError() throws {
    home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("CompletionShimTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    log = home.appendingPathComponent("source-order.log")
    let env = ProcessInfo.processInfo.environment
    savedZdotdir = env["ZDOTDIR"]
    savedOrbeUserZdotdir = env["ORBE_USER_ZDOTDIR"]
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: home)
    for (key, saved) in [("ZDOTDIR", savedZdotdir), ("ORBE_USER_ZDOTDIR", savedOrbeUserZdotdir)] {
      if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
    }
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
  /// `CHILD:` は zsh から起こした子プロセスが実際に継ぐ env、`HOOK:` は一回きりフックの痕跡
  /// （precmd_functions 内の位置 / 関数の有無 / 保持変数）。
  private static let probe = """
    print -r -- "TAB:${${(z)$(bindkey '^I')}[2]}"
    print -r -- "CR:${${(z)$(bindkey '^M')}[2]}"
    print -r -- "FB:${_ORBE_TAB_FALLBACK-unset}"
    print -r -- "LI:${widgets[zle-line-init]-unset}"
    print -r -- "ZDOTDIR:${ZDOTDIR-unset}"
    print -r -- "OUZ:${ORBE_USER_ZDOTDIR-unset}"
    print -r -- "CHILD:$(/bin/sh -c 'echo "${ZDOTDIR-unset} ${ORBE_USER_ZDOTDIR-unset}"')"
    print -r -- "HOOK:${precmd_functions[(I)_orbe_bootstrap]}/${+functions[_orbe_bootstrap]}/${_orbe_widget_file-unset}"
    """

  /// 実 zsh を起こし、probe を stdin から 1 コマンド目として流して出力を返す。
  /// widget は最初のプロンプト直前の precmd で入るため、プロンプトを出さない `-c` では観測できない。
  /// pipe 駆動の `zsh -i` はプロンプトを stderr に出すので stdout は probe の出力だけになる。
  /// 非対話（`interactive: false`）でも zsh は stdin をスクリプトとして読むので同じ駆動が使える。
  /// env は明示辞書のみ（継承しない）。`NO_GLOBAL_RCS` で `/etc/zshrc`・`/etc/zprofile`（path_helper）を
  /// 断ち決定論化する。
  private func runZsh(
    extraEnv: [String: String] = [:], login: Bool = false, interactive: Bool = true
  ) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    var args = ["-o", "NO_GLOBAL_RCS"]
    if login { args.append("-l") }
    if interactive { args.append("-i") }
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

  func testLoginShellSourcesAllUserRcInOrder() throws {
    // login shell: .zshenv → .zprofile → .zshrc → .zlogin の順でユーザー rc が読まれる
    // （shim が復元した ZDOTDIR から zsh が自力で読む）。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zprofile", in: home, marker: "user-zprofile")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    try writeRc(".zlogin", in: home, marker: "user-zlogin")
    _ = try runZsh(login: true)
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "user-zprofile", "user-zshrc", "user-zlogin"])
  }

  func testZdotdirUserLoginShellSourcesAllRcFromUserDirAndBindsWidgets() throws {
    // ZDOTDIR 派の login shell: ユーザー .zshenv が立てた ZDOTDIR の .zprofile → .zshrc → .zlogin が
    // 読まれ、その後で widget が入る。shim は復元した ZDOTDIR に以降触らないので、続く startup file は
    // すべて zsh がユーザーの dir から読む（旧方式の「再捕捉」が無くても要件 B が成り立つ形）。
    let cfg = home.appendingPathComponent("cfg")
    try writeRc(".zshenv", in: home, marker: "user-zshenv", extra: "export ZDOTDIR=\"$HOME/cfg\"\n")
    try writeRc(".zprofile", in: cfg, marker: "cfg-zprofile")
    try writeRc(".zshrc", in: cfg, marker: "cfg-zshrc")
    try writeRc(".zlogin", in: cfg, marker: "cfg-zlogin")
    let out = try runZsh(login: true)
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "cfg-zprofile", "cfg-zshrc", "cfg-zlogin"])
    assertProbe(out, contains: "TAB:_orbe_complete")
    assertProbe(out, contains: "CR:_orbe_accept_line")
    assertProbe(out, contains: "ZDOTDIR:\(cfg.path)", "ユーザーが設定した ZDOTDIR のまま終わる")
  }

  func testUserAliasesDoNotBreakWidgetInstall() throws {
    // ユーザーが shim・widget ファイルの語を alias で潰していても widget が入る。shim は全クォートで、
    // widget ファイルはユーザーの alias から隔離した関数スコープでパースされる（そうでないと
    // 関数本体の `local` が alias 展開され zle-line-init のチェーンが壊れる）。
    try writeRc(
      ".zshenv", in: home, marker: "user-zshenv",
      extra: "alias builtin=echo\nalias source=echo\nalias local=echo\n")
    let out = try runZsh()
    assertProbe(out, contains: "TAB:_orbe_complete")
    assertProbe(
      out, contains: "LI:user:_orbe_line_init", "zle-line-init のチェーンが Orbe の widget になっている")
  }

  func testBootstrapHookLeavesNoTraceAfterFirstPrompt() throws {
    // 一回きりフック: 最初のプロンプトで widget を入れたら、precmd_functions・関数・保持変数のどれにも
    // Orbe の痕跡が残らない（毎プロンプト走らず、ユーザーのシェル状態を汚さない）。
    let out = try runZsh()
    assertProbe(out, contains: "TAB:_orbe_complete", "フックは一度は走っている")
    assertProbe(
      out, contains: "HOOK:0/0/unset", "precmd_functions / 関数 / _orbe_widget_file のどれにも残らない")
  }

  // MARK: - 汚染 env からの回復（ORBE_USER_ZDOTDIR が Orbe の shim dir を指す・空文字）

  /// 汚染 env の共通観察: 再帰せず（shim は一度しか入らない＝フックの二重登録が無い）、
  /// ユーザーの rc が home から読まれ、widget が入り、ZDOTDIR / ORBE_USER_ZDOTDIR は unset に戻る。
  private func assertRecoveredToHome(_ out: String) {
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "user-zshrc"], "ユーザー値ではないので home 扱い")
    assertProbe(out, contains: "TAB:_orbe_complete")
    assertProbe(out, contains: "CR:_orbe_accept_line")
    assertProbe(out, contains: "ZDOTDIR:unset")
    assertProbe(out, contains: "OUZ:unset")
    assertProbe(out, contains: "HOOK:0/0/unset", "shim が二重に走った痕跡（フックの残り）が無い")
  }

  func testOrbeUserZdotdirPointingAtOwnShimDirRecoversToHome() throws {
    // 自分自身の shim dir を「ユーザーの ZDOTDIR」として渡された形（旧 shim が子 env に残した
    // ZDOTDIR=<shim dir> を activate() が退避した結果）。旧 shim はここで自分を source し無限再帰した。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    let out = try runZsh(extraEnv: ["ORBE_USER_ZDOTDIR": Self.shimDir.path])
    assertRecoveredToHome(out)
  }

  func testOrbeUserZdotdirPointingAtAnotherOrbeShimDirRecoversToHome() throws {
    // 別の Orbe（別 .app・旧版）の shim dir を渡された形（Orbe のペインから起こした Orbe Dev が
    // 親の shim dir を継ぐ経路）。orbe-completion.zsh を持つ dir は同類として同じ扱いになる。
    let other = home.appendingPathComponent("Other.app/Contents/Resources/zsh")
    try FileManager.default.createDirectory(
      at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Self.shimDir, to: other)
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    let out = try runZsh(extraEnv: ["ORBE_USER_ZDOTDIR": other.path])
    assertRecoveredToHome(out)
  }

  func testEmptyOrbeUserZdotdirRecoversToHome() throws {
    // 空文字を渡された形（再帰で巻き戻った旧 shim が残す ZDOTDIR=""・ORBE_USER_ZDOTDIR=""）。
    // 空文字を ZDOTDIR に復元すると zsh は `/.zshrc` を探しに行き、ユーザーの rc が読まれない。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    let out = try runZsh(extraEnv: ["ORBE_USER_ZDOTDIR": ""])
    assertRecoveredToHome(out)
  }

  // MARK: - 非対話 zsh（子プロセス env のクリーンさ・.zlogin）

  func testNonInteractiveShellLeavesNoShimInChildEnv() throws {
    // 非対話 zsh（`zsh script` / `zsh -c` 相当）: .zshenv 段で startup が終わっても、そこから起こした
    // 子プロセスの env に ZDOTDIR=<shim dir> も ORBE_USER_ZDOTDIR も残らない。
    // 旧 shim は「次の段のために」ZDOTDIR を shim へ戻したまま終わり、ここが汚染の種になっていた。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    let out = try runZsh(interactive: false)
    XCTAssertEqual(sourceOrder(), ["user-zshenv"])
    assertProbe(out, contains: "CHILD:unset unset", "子プロセスの env に shim の痕跡が無い")
  }

  func testNonInteractiveLoginShellSourcesZloginAndLeavesNoShimInChildEnv() throws {
    // 非対話 login zsh（`zsh -l -c` 相当）: .zshenv → .zprofile → .zlogin がユーザーの dir から読まれ
    // （.zshrc は非対話なので読まれない）、子プロセスの env もクリーン。
    try writeRc(".zshenv", in: home, marker: "user-zshenv")
    try writeRc(".zprofile", in: home, marker: "user-zprofile")
    try writeRc(".zshrc", in: home, marker: "user-zshrc")
    try writeRc(".zlogin", in: home, marker: "user-zlogin")
    let out = try runZsh(login: true, interactive: false)
    XCTAssertEqual(sourceOrder(), ["user-zshenv", "user-zprofile", "user-zlogin"])
    assertProbe(out, contains: "CHILD:unset unset", "子プロセスの env に shim の痕跡が無い")
  }

  func testDirectoryPathIsNilWithoutBundle() {
    // 同梱物が無い状態（ハーネスが BundledResources.root を管理下の空ディレクトリへ向けている）では
    // shim dir が解決されない＝ activate() は no-op。
    XCTAssertNil(CompletionShim.directoryPath)
  }

  // MARK: - GUI 側: ユーザーの ZDOTDIR の解決と activate() の所有規則

  /// `orbe-completion.zsh` を持つ dir＝Orbe の shim dir と同定される dir（本番 / Dev / 旧版の区別なし）。
  private func makeShimDir(named name: String) throws -> String {
    let dir = home.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("orbe-completion.zsh"))
    return dir.path
  }

  /// 同梱 shim を持つ fake bundle を組んで `BundledResources.root` を向ける。返すのは同梱 shim dir。
  private func installFakeBundle() throws -> String {
    let root = home.appendingPathComponent("bundle")
    let shim = try makeShimDir(named: "bundle/zsh")
    try Data().write(to: URL(fileURLWithPath: shim).appendingPathComponent(".zshenv"))
    BundledResources.root = root
    return shim
  }

  func testUserZdotdirPrefersInheritedZdotdir() {
    // ターミナル起動・launchctl setenv 由来の実 ZDOTDIR がそのままユーザー値。
    let user = home.appendingPathComponent("cfg").path
    XCTAssertEqual(
      CompletionShim.userZdotdir(in: ["ZDOTDIR": user, "ORBE_USER_ZDOTDIR": "/elsewhere"]), user)
  }

  func testUserZdotdirFallsBackToOrbeUserZdotdirWhenInheritedZdotdirIsShimDir() throws {
    // 親 Orbe・汚染シェルから起動された形: 継承 ZDOTDIR は shim dir なのでユーザー値ではなく、
    // 親が捕捉して渡した ORBE_USER_ZDOTDIR がユーザー値。
    let parentShim = try makeShimDir(named: "parent-shim")
    let user = home.appendingPathComponent("cfg").path
    XCTAssertEqual(
      CompletionShim.userZdotdir(in: ["ZDOTDIR": parentShim, "ORBE_USER_ZDOTDIR": user]), user)
  }

  func testUserZdotdirIsNilWhenOnlyEmptyOrShimValuesInherited() throws {
    // 空文字・shim dir・不在はどれもユーザー値ではない。
    let parentShim = try makeShimDir(named: "parent-shim")
    XCTAssertNil(CompletionShim.userZdotdir(in: [:]))
    XCTAssertNil(CompletionShim.userZdotdir(in: ["ZDOTDIR": "", "ORBE_USER_ZDOTDIR": ""]))
    XCTAssertNil(
      CompletionShim.userZdotdir(in: ["ZDOTDIR": parentShim, "ORBE_USER_ZDOTDIR": parentShim]))
  }

  func testActivateKeepsOrbeUserZdotdirWhenInheritedZdotdirIsShimDir() throws {
    // 継承 ZDOTDIR が shim dir のとき、親が捕捉したユーザー値（ORBE_USER_ZDOTDIR）を shim dir で
    // 上書きしない。旧実装はここで shim dir を退避し、子の shim が自分を source する種を作っていた。
    let bundled = try installFakeBundle()
    let parentShim = try makeShimDir(named: "parent-shim")
    let user = home.appendingPathComponent("cfg").path
    setenv("ZDOTDIR", parentShim, 1)
    setenv("ORBE_USER_ZDOTDIR", user, 1)
    CompletionShim.activate()
    let env = ProcessInfo.processInfo.environment
    XCTAssertEqual(env["ORBE_USER_ZDOTDIR"], user)
    XCTAssertEqual(env["ZDOTDIR"], bundled, "ZDOTDIR は同梱 shim dir へ向く")
  }

  func testActivateUnsetsOrbeUserZdotdirWhenOnlyContaminatedValuesInherited() throws {
    // 継承値が shim dir しか無ければ ORBE_USER_ZDOTDIR は消える。以降 GUI プロセス env の
    // ORBE_USER_ZDOTDIR は「存在すれば必ず正当なユーザー値」と読める（shim がそれを前提に復元する）。
    let bundled = try installFakeBundle()
    let parentShim = try makeShimDir(named: "parent-shim")
    setenv("ZDOTDIR", parentShim, 1)
    setenv("ORBE_USER_ZDOTDIR", parentShim, 1)
    CompletionShim.activate()
    let env = ProcessInfo.processInfo.environment
    XCTAssertNil(env["ORBE_USER_ZDOTDIR"], "汚染値を子の shim へ通さない")
    XCTAssertEqual(env["ZDOTDIR"], bundled, "ZDOTDIR は同梱 shim dir へ向く")
  }
}
