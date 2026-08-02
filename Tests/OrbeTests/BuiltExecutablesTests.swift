import XCTest

/// L4（プロセス境界）が前提にする「ビルド済み CLI 実行体がテストバンドルの隣にある」ことを固定する。
///
/// この 3 実行体は `Package.swift` 上どのテストターゲットの依存でもない。それでも `swift test` で
/// ビルドされるのは、SwiftPM がルートパッケージの**全ターゲット**をビルドサブセットに含めるからである
/// （`products:` の宣言内容とも、テストターゲットの依存関係とも無関係に生成される）。
/// つまりこの前提は SwiftPM の暗黙の振る舞いに支えられているだけで、どこにも宣言されていない。
///
/// 壊れると何が起きるか: 実行体ターゲットが `Package.swift` から消えた・改名された瞬間、あるいは
/// `swift test` のビルドサブセットの挙動が変わった瞬間、バイナリは何も言わずに消える。L4 のテストは
/// 「バイナリが無い」ことを「Orbe が動いていない」ことと区別できないため、原因の見えない失敗になるか、
/// 存在チェックで握り潰していれば黙って緑に化ける。ここが先に落ちればその切り分けが要らない。
final class BuiltExecutablesTests: XCTestCase {
  /// L4 が使うバイナリ位置の解決規則: xctest バンドルの親ディレクトリ。
  private var builtProductsDirectory: URL {
    Bundle(for: BuiltExecutablesTests.self).bundleURL.deletingLastPathComponent()
  }

  /// 制御チャネルを喋る 3 実行体が、テストバンドルの隣に実行可能な状態で存在する。
  func testControlChannelExecutablesExistNextToTestBundle() {
    let directory = builtProductsDirectory
    for name in ["orbe-cli", "orbe-mcp", "orbe-report"] {
      let url = directory.appendingPathComponent(name, isDirectory: false)
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: url.path),
        "\(name) が \(directory.path) に無い。swift test がこの実行体をビルドしなくなっている"
      )
    }
  }
}
