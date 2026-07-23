import XCTest

@testable import Orbe

/// ⌘H ヘルプの静的カタログの内部整合を機械保証する（掲載内容そのものは手動棚卸しが正）。
/// combo が物理配列に実在し、トップ厳選がカテゴリ行の部分集合で、表示キーが全体で一意である
/// ことを固定する（どれかが崩れるとキーボード点灯・絞り込み・行 identity が静かに壊れる）。
final class HelpCatalogTests: XCTestCase {
  private var keyboardIDs: Set<String> {
    Set(HelpCatalog.keyboard.flatMap { $0.map(\.id) })
  }

  /// 全行の combo id がキーボード物理配列に存在する（点灯・クリック絞り込みの宛先が実在する）。
  func testCombosResolveToKeyboardKeys() {
    let ids = keyboardIDs
    for group in HelpCatalog.all {
      for row in group.rows {
        for id in row.combo {
          XCTAssertTrue(ids.contains(id), "\(row.key) の combo id \(id) が KB 配列に無い")
        }
        XCTAssertFalse(row.combo.isEmpty, "\(row.key) の combo が空")
      }
    }
  }

  /// トップビュー厳選キーが該当カテゴリの行の部分集合である（導出 topGroups が欠落しない）。
  func testTopPicksAreSubsetOfCategoryRows() {
    for (title, keys) in HelpCatalog.topPicks {
      guard let group = HelpCatalog.all.first(where: { $0.title == title }) else {
        XCTFail("厳選カテゴリ \(title) が all に無い")
        continue
      }
      let rowKeys = Set(group.rows.map(\.key))
      for key in keys {
        XCTAssertTrue(rowKeys.contains(key), "厳選 \(key) がカテゴリ \(title) の行に無い")
      }
    }
    // 導出 topGroups は厳選と同数の行を持つ（filter の取りこぼし検出）。
    let derived = HelpCatalog.topGroups.reduce(0) { $0 + $1.rows.count }
    let picked = HelpCatalog.topPicks.values.reduce(0) { $0 + $1.count }
    XCTAssertEqual(derived, picked, "topGroups の行数が厳選数と一致しない")
  }

  /// 表示キーは全カテゴリ横断で一意（行 identity・キー絞り込みの衝突防止）。
  func testDisplayKeysAreUnique() {
    let keys = HelpCatalog.all.flatMap { $0.rows.map(\.key) }
    XCTAssertEqual(keys.count, Set(keys).count, "表示キーが重複している")
  }

  /// キーボード物理配列の id も一意（点灯集合・クリック判定の前提）。
  func testKeyboardIDsAreUnique() {
    let ids = HelpCatalog.keyboard.flatMap { $0.map(\.id) }
    XCTAssertEqual(ids.count, Set(ids).count, "KB 配列の id が重複している")
  }

  /// 棚卸しの総数（29）と「すべて」件数の導出が一致する。
  func testTotalCount() {
    XCTAssertEqual(HelpCatalog.totalCount, 29)
    XCTAssertEqual(HelpCatalog.all.map(\.rows.count), [3, 8, 7, 3, 8])
  }

  /// usedKeys は combo の全網羅（キーボードの明暗・クリック可否の SSOT）。
  func testUsedKeysDerivation() {
    XCTAssertTrue(HelpCatalog.usedKeys.contains("cmd"))
    XCTAssertTrue(HelpCatalog.usedKeys.contains("shift"))
    XCTAssertTrue(HelpCatalog.usedKeys.isSubset(of: keyboardIDs), "usedKeys に KB 外の id がある")
    // 修飾のみの組合せは存在しない＝どの行も非修飾キーを 1 つ以上含む。
    for group in HelpCatalog.all {
      for row in group.rows {
        XCTAssertFalse(
          Set(row.combo).isSubset(of: HelpCatalog.modifierKeys),
          "\(row.key) が修飾キーのみの combo")
      }
    }
  }
}
