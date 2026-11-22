import Foundation
import XCTest

/// CI の検証用。使い捨てのブランチにだけ置く。テストの途中で、プロセスを終了コード 0 で終わらせる。
/// テストの実行が途中で終わったときに、所要時間の集計のステップが失敗して、`build-test` が失敗で終わることを確かめる。
final class TimingProbeTests: XCTestCase {
  func testExitsInTheMiddle() {
    exit(0)
  }
}
