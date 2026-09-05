import XCTest

@testable import Orbe

/// `.app` 同梱物の探索根 `BundledResources.root` と、そこへぶら下がる利用側の解決規則を固定する。
/// 壊れると、同梱物に依る機能（エージェント hook・bare `orb`・zsh 補完 shim・補完エンジン・
/// プラグイン自動導入）が**無警告で丸ごと no-op へ倒れる**。どれも失敗を報せず「使っても何も
/// 起きない」としか現れないので、ここが唯一の番人になる。
///
/// とくに固定したいのは **root の差し替えが即座に全利用側へ伝わる**こと。解決を `static let` や
/// メモ化へ「最適化」すると差し替えが効かなくなり、root を注入点として使う上位層のテストが
/// 静かに嘘をつき始める（同じファイル群の `TitleGlyphs.notoEmoji` が既に焼き付く形をしており、
/// 模倣される現実的な退行）。
final class BundledResourcesTests: OrbeTestCase {
  private var tmp: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    // `BundledResources.root` はハーネスが毎テスト張り直すので、ここで退避・復元はしない。
    tmp = try XCTUnwrap(TestIsolation.caseDir).appendingPathComponent("bundles", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  }

  // MARK: - 仕様1: root は解決の唯一の根で、差し替えが即座に伝わる

  /// バンドルを持たない実行体（`swift run`）では root 自体が無く、全機能が no-op へ倒れる。
  func testNilRootResolvesNothing() {
    BundledResources.root = nil
    assertNothingResolves("root が無いのに所在を返した利用側がある")
  }

  /// root は在るが同梱物が置かれていないディレクトリ（テスト実行体の ambient root がこの形）。
  /// 存在確認を外すと、実体の無いパスを掴んだまま下流へ渡す。
  func testRootWithoutBundledItemsResolvesNothing() {
    BundledResources.root = tmp
    assertNothingResolves("同梱物が無いのに所在を返した利用側がある")
  }

  /// 完全な同梱レイアウトを指せば、全利用側がその root 配下の絶対パスへ解決する。
  /// 各相対パスは `scripts/build-app.sh` が `Contents/Resources/` へ置く配置と同じ。
  func testCompleteLayoutResolvesEveryConsumerUnderRoot() throws {
    let root = try makeBundleLayout(named: "app")
    BundledResources.root = root
    assertEverythingResolves(under: root)
  }

  /// root を別の完全レイアウトへ差し替えると、解決先が新しい root 配下へ移る。
  /// 解決結果をメモ化・`static let` 化した瞬間にここが落ちる（上位層の注入点が死ぬ）。
  func testSwappingRootMovesEveryResolution() throws {
    let first = try makeBundleLayout(named: "first")
    let second = try makeBundleLayout(named: "second")
    BundledResources.root = first
    assertEverythingResolves(under: first)
    BundledResources.root = second
    assertEverythingResolves(under: second)
  }

  // MARK: - 仕様2: 存在条件を満たすときだけ所在を返す

  /// `install.sh` に実行権が無いパッケージは導入できない。掴むと導入が実行時に失敗する。
  func testNonExecutableInstallScriptIsNotAPluginDir() throws {
    let root = try makeBundleLayout(named: "app")
    try setPermissions(0o644, at: root.appendingPathComponent("agent-plugin/install.sh"))
    BundledResources.root = root
    XCTAssertNil(
      AgentPluginInstaller.bundledPluginDir, "install.sh が非実行可能なら同梱プラグインと見なさない")
  }

  /// ディレクトリだけ在って `install.sh` が無い形（コピー漏れ）も同梱と見なさない。
  func testMissingInstallScriptIsNotAPluginDir() throws {
    let root = try makeBundleLayout(named: "app")
    try FileManager.default.removeItem(at: root.appendingPathComponent("agent-plugin/install.sh"))
    BundledResources.root = root
    XCTAssertNil(AgentPluginInstaller.bundledPluginDir, "install.sh が無いなら同梱プラグインと見なさない")
  }

  /// shim の入口は `.zshenv`。これが無い `zsh/` を掴むと ZDOTDIR がユーザーの rc を読めない場所を指す。
  func testMissingZshenvIsNotAShimDir() throws {
    let root = try makeBundleLayout(named: "app")
    try FileManager.default.removeItem(at: root.appendingPathComponent("zsh/.zshenv"))
    BundledResources.root = root
    XCTAssertNil(CompletionShim.directoryPath, ".zshenv が無いなら shim dir と見なさない")
  }

  /// `orbe-completion.zsh` は Orbe の shim dir を同定する印。これが無い `zsh/` を据えると、
  /// shim と別インスタンスの `activate()` がその dir をユーザーの ZDOTDIR と誤認する。
  func testMissingWidgetFileIsNotAShimDir() throws {
    let root = try makeBundleLayout(named: "app")
    try FileManager.default.removeItem(at: root.appendingPathComponent("zsh/orbe-completion.zsh"))
    BundledResources.root = root
    XCTAssertNil(CompletionShim.directoryPath, "orbe-completion.zsh が無いなら shim dir と見なさない")
  }

  /// `bin` が同名のファイルなら PATH へ前置できない。存在確認だけでは通ってしまう境界。
  func testBinAsFileIsNotABinDir() throws {
    let root = tmp.appendingPathComponent("app", isDirectory: true)
    try write(root.appendingPathComponent("bin"))
    BundledResources.root = root
    XCTAssertNil(OrbeRuntimeEnv.bundledBinDir, "bin がディレクトリでなければ PATH へ前置しない")
  }

  /// `orbe-report` の実行権と `bin/` の存在は独立した条件。
  /// 片方が落ちてももう片方は生きる（hook は no-op でも bare `orb` は解決する）。
  func testNonExecutableReportBinaryIsNilButBinDirRemains() throws {
    let root = try makeBundleLayout(named: "app")
    try setPermissions(0o644, at: root.appendingPathComponent("bin/orbe-report"))
    BundledResources.root = root
    XCTAssertNil(OrbeRuntimeEnv.reportBinaryPath, "orbe-report が非実行可能なら env へ注入しない")
    XCTAssertEqual(
      OrbeRuntimeEnv.bundledBinDir, root.appendingPathComponent("bin").path,
      "orbe-report の実行権と bin/ の存在は独立した条件")
  }

  // MARK: - 仕様3: 同梱 bin を PATH 先頭へ前置する（bare `orb` の解決）

  /// 既存 PATH は保持したまま前置する。上書きするとログインシェルの PATH が消える。
  func testPrependPutsBundledBinBeforeExistingPath() throws {
    let root = try makeBundleLayout(named: "app")
    BundledResources.root = root
    var env = ["PATH": "/usr/bin:/bin"]
    OrbeRuntimeEnv.prependBundledBin(to: &env)
    XCTAssertEqual(
      env["PATH"], "\(root.appendingPathComponent("bin").path):/usr/bin:/bin",
      "既存 PATH を保持したまま同梱 bin を先頭へ前置する")
  }

  /// env に PATH が無いタブ（split 等）では本プロセスの PATH を土台にする。
  func testPrependFallsBackToProcessPathWhenEnvHasNone() throws {
    let root = try makeBundleLayout(named: "app")
    let processPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PATH"], "テストプロセスに PATH が無い")
    BundledResources.root = root
    var env: [String: String] = [:]
    OrbeRuntimeEnv.prependBundledBin(to: &env)
    XCTAssertEqual(
      env["PATH"], "\(root.appendingPathComponent("bin").path):\(processPath)",
      "env に PATH が無ければ本プロセスの PATH を土台に前置する")
  }

  /// バンドル無しでは既存 PATH に一切触らない。
  func testPrependIsNoOpWithoutBundle() {
    BundledResources.root = tmp
    var env = ["PATH": "/usr/bin:/bin"]
    OrbeRuntimeEnv.prependBundledBin(to: &env)
    XCTAssertEqual(env["PATH"], "/usr/bin:/bin", "同梱 bin が無ければ PATH を変えない")
  }

  /// バンドル無しかつ env に PATH が無ければ PATH キー自体を生やさない
  /// （生やすと本プロセスの PATH がタブへ漏れ、ログインシェルの解決を横取りする）。
  func testPrependAddsNoPathKeyWithoutBundle() {
    BundledResources.root = tmp
    var env: [String: String] = [:]
    OrbeRuntimeEnv.prependBundledBin(to: &env)
    XCTAssertNil(env["PATH"], "同梱 bin が無ければ PATH キーを生やさない")
  }

  // MARK: - 同梱レイアウトの組み立て

  /// `.app` の `Contents/Resources/` と同じ相対配置を temp に組む。
  private func makeBundleLayout(named name: String) throws -> URL {
    let root = tmp.appendingPathComponent(name, isDirectory: true)
    try write(root.appendingPathComponent("agent-plugin/install.sh"), permissions: 0o755)
    try write(root.appendingPathComponent("completion-engine.js"))
    try write(root.appendingPathComponent("zsh/.zshenv"))
    try write(root.appendingPathComponent("zsh/orbe-completion.zsh"))
    try write(root.appendingPathComponent("bin/orbe-report"), permissions: 0o755)
    try write(root.appendingPathComponent("bin/orb"), permissions: 0o755)
    return root
  }

  private func write(_ url: URL, permissions: Int = 0o644) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: url.path, contents: Data(), attributes: [.posixPermissions: permissions])
  }

  private func setPermissions(_ permissions: Int, at url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }

  // MARK: - パスを返す利用側の一括検査

  /// 所在をパスで返す利用側の現在値。1 本のテストで束ねて見ることで、
  /// 「1 つだけ追随しない」形の退行を取りこぼさない。
  /// `Config.load()` と `TerminalFonts.registerBundled()` は戻り値から所在を観測できず、
  /// `TitleGlyphs.notoEmoji` は `static let` で root の差し替えに追随しないため、ここには入らない。
  /// この 3 つの相対パスは `scripts/build-app.sh` との照合（スライス 9）が受け持つ。
  private func resolved() -> [(name: String, path: String?)] {
    [
      ("AgentPluginInstaller.bundledPluginDir", AgentPluginInstaller.bundledPluginDir?.path),
      ("CompletionEngine.bundlePath", CompletionEngine.bundlePath),
      ("CompletionShim.directoryPath", CompletionShim.directoryPath),
      ("OrbeRuntimeEnv.reportBinaryPath", OrbeRuntimeEnv.reportBinaryPath),
      ("OrbeRuntimeEnv.bundledBinDir", OrbeRuntimeEnv.bundledBinDir),
    ]
  }

  /// root 配下で各利用側が返すべき絶対パス。
  private func expected(under root: URL) -> [String: String] {
    [
      "AgentPluginInstaller.bundledPluginDir": root.appendingPathComponent("agent-plugin").path,
      "CompletionEngine.bundlePath": root.appendingPathComponent("completion-engine.js").path,
      "CompletionShim.directoryPath": root.appendingPathComponent("zsh").path,
      "OrbeRuntimeEnv.reportBinaryPath": root.appendingPathComponent("bin/orbe-report").path,
      "OrbeRuntimeEnv.bundledBinDir": root.appendingPathComponent("bin").path,
    ]
  }

  private func assertNothingResolves(
    _ message: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let offenders = resolved().filter { $0.path != nil }.map { "\($0.name)=\($0.path ?? "")" }
    XCTAssertTrue(offenders.isEmpty, "\(message): \(offenders)", file: file, line: line)
  }

  private func assertEverythingResolves(
    under root: URL, file: StaticString = #filePath, line: UInt = #line
  ) {
    let want = expected(under: root)
    for (name, path) in resolved() {
      XCTAssertEqual(
        path, want[name], "\(name) が root（\(root.path)）配下へ解決していない", file: file, line: line)
    }
  }
}
