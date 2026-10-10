import XCTest

@testable import Orbe

/// タブの印——Orbe が起動時に外す集合は、タブへ注入する集合と同じ定義から出る。
///
/// 壊れると何が起きるか。別の Orbe のタブから起動した Orbe の子（git の hook・エディタ・裏の agent）が親のタブを名乗り、
/// 親の Orbe のタブの状態として報告する。注入しない `ORBE_STATE_DIR` まで外すと、隔離インスタンスの子が本物の state を掴む。
final class OrbeRuntimeEnvTests: OrbeTestCase {
  /// タブへ注入する印は全て外す一覧に入っていて、注入しない変数は入っていない。
  func testStrippedMarkersAreExactlyWhatTabsReceive() {
    var env: [String: String] = [:]
    OrbeRuntimeEnv.inject(into: &env, tabId: 1)

    let injected = Set(env.keys.filter { $0 != "PATH" })

    XCTAssertTrue(injected.isSubset(of: OrbeRuntimeEnv.markerNames), "\(injected)")
    XCTAssertTrue(injected.contains("ORBE_TAB"))
    XCTAssertFalse(OrbeRuntimeEnv.markerNames.contains("ORBE_STATE_DIR"))
    XCTAssertFalse(OrbeRuntimeEnv.markerNames.contains("PATH"))
  }
}
