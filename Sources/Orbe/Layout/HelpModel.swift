import SwiftUI

/// ヘルプオーバーレイ（⌘H ショートカットチートシート）の描画状態。提示元（WindowController）が立て下げる。
@Observable final class HelpModel {
  /// サイドバーのカテゴリ選択。`top`＝基本操作（トップビュー）/ `all`＝すべて / `group`＝個別カテゴリ。
  enum Category: Hashable {
    case top
    case all
    case group(L10nKey)
  }

  /// 検索クエリ（ラベル・キー表記への部分一致）。
  var query = ""
  /// 選択中カテゴリ。検索・キー絞り込み中の「基本操作」は一覧ビューへ自動遷移する（`isTopView`）。
  var category: Category = .top
  /// キー絞り込み（キーボードのクリックで選んだ物理キー id）。ヘッダのチップで解除できる。
  var fkey: String?
  /// ホバー中の行（行 id と combo）。キーボード可視化の点灯に使う。
  var hoverRow: (id: String, combo: [String])?
  /// 実押下中のキー id 集合（表示中のみ NSEvent ローカルモニタが増減。キーボード点灯用）。
  var pressed: Set<String> = []
  /// 実押下が combo と完全一致してハイライト中の行 id 集合（同 combo の複数行は全行対象。
  /// キーボード点灯と同期して `syncPressedMatch` が立て下げる）。
  private(set) var pressedRowIDs: Set<String> = []
  /// 実押下一致で自動スクロールする行 id（カタログ順で最初の該当行。解放で nil）。
  private(set) var revealRowID: String?
  /// 検索欄へ focus を確定するためのトークン（描画後に `@FocusState` を立て直す）。
  private(set) var focusToken = 0
  /// 閉じ要求（esc / scrim クリック）。WindowController が dismissHelp を配線する。
  var onDismiss: () -> Void = {}

  func focus() { focusToken &+= 1 }

  /// 正規化済みクエリ（前後空白除去・小文字）。
  var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// トップビュー（基本操作）を出すか。「基本操作」でも検索・キー絞り込み中は一覧ビューへ
  /// 自動遷移し、クリアで自動的に戻る。
  var isTopView: Bool {
    category == .top && trimmedQuery.isEmpty && fkey == nil
  }

  /// 実押下の変化を行ハイライトへ同期する（pressed の変更点から呼ぶ）。
  /// 一致判定は正規化済み押下集合と combo の完全一致。現在のビューに該当行が無ければ
  /// 「すべて」一覧へ自動遷移し、検索・キー絞り込みが該当行を隠すときだけクリアして必ず見せる。
  /// キー解放ではビューを戻さない（押した答えを見続けられる）。
  func syncPressedMatch(_ l10n: LocalizationStore) {
    let combo = Set(pressed.map(Self.normalizedComboID))
    guard HelpCatalog.all.contains(where: { $0.rows.contains { Set($0.combo) == combo } }) else {
      pressedRowIDs = []
      revealRowID = nil
      return
    }
    if isTopView {
      let topIDs = HelpCatalog.topGroups.flatMap { group in
        group.rows.filter { Set($0.combo) == combo }
          .map { "top/\(group.title.rawValue)/\($0.key)" }
      }
      if !topIDs.isEmpty {
        pressedRowIDs = Set(topIDs)
        revealRowID = topIDs.first
        return
      }
      category = .all
    }
    var visible = matchedListIDs(combo, l10n)
    if visible.isEmpty {
      category = .all
      visible = matchedListIDs(combo, l10n)
    }
    if visible.isEmpty {
      query = ""
      fkey = nil
      visible = matchedListIDs(combo, l10n)
    }
    pressedRowIDs = Set(visible)
    revealRowID = visible.first
  }

  /// 現在の一覧ビュー（filteredGroups）に見えている該当行の id 列（カタログ順）。
  private func matchedListIDs(_ combo: Set<String>, _ l10n: LocalizationStore) -> [String] {
    filteredGroups(l10n).flatMap { group in
      group.rows.filter { Set($0.combo) == combo }.map { "\(group.title.rawValue)/\($0.key)" }
    }
  }

  /// 左右修飾キーの物理 id を combo 語彙へ正規化する（ctrl は配列側で合流済み）。
  private static func normalizedComboID(_ id: String) -> String {
    switch id {
    case "rcmd": "cmd"
    case "rshift": "shift"
    case "ropt": "opt"
    default: id
    }
  }

  /// 一覧ビューのグループ（検索 × カテゴリ × キー絞り込みの AND。空になったグループは落とす）。
  /// `top`（自動遷移中）と `all` は全カテゴリを対象にする。ラベルは現在言語で照合する。
  func filteredGroups(_ l10n: LocalizationStore) -> [HelpCatalog.Group] {
    let q = trimmedQuery
    return HelpCatalog.all
      .filter { group in
        switch category {
        case .top, .all: true
        case .group(let title): group.title == title
        }
      }
      .map { group in
        HelpCatalog.Group(
          title: group.title,
          rows: group.rows.filter { row in
            (q.isEmpty || l10n.string(row.label).lowercased().contains(q)
              || row.key.lowercased().contains(q))
              && (fkey == nil || row.combo.contains(fkey!))
          })
      }
      .filter { !$0.rows.isEmpty }
  }
}
