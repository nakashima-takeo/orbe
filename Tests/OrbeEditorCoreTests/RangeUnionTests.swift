import Foundation
import XCTest

@testable import OrbeEditorCore

/// 一致の地の 2 つの出どころ（ファイル内検索とプロジェクト検索）の和——昇順で、重なる区間は 1 つにまとめる。
///
/// 壊れると何が起きるか。⌘F とプロジェクト検索の両方に当たる一致に地が二重に敷かれる、昇順を前提にする面と俯瞰が
/// 地を取りこぼす。
final class RangeUnionTests: XCTestCase {
  func testTheUnionIsAscendingWithOverlapsMerged() {
    let find = [NSRange(location: 0, length: 3), NSRange(location: 10, length: 3)]
    let project = [
      NSRange(location: 4, length: 2), NSRange(location: 11, length: 4),
      NSRange(location: 20, length: 1),
    ]
    XCTAssertEqual(
      RangeUnion.union(find, project),
      [
        NSRange(location: 0, length: 3), NSRange(location: 4, length: 2),
        NSRange(location: 10, length: 5), NSRange(location: 20, length: 1),
      ])
    XCTAssertEqual(RangeUnion.union(project, find), RangeUnion.union(find, project))
    XCTAssertEqual(RangeUnion.union([], project), project)
    XCTAssertEqual(RangeUnion.union(find, []), find)
  }
}
