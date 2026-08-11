import XCTest

@testable import Orbe

/// ⌘H ヘルプの静的カタログの内部整合を機械保証する（掲載内容そのものは手動棚卸しが正）。
/// combo が物理配列に実在し、トップ厳選がカテゴリ行の部分集合で、表示キーが全体で一意である
/// ことを固定する（どれかが崩れるとキーボード点灯・絞り込み・行 identity が静かに壊れる）。
/// 例外として、タブ左右移動の「矢印が主・括弧が従」だけは提示の意思決定そのものなので具体キーで固定する。
final class HelpCatalogTests: OrbeTestCase {
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

  /// タブ左右移動は矢印が主・括弧が従。トップ厳選には矢印だけを載せ、一覧でも矢印 2 行を括弧 2 行より先に置く。
  func testTabTraversalPrefersArrowsOverBrackets() {
    let picks = HelpCatalog.topPicks[.helpCatWorkspaceTabsPanes] ?? []
    XCTAssertTrue(picks.contains("⌘⇧→"), "トップ厳選のタブ移動が矢印 ⌘⇧→ でない")
    XCTAssertFalse(picks.contains("⌘⇧]"), "トップ厳選に括弧 ⌘⇧] が載っている")

    guard let group = HelpCatalog.all.first(where: { $0.title == .helpCatWorkspaceTabsPanes })
    else {
      return XCTFail("カテゴリ helpCatWorkspaceTabsPanes が all に無い")
    }
    let traversal = ["⌘⇧→", "⌘⇧←", "⌘⇧]", "⌘⇧["]
    XCTAssertEqual(
      group.rows.map(\.key).filter(traversal.contains), traversal,
      "一覧のタブ移動 4 行が 矢印 → 括弧 の順に並んでいない")
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

  /// 棚卸しの総数（28）と「すべて」件数の導出が一致する。
  func testTotalCount() {
    XCTAssertEqual(HelpCatalog.totalCount, 28)
    XCTAssertEqual(HelpCatalog.all.map(\.rows.count), [4, 12, 4, 8])
  }

  /// ⌘⌘（Attention パレット）は画面のどこにも書けない発見不能なジェスチャなので、
  /// 一覧とトップ厳選の両方に必ず載せる（可視の入口はヘルプだけ＝提示の意思決定）。
  func testAttentionGestureIsListedAndTopPicked() {
    guard let agents = HelpCatalog.all.first(where: { $0.title == .helpCatAgents }) else {
      return XCTFail("カテゴリ helpCatAgents が all に無い")
    }
    guard let row = agents.rows.first(where: { $0.key == "⌘⌘" }) else {
      return XCTFail("⌘⌘ の行が エージェント カテゴリに無い")
    }
    XCTAssertEqual(row.combo, ["cmd"], "⌘⌘ の点灯は ⌘ キーそのもの")
    XCTAssertTrue(
      HelpCatalog.topPicks[.helpCatAgents]?.contains("⌘⌘") == true,
      "発見不能な ⌘⌘ がトップ厳選に載っていない")
  }

  /// usedKeys は combo の全網羅（キーボードの明暗・クリック可否の SSOT）。
  func testUsedKeysDerivation() {
    XCTAssertTrue(HelpCatalog.usedKeys.contains("cmd"))
    XCTAssertTrue(HelpCatalog.usedKeys.contains("shift"))
    XCTAssertTrue(HelpCatalog.usedKeys.isSubset(of: keyboardIDs), "usedKeys に KB 外の id がある")
    // 修飾のみの combo は ⌘⌘（⌘ の素タップ×2）だけ——修飾は単独では実行キーになりえず、
    // 例外はこのジェスチャに限る（増えたら実バインドの棚卸し漏れを疑う）。
    let modifierOnly = HelpCatalog.all.flatMap { $0.rows }
      .filter { Set($0.combo).isSubset(of: HelpCatalog.modifierKeys) }
      .map(\.key)
    XCTAssertEqual(modifierOnly, ["⌘⌘"], "修飾キーのみの combo は ⌘⌘ 以外に存在しない")
  }
}
