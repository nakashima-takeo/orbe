import SwiftUI

/// 状態一覧に出す状態の表示ラベル（アイコン設定の文脈での状態名）。文言は現在言語で引く。
private func agentStateLabel(_ kind: AgentStateIcon.Kind, _ l10n: LocalizationStore) -> String {
  switch kind {
  case .working: return l10n.string(.agentStateWorking)
  case .waiting: return l10n.string(.agentStateWaiting)
  case .done: return l10n.string(.agentStateDone)
  case .idle: return l10n.string(.agentStateIdle)
  case .dormant: return l10n.string(.agentStateDormant)
  }
}

/// サブパレット（theme / agent / font）の行組み立て。本体（状態機械）から分離する。
///
/// 3 モードに共通する不変条件: `●`（現在値マーカー）と初期ハイライト（選択色）は `currentRowIndex`
/// 1 本から出す。ここが確定させる「現在値」は常に**そのスコープの実効値**（agent は解決済みデフォルト）
/// であり、↵ の着地点と一致する。
extension SettingsPaletteModel {
  /// theme: Auto / Dark / Light の固定3行（絞り込み欄なし・見本 Settings 画面の Seg 順）。
  /// 現在値は実効テーマ（nil＝Auto へ解決・スコープ依存）。
  func rebuildTheme() {
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = localization.string(.settingsThemeBreadcrumb)
    render.placeholder = ""
    render.hint = localization.string(.settingsSubHintApply)
    currentRowIndex = Self.themeModes.firstIndex(of: values.effTheme)
    render.rows = Self.themeModes.indices.map {
      PaletteModel.RowItem(label: marker($0) + Self.themeModes[$0].label)
    }
  }

  /// emojiFont: Noto（同梱）/ Apple（システム）の固定2行（絞り込み欄なし・theme と同型）。
  /// 現在値は実効値（未設定＝noto へ解決・スコープ依存）。
  func rebuildEmojiFont() {
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = localization.string(.settingsEmojiFontBreadcrumb)
    render.placeholder = ""
    render.hint = localization.string(.settingsSubHintApply)
    currentRowIndex = Self.emojiFontModes.firstIndex(of: values.effEmojiFont)
    render.rows = Self.emojiFontModes.enumerated().map { i, mode in
      PaletteModel.RowItem(label: marker(i) + localization.string(mode.labelKey))
    }
  }

  /// agent: 検出済み CLI の行（絞り込み欄なし・検出ゼロは情報行 1 つ）。
  /// 現在値は解決済みデフォルト＝実際に起動される agent（起動パレットの ● と同じキー）。
  func rebuildAgent() {
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = localization.string(.settingsAgentBreadcrumb)
    render.placeholder = ""
    render.hint = localization.string(.settingsSubHintApply)
    currentRowIndex = resolvedAgent.flatMap { agents.firstIndex(of: $0) }
    render.rows =
      agents.isEmpty
      ? [
        PaletteModel.RowItem(label: localization.string(.agentNotFoundCLI), enabled: false)
      ]
      : agents.indices.map { PaletteModel.RowItem(label: marker($0) + agents[$0]) }
  }

  /// font: 絞り込み欄あり。クエリ空のときだけ先頭に解除行（`fontFamily(nil)`＝その ↵ がそのスコープで
  /// 着地する値を名乗る固定行。global は既定の実フォント名、workspace は継承先の global 値）、続いて
  /// 等幅カタログの名前行。0 件・列挙不能は情報行 1 つ。
  func rebuildFont() {
    rebuildFontFilter(
      names: fontNames, breadcrumb: localization.string(.settingsFontBreadcrumb),
      resetLabel: values.fontResetRowLabel(localization), current: values.effFontFamily)
  }

  /// tabTitleFont: font と同じ filter 基盤で、等幅制限なしの全 family を列挙する。解除行は
  /// 「既定（システム等幅）」（global）/「グローバルを継承（…）」（workspace）を名乗る。
  /// `orb config set` 由来の解決不能名は表示中リストに無いため ● は出ない（描画は既定へ退避済み）。
  func rebuildTabTitleFont() {
    rebuildFontFilter(
      names: allFontNames, breadcrumb: localization.string(.settingsTabTitleFontBreadcrumb),
      resetLabel: values.tabTitleFontResetRowLabel(localization),
      current: values.effTabTitleFontFamily)
  }

  /// filter 型フォントサブ（font / tabTitleFont）の共通行組み立て。
  ///
  /// 現在値（● と初期ハイライトの行）は実効値の解決に一致させる:
  /// - 未設定（`current == nil`）→ 解除行（index 0）。カタログに既定フォントが並んでいても
  ///   その名前行には付けない（↵ の着地点は「未設定のまま」＝余計な書き込みを起こさない）。
  /// - 設定済み → 表示中リストのその名前の行。
  /// - 絞り込み中は解除行が出ないため、未設定なら現在値の行は無い（nil＝選択は先頭）。
  ///
  /// 選択 index → 名前の対応（`fontRows`）と解除行の有無（`fontDefaultRowVisible`）も確定させる
  /// （↵ の確定が offset 計算に使う）。絞り込みはプレフィクス付きラベルでなく元の名前に対して行う。
  private func rebuildFontFilter(
    names: [String], breadcrumb: String, resetLabel: String, current: String?
  ) {
    render.fieldVisible = true
    render.fieldIsFilter = true  // filter 入力欄＝← で戻る（カーソル移動は不要）
    render.breadcrumb = breadcrumb
    render.placeholder = localization.string(.settingsFontFilterPlaceholder)
    render.hint = localization.string(.settingsFontHint)

    guard !names.isEmpty else {
      fontRows = []
      fontDefaultRowVisible = false
      currentRowIndex = nil
      render.rows = [
        PaletteModel.RowItem(label: localization.string(.settingsNoFonts), enabled: false)
      ]
      return
    }
    let query = render.query.trimmingCharacters(in: .whitespaces)
    fontRows =
      query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    fontDefaultRowVisible = query.isEmpty
    let offset = fontDefaultRowVisible ? 1 : 0  // 解除行のぶん、名前行の index がずれる
    currentRowIndex =
      if let current {
        fontRows.firstIndex(of: current).map { $0 + offset }
      } else {
        fontDefaultRowVisible ? 0 : nil
      }

    var rows: [PaletteModel.RowItem] = []
    if fontDefaultRowVisible {
      rows.append(PaletteModel.RowItem(label: marker(0) + resetLabel))
    }
    if fontRows.isEmpty {
      rows.append(
        PaletteModel.RowItem(label: localization.string(.settingsNoMatchingFonts), enabled: false))
    } else {
      rows += fontRows.indices.map {
        PaletteModel.RowItem(label: marker($0 + offset) + fontRows[$0])
      }
    }
    render.rows = rows
  }

  /// agentStates: 5 状態の一覧（絞り込み欄なし・各行にその状態の実効グリフをプレビュー）。
  /// 現在値マーカーは持たない（状態一覧は選ぶ対象＝アイコンでなく状態のため ● は無い）。
  func rebuildAgentStates() {
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = localization.string(.settingsAgentIconsBreadcrumb)
    render.placeholder = ""
    render.hint = localization.string(.settingsSubHintOpen)
    currentRowIndex = nil
    render.rows = AgentStateIcon.Kind.allCases.map { kind in
      PaletteModel.RowItem(
        label: agentStateLabel(kind, localization) + "  " + statePreviewLabel(kind),
        chevron: true,
        leading: AnyView(
          StatusGlyphView(kind: kind, size: 14, symbol: values.effSymbol(for: kind))))
    }
  }

  /// 状態行の現在アイコン表示（Glass 既定 or symbol 名）。root 要約と同じ語彙の粒度に合わせる。
  private func statePreviewLabel(_ kind: AgentStateIcon.Kind) -> String {
    values.effSymbol(for: kind) ?? localization.string(.settingsGlassDefault)
  }

  /// agentIcon: ある状態のアイコン候補（絞り込み欄なし）。先頭に Glass（既定・nil）、続いて curated symbol。
  /// 現在値（●・初期ハイライト）は実効 symbol の行（未設定なら Glass 行 index 0）。
  func rebuildAgentIcon(kind: AgentStateIcon.Kind) {
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = "‹ " + agentStateLabel(kind, localization)
    render.placeholder = ""
    render.hint = localization.string(.settingsSubHintApply)
    let symbols = AgentStateIcon.curatedSymbols[kind] ?? []
    currentRowIndex =
      values.effSymbol(for: kind).flatMap { symbols.firstIndex(of: $0).map { $0 + 1 } } ?? 0
    var rows: [PaletteModel.RowItem] = [
      PaletteModel.RowItem(
        label: marker(0) + localization.string(.settingsGlassDefault),
        leading: AnyView(StatusGlyphView(kind: kind, size: 14)))
    ]
    rows += symbols.indices.map { i in
      PaletteModel.RowItem(
        label: marker(i + 1) + symbols[i],
        leading: AnyView(StatusGlyphView(kind: kind, size: 14, symbol: symbols[i])))
    }
    render.rows = rows
  }

  /// language: ja / en の固定2行（絞り込み欄なし）。現在値は実効 UI 言語。↵ で確定し提示元へ通知する。
  func rebuildLanguage() {
    render.fieldVisible = false
    render.fieldIsFilter = false
    render.breadcrumb = localization.string(.settingsLanguageBreadcrumb)
    render.placeholder = ""
    render.hint = localization.string(.settingsSubHintApply)
    currentRowIndex = Language.allCases.firstIndex(of: localization.language)
    render.rows = Language.allCases.indices.map {
      PaletteModel.RowItem(label: marker($0) + Language.allCases[$0].displayName)
    }
  }

  /// 現在値マーカーのプレフィクス。`currentRowIndex` だけを読む（値と直接比較する箇所を作らない＝
  /// ● とハイライトが食い違わない）。非現在値は同じ幅の 2 スペースで列を揃える。
  private func marker(_ row: Int) -> String { row == currentRowIndex ? "● " : "  " }
}
