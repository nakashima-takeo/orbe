import XCTest

/// L4（プロセス境界）が前提にする「ビルド済み CLI 実行体がテストバンドルの隣にある」ことを固定する。
///
/// `orbe-report` は `OrbeReportTests` の依存として宣言されているが、`orbe-cli` / `orbe-mcp` は
/// どのテストターゲットの依存でもない。それでもビルドされるのは、`swift test` が
/// ルートパッケージの**全ターゲット**をビルドサブセットに含めるからで、この振る舞いは宣言されていない。
///
/// 壊れると何が起きるか: 依存が宣言された `orbe-report` はターゲットが消えればマニフェスト解決が落ちて
/// 気づける。`orbe-cli` / `orbe-mcp` は何のエラーも出さずバイナリだけが消える。L4 のテストは「バイナリが無い」ことを
/// 「Orbe が動いていない」ことと区別できないため、原因の見えない失敗になるか、存在チェックで握り潰して
/// いれば黙って緑に化ける。ここが先に落ちればその切り分けが要らない。
final class BuiltExecutablesTests: OrbeTestCase {
  /// 制御チャネルを喋る 3 実行体が、テストバンドルの隣に実行可能な状態で存在する。
  /// 解決規則そのものは L4 の駆動台（`ControlProcess.builtProductsDirectory`）が持ち、ここはその
  /// 規則が指す先を検査する——両者が別の式を持つと、片方だけ直したときに黙ってすれ違う。
  func testControlChannelExecutablesExistNextToTestBundle() {
    let directory = ControlProcess.builtProductsDirectory
    for name in ["orbe-cli", "orbe-mcp", "orbe-report"] {
      let url = directory.appendingPathComponent(name, isDirectory: false)
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: url.path),
        "\(name) が \(directory.path) に無い。`Package.swift` の実行体ターゲットが消えた・改名されたか、"
          + " `swift test` のビルド対象から外れている"
      )
    }
  }
}
