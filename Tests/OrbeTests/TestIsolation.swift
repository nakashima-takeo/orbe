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
  /// `static`（＝上書き不可）にするのは、サブクラスが `super` 抜きで上書きすると点火が外れるため。
  /// 上書きしようとした時点でコンパイルが落ちる＝実行時に無言で外れる経路が残らない。
  override static func setUp() {
    TestIsolation.installOnce()
    super.setUp()
  }
}

/// ハーネスが配る隔離済みの永続ファイル。arrange が実ファイルを置く先であり、
/// 各テストが自分でパスを組み立てないための唯一の出所。
extension OrbeTestCase {
  func workspacesFile() throws -> URL { try XCTUnwrap(WorkspacePersistence.fileURL) }
  func settingsFile() throws -> URL { try XCTUnwrap(SettingsPersistence.fileURL) }
  func appStateFile() throws -> URL { try XCTUnwrap(AppStatePersistence.fileURL) }
  func guiConfFile() throws -> URL { try XCTUnwrap(GuiConfig.fileURL) }
}

/// テストプロセス全体の隔離。`installOnce()` は冪等で、最初の 1 回だけ実際に張る。
///
/// 張る順序に意味がある。`ORBE_STATE_DIR` は `ControlServer.shared` の `private init()` が
/// 読むため、どのテスト本体よりも前に置かないと実 state dir の `control.sock` を掴む。
/// 掴んだかどうかは最後の assert が検査する（静かに実環境へ落ちさせない）。
///
/// 実環境を汚さないことの実証は `scripts/verify-test-isolation.sh`（手動・CI 非搭載）。
enum TestIsolation {
  /// プロセス級の隔離根。テスト実行の間だけ存在する。
  private(set) nonisolated(unsafe) static var root: URL!
  /// 実行中のテスト 1 件に配る作業ディレクトリ。
  private(set) nonisolated(unsafe) static var caseDir: URL?
  /// 直前のテストへ配ったディレクトリ。配り直しと後始末を測るためだけに持つ。
  private(set) nonisolated(unsafe) static var previousCaseDir: URL?

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

    // 3. 同梱リソースの探索根が指す先。既定は Xcode の bin を指しており空でも中立でもないため、
    //    管理下の空ディレクトリを用意する（層1 の `orbe-defaults.conf` は不在になる）。
    //    実際の代入は `beginCase` が毎テスト行う（張り忘れ・戻し忘れを作らない）。
    try? FileManager.default.createDirectory(
      at: dir.appendingPathComponent("resources", isDirectory: true),
      withIntermediateDirectories: true)

    // 4. 補完の学習ストア。`CompletionLearning.shared` は初回タッチ時の `fileURL` で in-memory
    //    ストアを焼くため、まだ誰も書いていないこの時点で固定して即タッチする。
    //    ＝この 1 種だけは per-test にできず、学習状態はテスト間で持ち越される。
    CompletionLearning.fileURLOverride = dir.appendingPathComponent("completion-learning.json")
    _ = CompletionLearning.shared

    // 5. `ControlServer.shared` が 2 より前に構築されていたら実 state dir の socket を掴んでいる。
    //    プロセス級の不変条件が壊れた状態で続けても以降の全テストが無意味なので落とす。
    let expected = dir.appendingPathComponent("control.sock").path
    let actual = ControlServer.shared.socketPath
    guard actual == expected else {
      fatalError(
        "ControlServer が隔離前に構築された（socketPath=\(actual) 期待=\(expected)）。"
          + "テスト本体より前に ORBE_STATE_DIR を張れていない")
    }

    // 6. 毎テストの隔離を担うオブザーバ。以降の全テストへ効く。
    let obs = TestIsolationObserver()
    observer = obs
    XCTestObservationCenter.shared.addTestObserver(obs)
  }

  /// テスト 1 件へ専用ディレクトリを配り、隔離の seam をそこへ向け直す。
  ///
  /// 値が per-test（永続 4 種）かプロセス級（同梱リソース根・ghostty user 層）かに関わらず
  /// **毎テスト無条件に張り直す**。テストが自分で書き換えても次のテストへ漏れず、戻し忘れが
  /// 起きえない——申告制を残さないため。`CompletionLearning` だけは `shared` が in-memory へ
  /// 焼き付ける都合で per-test にできず、`installOnce` の固定のままにする。
  static func beginCase(sequence: Int) {
    // 連番は UUID より短く、`sun_path` 上限へ効く root 直下のパス長を抑える。
    let dir = root.appendingPathComponent("c\(sequence)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    caseDir = dir

    WorkspacePersistence.fileURLOverride = dir.appendingPathComponent("workspaces.json")
    SettingsPersistence.fileURLOverride = dir.appendingPathComponent("settings.json")
    AppStatePersistence.fileURLOverride = dir.appendingPathComponent("app-state.json")
    GuiConfig.fileURLOverride = dir.appendingPathComponent("gui.conf")

    // プロセス級の 2 種。root 直下の同じ値を毎回置き直す冪等操作。
    BundledResources.root = root.appendingPathComponent("resources", isDirectory: true)
    // ファイルは作らない＝不在なので ghostty の user 層は読まれない。
    Config.userFileURLOverride = root.appendingPathComponent("ghostty-user.conf")
  }

  static func endCase() {
    if let dir = caseDir { try? FileManager.default.removeItem(at: dir) }
    previousCaseDir = caseDir
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
