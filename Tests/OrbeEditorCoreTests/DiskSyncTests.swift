import CryptoKit
import Foundation
import XCTest

@testable import OrbeEditorCore

/// 未保存の状態——立てるのは即時、下ろすのは今の版の比較が同じと答えてから。壊れると、編集の後に届いた古い比較の結果で
/// 未保存が誤って下り、閉じる確認が出ずに編集が消え、外部変更が未保存の本文を上書きする。
final class DiskSyncTests: XCTestCase {
  private func synced(_ text: String) -> DiskSync {
    DiskSync(.init(text: TextRope(text), digest: SHA256.hash(data: Data(text.utf8)), hasBOM: false))
  }

  /// 確かめ中でも、古い版の結果は当てない——その後の編集で同じかは変わる。
  func testAnOutcomeOfAnOlderVersionIsIgnored() {
    var sync = synced("abc")
    XCTAssertTrue(sync.textDidChange(length: 3), "前提: 長さが同じなら確かめ中")
    XCTAssertFalse(sync.settle(ComparisonOutcome(version: 1, same: true), version: 2))
    XCTAssertTrue(sync.isDirty, "古い版の「同じ」で下ろさない")
    XCTAssertTrue(sync.settle(ComparisonOutcome(version: 2, same: true), version: 2))
    XCTAssertFalse(sync.isDirty)
  }

  /// 確かめ中でなければ、今の版の結果でも当てない——長さが違うと分かった後や、姿を置き直した後に届いた結果。
  func testAnOutcomeIsIgnoredUnlessChecking() {
    var sync = synced("abc")
    XCTAssertTrue(sync.textDidChange(length: 3))
    XCTAssertFalse(sync.textDidChange(length: 4), "前提: 長さが違えばその場で違う")
    XCTAssertFalse(sync.settle(ComparisonOutcome(version: 2, same: true), version: 2))
    XCTAssertTrue(sync.isDirty)

    sync.sync(
      .init(text: TextRope("abcd"), digest: SHA256.hash(data: Data("abcd".utf8)), hasBOM: false))
    XCTAssertFalse(sync.settle(ComparisonOutcome(version: 2, same: false), version: 2))
    XCTAssertFalse(sync.isDirty, "揃った後の「違う」で立てない")
  }
}
