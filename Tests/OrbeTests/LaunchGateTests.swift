import XCTest

@testable import Orbe

/// 起動経路の関門（`LaunchGate`）の契約を検証する。
///
/// 守っているのは 2 つ。①`.app` をコマンドとして直接叩かれた起動だけを落とし、正当な起動経路
/// （LaunchServices・隔離インスタンス・`swift run`）は通すこと。②起動経路の印をペインへ
/// 継承させないこと。②は落とすと **Orbe の中で打った `orbe` でだけ**関門が素通りする——
/// Finder 起動もターミナルからの直接 exec も正しく動くので、手で触っても露見しない。
final class LaunchGateTests: OrbeTestCase {
  /// 実プロセス env を触るテストがあるため、前後で必ず未設定へ戻す（既定の静止状態）。
  override func setUpWithError() throws {
    unsetenv(LaunchGate.launchSourceEnvVar)
  }

  override func tearDownWithError() throws {
    unsetenv(LaunchGate.launchSourceEnvVar)
  }

  // MARK: - 判定規則

  /// LaunchServices（Finder / Dock / `open`）起動は通す。Info.plist の `LSEnvironment` が
  /// 印を注入する唯一の経路で、ここが通らないとアプリが起動不能になる。
  func testLaunchServicesLaunchProceeds() {
    XCTAssertEqual(
      LaunchGate.decide(
        isBundled: true, launchSource: LaunchGate.appLaunchSource, stateDir: nil),
      .proceed)
  }

  /// `.app` をコマンドとして直接叩かれた起動は落とす。`orb` の typo である `orbe` がここに来る
  /// （ghostty の shell integration が `Contents/MacOS` を PATH へ載せ、大小文字非区別で GUI 実行体に当たる）。
  func testDirectExecOfBundleIsRejected() {
    XCTAssertEqual(
      LaunchGate.decide(isBundled: true, launchSource: nil, stateDir: nil),
      .reject)
  }

  /// 未知の印を `app` 扱いしない。判定は「`app` と厳密一致か」だけで、それ以外は非 LaunchServices。
  func testUnknownLaunchSourceIsRejected() {
    XCTAssertEqual(
      LaunchGate.decide(isBundled: true, launchSource: "cli", stateDir: nil),
      .reject)
  }

  /// 隔離インスタンス（sandbox-run）は通す。直接 exec がその起こし方そのもので、
  /// `ORBE_STATE_DIR` が「意図した隔離起動である」ことの印になる。
  func testIsolatedInstanceProceeds() {
    XCTAssertEqual(
      LaunchGate.decide(isBundled: true, launchSource: nil, stateDir: "/tmp/orbe-sandbox"),
      .proceed)
  }

  /// 空文字の `ORBE_STATE_DIR` は未設定と同じ扱い（`OrbePaths` の非空判定と規則を揃える）。
  /// 空文字を隔離指定と読むと、うっかり `ORBE_STATE_DIR=` を撒いた環境で関門が丸ごと無効になる。
  func testEmptyStateDirDoesNotOpenTheGate() {
    XCTAssertEqual(
      LaunchGate.decide(isBundled: true, launchSource: nil, stateDir: ""),
      .reject)
  }

  /// `swift run`（バンドル無し）の開発起動は通す。LaunchServices を通りようがないので、
  /// バンドル判定より先に落とすと開発動線が丸ごと止まる。
  func testUnbundledDevelopmentRunProceeds() {
    XCTAssertEqual(
      LaunchGate.decide(isBundled: false, launchSource: nil, stateDir: nil),
      .proceed)
  }

  // MARK: - 印の消費（ペインへ継承させない）

  /// 印は読めて、かつ**読んだ時点でプロセス env から消えている**。
  ///
  /// ペインの env は spawn 時のプロセス env そのものなので、ここで消え残ると
  /// ペインが印を継承し、その中で打った `orbe` が LaunchServices 起動に化けて関門を素通りする。
  /// このテストがこのファイルで一番効く（規則そのものは目で追えるが、掃除の欠落は追えない）。
  func testConsumeReturnsValueAndScrubsProcessEnv() {
    setenv(LaunchGate.launchSourceEnvVar, LaunchGate.appLaunchSource, 1)

    XCTAssertEqual(LaunchGate.consumeLaunchSource(), LaunchGate.appLaunchSource)
    XCTAssertNil(
      ProcessInfo.processInfo.environment[LaunchGate.launchSourceEnvVar],
      "印が残ると Orbe の中で打った `orbe` が正規起動に見え、関門が素通りする")
    XCTAssertNil(getenv(LaunchGate.launchSourceEnvVar), "子プロセスへ渡る env からも消えていること")
  }

  /// 未設定でも nil を返して壊れない（LaunchServices を経由しない起動が通る通常経路）。
  func testConsumeOnMissingLaunchSourceIsNil() {
    XCTAssertNil(LaunchGate.consumeLaunchSource())
    XCTAssertNil(getenv(LaunchGate.launchSourceEnvVar))
  }

  // MARK: - バンドル素材との噛み合い

  /// `app/Info.plist` が印を注入する宣言を持っていること。
  ///
  /// これが欠けると全起動が「LaunchServices 経由でない」と判定され、**Finder から起動できなくなる**。
  /// 関門のロジックと Info.plist は別ファイルで、片方だけ直しても Swift のコンパイルは通るため、
  /// 対応関係をここで縛る。検証するのは同梱物ではなくリポジトリのソース（`CompletionShimTests` と同じ流儀）。
  func testInfoPlistDeclaresLaunchSource() throws {
    let plist = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // OrbeTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("app/Info.plist")

    let parsed =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: plist), format: nil) as? [String: Any]
    let environment = try XCTUnwrap(
      parsed?["LSEnvironment"] as? [String: String],
      "app/Info.plist に LSEnvironment が無い。LaunchServices 起動が印を得られず、Finder から起動できなくなる")

    XCTAssertEqual(
      environment[LaunchGate.launchSourceEnvVar], LaunchGate.appLaunchSource,
      "LSEnvironment の値と LaunchGate が期待する値は一致していること")
  }
}
