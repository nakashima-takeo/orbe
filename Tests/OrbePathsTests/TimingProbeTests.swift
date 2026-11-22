import XCTest

/// CI の検証用。使い捨てのブランチにだけ置く。必ず失敗する。
/// テストが失敗したときに `build-test` が失敗で終わり、そのときも所要時間の要約が出ることを確かめる。
final class TimingProbeTests: XCTestCase {
  func testAlwaysFails() {
    XCTFail("検証用の失敗")
  }
}
