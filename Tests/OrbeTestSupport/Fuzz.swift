import Foundation
import XCTest

/// 乱数で大量の手を実行するテストの、2 つの段。
///
/// 段は、テストのメソッドの単位で分ける。名前の末尾に `AtFullScale` が付かないメソッドが小さい段で、いつも走る。
/// 付くメソッドが全部の段（長時間ファズ）で、小さい段が確かめることを全部確かめる。手を順に重ねるテストでは、全部の段は、
/// 小さい段と同じ種で始まり、小さい段の手の列を先頭に持つ。全部の段は既定で走り、PR の CI だけが飛ばす。main と手元では、
/// 小さい段のメソッドも全部の段のメソッドも走る。
public enum Fuzz {
  /// 全部の段のメソッドの先頭で呼ぶ。環境変数 `ORBE_SKIP_LONG_FUZZ` が `1` のときだけ、テストを飛ばす。
  public static func skipFullScaleIfExcluded() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["ORBE_SKIP_LONG_FUZZ"] == "1",
      "ORBE_SKIP_LONG_FUZZ=1 で飛ばす")
  }

  /// 手 1 回分の `body` を実行する。その間に `test` へ失敗が記録されるか、`body` がスローしたら、`context`（種と手の番号）を
  /// 持つ失敗を 1 つ記録して `false` を返す。`false` が返ったら、呼び出し側はそのテストを止める。
  public static func step(
    _ test: XCTestCase, _ context: @autoclosure () -> String, file: StaticString = #filePath,
    line: UInt = #line, _ body: () throws -> Void
  ) -> Bool {
    let before = test.testRun?.totalFailureCount ?? 0
    do {
      try body()
    } catch {
      XCTFail("最初の失敗: \(context()): \(error)", file: file, line: line)
      return false
    }
    guard (test.testRun?.totalFailureCount ?? 0) > before else { return true }
    XCTFail("最初の失敗: \(context())", file: file, line: line)
    return false
  }
}
