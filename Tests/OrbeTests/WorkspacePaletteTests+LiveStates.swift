import XCTest

@testable import Orbe

/// 表示中の workspace パレットに届く「タブ集合から導く現在値」の差し替え（`updateLiveStates`）。
/// 構造スナップショット（`setItems`）と違い、モード・絞り込み・選択カーソル・focus に触れない。
extension WorkspacePaletteTests {
  // MARK: - live 追随（表示中に届く agent 状態変化）

  /// 構造は据え置き・現在値だけを差し替える入口。行順は起源固定＋MRU で決まるため `index`
  /// （workspace 配列 offset）は行位置と一致しない——`updateLiveStates` の `states` は行順ではなく
  /// offset で引く。休眠＋復元チケット 2 枚を持つのは行 1 の api-infra（offset 2）。
  private func liveItems() -> [WorkspacePaletteModel.Item] {
    [
      WorkspacePaletteModel.Item(
        index: 0, name: "api", isActive: true, dir: "/",
        live: .init(rollup: [], dormant: false)),
      WorkspacePaletteModel.Item(
        index: 2, name: "api-infra", isActive: false, dir: "/",
        live: .init(rollup: [(state: "dormant", count: 2)], dormant: true)),
      WorkspacePaletteModel.Item(
        index: 1, name: "docs", isActive: false, dir: "/",
        live: .init(rollup: [], dormant: false)),
    ]
  }

  func testUpdateLiveStatesRefreshesChipsWithoutDisturbingFilterSelectionOrFocus() {
    let p = palette()
    p.setItems(liveItems())
    type(p, "api")  // api / api-infra が残る
    send(p, down)  // 選択を api-infra へ
    let token = p.render.focusToken
    let rowCount = p.render.rows.count

    p.updateLiveStates([  // offset 順: api / docs / api-infra
      .init(rollup: [], dormant: false),
      .init(rollup: [], dormant: false),
      .init(rollup: [(state: "working", count: 1), (state: "dormant", count: 1)], dormant: false),
    ])

    XCTAssertEqual(p.items[1].live.rollup.map(\.state), ["working", "dormant"])
    XCTAssertEqual(p.items[1].live.rollup.map(\.count), [1, 1])
    XCTAssertFalse(p.render.rows[1].dimmed, "1 枚起きた workspace の行は減光が解ける")
    XCTAssertEqual(p.render.rows.count, rowCount, "行数は構造と絞り込みだけで決まる")
    XCTAssertEqual(p.render.query, "api")
    XCTAssertEqual(p.render.selected, 1)
    XCTAssertEqual(p.render.focusToken, token, "live 更新は focus を確定し直さない")
    XCTAssertTrue(p.render.fieldVisible, "一覧モードのまま")

    p.updateLiveStates([  // offset 順: api / docs / api-infra
      .init(rollup: [], dormant: false),
      .init(rollup: [], dormant: false),
      .init(rollup: [], dormant: true),  // 最後の live タブが消えた
    ])
    XCTAssertTrue(p.items[1].live.rollup.isEmpty, "0 件になったチップは消える")
    XCTAssertTrue(p.render.rows[1].dimmed, "起床済みタブが尽きた行は再び減光する")
    XCTAssertEqual(p.render.selected, 1)
    XCTAssertEqual(p.render.query, "api")
  }

  func testUpdateLiveStatesKeepsSubmenuAndShowsNewChipsOnReturn() {
    let p = palette()
    p.setItems(liveItems())
    send(p, down)  // api-infra 行
    send(p, right)  // 詳細メニューへ潜る
    XCTAssertEqual(p.render.breadcrumb, "‹ api-infra")

    p.updateLiveStates([  // offset 順: api / docs / api-infra
      .init(rollup: [], dormant: false),
      .init(rollup: [], dormant: false),
      .init(rollup: [(state: "working", count: 1)], dormant: false),
    ])

    XCTAssertEqual(p.render.breadcrumb, "‹ api-infra", "live 更新は詳細メニューから引き戻さない")
    XCTAssertFalse(p.render.fieldVisible)

    key(p, kLeft)  // 一覧へ戻る
    XCTAssertEqual(p.items[1].live.rollup.map(\.state), ["working"])
    XCTAssertFalse(p.render.rows[1].dimmed, "戻った一覧に最新の現在値が出る")
  }

  /// 改名入力中に届く live 更新は、打ちかけの名前も改名の宛先も動かさない（構造の再読込を流用すると
  /// 一覧へ引き戻され、入力中の文字列が消える）。
  func testUpdateLiveStatesKeepsRenameInputAndCommitTarget() {
    let p = palette()
    var renamed: (Int, String)?
    p.onRename = { renamed = ($0, $1) }
    p.setItems(liveItems())
    send(p, down)  // api-infra 行
    send(p, right)  // 詳細メニューへ潜る
    key(p, kReturn)  // 改名モード（現名プリフィル）
    type(p, "api-infra-2")  // 打ちかけの新名

    p.updateLiveStates([  // offset 順: api / docs / api-infra
      .init(rollup: [], dormant: false),
      .init(rollup: [], dormant: false),
      .init(rollup: [(state: "working", count: 1)], dormant: false),
    ])

    XCTAssertEqual(p.render.query, "api-infra-2", "打ちかけの名前を live 更新が消さない")
    XCTAssertTrue(p.render.rows.isEmpty, "改名モードのまま（一覧へ引き戻されない）")

    send(p, enter)
    XCTAssertEqual(renamed?.0, 2, "改名の宛先は潜った先の workspace（行位置ではなく offset）のまま")
    XCTAssertEqual(renamed?.1, "api-infra-2")
  }
}
