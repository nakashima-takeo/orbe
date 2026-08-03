import Foundation
import OrbePaths
import XCTest

@testable import Orbe

/// 全テストクラスの基底。隔離ハーネスへ点火するだけで、それ以外は素の `XCTestCase`。
///
/// 点火は `class func setUp()`（クラス単位・全インスタンス setUp より前）で行う。最初に走った
/// 1 クラスが `TestIsolation.installOnce()` を呼び、そこで登録されるオブザーバが以降の全テスト
/// （この基底を継承しないクラスも含む）へ効く。だから継承は「どのクラスが最初に走っても点火される」
/// ことだけを担保すればよく、隔離そのものは基底に依存しない。
///
/// これが外れると、`swift test` が開発者の実 `workspaces.json`・ghostty の user 設定・
/// 実 state dir を読み書きし始める。テストが手元の環境に依存して緑になり、CI で落ちる。
class OrbeTestCase: XCTestCase {
  override class func setUp() {
    TestIsolation.installOnce()
    super.setUp()
  }
}

/// テストプロセス全体の隔離。`installOnce()` は冪等で、最初の 1 回だけ実際に張る。
///
/// 張る順序に意味がある。`ORBE_STATE_DIR` は `ControlServer.shared` の `private init()` が
/// 読むため、どのテスト本体よりも前に置かないと実 state dir の `control.sock` を掴む。
/// 掴んだかどうかは最後の assert が検査する（静かに実環境へ落ちさせない）。
enum TestIsolation {
  /// プロセス級の隔離根。テスト実行の間だけ存在する。
  private(set) nonisolated(unsafe) static var root: URL!
  /// 実行中のテスト 1 件に配る作業ディレクトリ。
  private(set) nonisolated(unsafe) static var caseDir: URL?

  /// AF_UNIX の `sun_path` 上限は 104 バイト。`<root>/control.sock` を足しても収まるよう、
  /// root 自体をこの長さで抑える（超える環境では無言で制御 API が無効化するので落とす）。
  static let maxRootPathBytes = 90

  private nonisolated(unsafe) static var installed = false
  private nonisolated(unsafe) static var observer: TestIsolationObserver?

  static func installOnce() {
    guard !installed else { return }
    installed = true

    // 1. 隔離根。UUID 全長は `sun_path` を圧迫するので 8 桁の hex に切る。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(String(format: "orbe-t-%08x", UInt32.random(in: 0...UInt32.max)))
    precondition(
      dir.path.utf8.count <= maxRootPathBytes,
      "隔離根が長すぎる（\(dir.path.utf8.count) > \(maxRootPathBytes)）: \(dir.path)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    root = dir

    // 2. state dir（workspaces.json・control.sock・gui.conf の親）。本番と同じ ORBE_STATE_DIR 経路。
    setenv(OrbePaths.stateDirEnvVar, dir.path, 1)

    // 3. 同梱リソースの探索根。既定は Xcode の bin を指しており空でも中立でもないため、
    //    管理下の空ディレクトリへ明示的に立てる（層1 の `orbe-defaults.conf` は不在になる）。
    let resources = dir.appendingPathComponent("resources", isDirectory: true)
    try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    BundledResources.root = resources

    // 4. ghostty の user 設定。ファイルは作らない＝不在なので user 層は読まれない。
    Config.userFileURLOverride = dir.appendingPathComponent("ghostty-user.conf")

    // 5. 補完の学習ストア。`CompletionLearning.shared` は初回タッチ時の `fileURL` で in-memory
    //    ストアを焼くため、ここでプロセス級に固定して即タッチする（読みと書きの先を食い違わせない）。
    CompletionLearning.fileURLOverride = dir.appendingPathComponent("completion-learning.json")
    _ = CompletionLearning.shared

    // 6. `ControlServer.shared` が 2 より前に構築されていたら実 state dir の socket を掴んでいる。
    //    プロセス級の不変条件が壊れた状態で続けても以降の全テストが無意味なので落とす。
    let expected = dir.appendingPathComponent("control.sock").path
    let actual = ControlServer.shared.socketPath
    guard actual == expected else {
      fatalError(
        "ControlServer が隔離前に構築された（socketPath=\(actual) 期待=\(expected)）。"
          + "テスト本体より前に ORBE_STATE_DIR を張れていない")
    }

    // 7. 毎テストの隔離を担うオブザーバ。以降の全テストへ効く。
    let obs = TestIsolationObserver()
    observer = obs
    XCTestObservationCenter.shared.addTestObserver(obs)
  }

  /// テスト 1 件へ専用ディレクトリを配り、per-test の永続 seam をそこへ向ける。
  /// `CompletionLearning` は張らない（プロセス級に固定。in-memory ストアと保存先を食い違わせない）。
  static func beginCase(sequence: Int) {
    // 連番は UUID より短く、`sun_path` 上限へ効く root 直下のパス長を抑える。
    let dir = root.appendingPathComponent("c\(sequence)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    caseDir = dir

    WorkspacePersistence.fileURLOverride = dir.appendingPathComponent("workspaces.json")
    SettingsPersistence.fileURLOverride = dir.appendingPathComponent("settings.json")
    AppStatePersistence.fileURLOverride = dir.appendingPathComponent("app-state.json")
    GuiConfig.fileURLOverride = dir.appendingPathComponent("gui.conf")
  }

  static func endCase() {
    if let dir = caseDir { try? FileManager.default.removeItem(at: dir) }
    caseDir = nil
  }

  static func teardown() {
    if let root { try? FileManager.default.removeItem(at: root) }
  }
}

/// 毎テストの隔離。テスト 1 件ごとに専用ディレクトリを配り、永続の seam をそこへ向ける。
///
/// インスタンス `setUp()` ではなくオブザーバに置くのは、`super.setUp()` の呼び忘れで隔離が
/// 無言に外れる経路を作らないため（`testCaseWillStart` はインスタンス `setUp()` より前に必ず走る）。
final class TestIsolationObserver: NSObject, XCTestObservation {
  private var sequence = 0

  func testCaseWillStart(_ testCase: XCTestCase) {
    sequence += 1
    TestIsolation.beginCase(sequence: sequence)
  }

  func testCaseDidFinish(_ testCase: XCTestCase) {
    TestIsolation.endCase()
  }

  func testBundleDidFinish(_ testBundle: Bundle) {
    TestIsolation.teardown()
  }
}
