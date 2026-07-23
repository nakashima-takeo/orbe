import SwiftUI

/// パレット内の focus 先。ちょうど 1 つに定まる（field＝入力欄 / card＝カード器）。
private enum PaletteFocus { case field, card }

/// パレットのカード本体（WorkspaceSwitcher の器）。ヘッダ行（◐＋クエリ/breadcrumb・
/// 下罫線。入力欄も breadcrumb も無ければ描かない）＋行リスト（padding 6・PaletteRow）＋
/// フッターヒント（上罫線）。
/// 外郭は GlassPanel(.panel α.72・radius 16)＋panel elevation。幅は呼び出し側（PaletteOverlay）が与える。
/// focus は単一の `@FocusState<PaletteFocus?>` に一本化し、入力欄（`TextField`）とカード器
/// （`.focusable()`）の間で移動するだけ。**両方の宛先を常設**するのがこの器の不変条件で
/// （入力欄の常設は `header` 参照）、モード切替が「既存ビュー間の focus 移動」に閉じ、
/// first responder の所在が常に一意になる。focus 確定は model の focusToken で駆動。
struct PaletteCard: View {
  @Bindable var model: PaletteModel
  @FocusState private var focus: PaletteFocus?

  /// 行リストの高さ上限（px）。これを超える行は内部スクロールへ。コンポーネント局所の定数
  /// （CompletionList.capHeight と同流儀。グローバルトークンは足さない）。
  private let capHeight: CGFloat = 320

  var body: some View {
    GlassPanel(level: .panel) {
      VStack(alignment: .leading, spacing: 0) {
        // ヘッダのスロットは入力欄と breadcrumb の 2 つ。両方空なら行ごと描かない
        // （他スロット同様「埋まっているものだけ描く」）。入力欄の常設（header 参照）はこの器の中で
        // 成り立つため、入力欄を出しうるパレットはヘッダを持ち続ける——`fieldVisible` が立つモードは
        // この条件を必ず満たし、入力欄なしモードも breadcrumb（‹ 親）を出すため、往復でヘッダは消えない。
        if model.fieldVisible || model.breadcrumb != nil {
          header
          divider
        }

        // 行ゼロ（入力欄だけのプロンプト＝改名・ディレクトリ・タブ改名）では行リストごと描かない。
        // 描くと 6pt パディングの空帯がヘッダ罫線と hint 罫線に挟まれ、中身ゼロの帯に見える。
        if !model.rows.isEmpty {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { i, row in
                  rowView(i, row)
                    .id(i)
                }
              }
            }
            .frame(maxHeight: capHeight)
            // ScrollView は走査軸に greedy で、上位（PaletteOverlay の全画面提案）から高さを目一杯
            // 取り cap まで伸びる。content 高でハグさせ cap 未満では余白を作らないため、垂直方向だけ
            // 内容サイズに固定する（cap 超過時は maxHeight が頭打ちし内部スクロールに入る）。
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.automatic)
            .onChange(of: model.selected) { proxy.scrollTo(model.selected) }
            .onAppear { proxy.scrollTo(model.selected) }
            .padding(Theme.Space.note)
          }
        }

        if !model.hint.isEmpty {
          divider
          Text(model.hint)
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
            .padding(.horizontal, Theme.Space.bar)
            .padding(.vertical, Theme.Space.step + Theme.Space.hair)
        }
      }
    }
    // カード器（.focusable()）を常設し、入力欄ありモードでカーソルに委ねるべきキーだけ器側で
    // .ignored を返す。宛先常設でモード切替が「既存ビュー間の focus 移動」になる。
    .modifier(CardKeyCapture(model: model, focus: $focus))
    .onChange(of: model.focusToken, initial: true) {
      focus = model.fieldVisible ? .field : .card
    }
  }

  private var divider: some View {
    Rectangle().fill(Color.theme.surface1).frame(height: Theme.Stroke.hairline)
  }

  /// ヘッダ行: ◐（glyphGradient）＋クエリ入力欄 or breadcrumb（‹ 親）。両スロット空のとき
  /// body 側が行ごと描かないため、ここへは少なくとも一方が埋まった状態で来る。
  ///
  /// **入力欄は `fieldVisible` に依らず常設する**（focus 宛先の常設＝この器の不変条件）。`fieldVisible` は
  /// 「見せて場所を取るか」だけを決め、mount の有無は決めない。宛先が同じ更新 pass で新規 mount されると
  /// SwiftUI はその pass で当てた `@FocusState` を取りこぼし、first responder が常設のカード器に残る
  /// ——↑↓（器が捕捉）だけ効き、←→↵（器が入力欄へ委ねて `.ignored` を返す）が誰にも届かない状態になる。
  /// 行間隔は spacing でなく各スロットの leading padding で作る（隠れた入力欄が余白を生まないため）。
  private var header: some View {
    HStack(spacing: 0) {
      Text("◐")
        .font(Font.theme.title)
        .foregroundStyle(Color.theme.glyphGradient)
      // 絞り込み欄とサブメニュー文脈（設定のフォント/テーマ/カーソル色等）は併存する。
      // breadcrumb を前置しないと絞り込み中に現在地表示が消える。入力欄と併存するときは副色で控えめに、
      // 単独のときは主色で幅一杯に置く。
      if let breadcrumb = model.breadcrumb {
        Text(breadcrumb)
          .font(Font.theme.title)
          .foregroundStyle(
            model.fieldVisible ? Color.theme.textSecondary : Color.theme.textPrimary
          )
          .lineLimit(1)
          .fixedSize(horizontal: model.fieldVisible, vertical: false)
          .frame(maxWidth: model.fieldVisible ? nil : .infinity, alignment: .leading)
          .padding(.leading, Theme.Space.beat)
      }
      queryField
        .padding(.leading, model.fieldVisible ? Theme.Space.beat : 0)
        .frame(maxWidth: model.fieldVisible ? .infinity : 0)
        .opacity(model.fieldVisible ? 1 : 0)
        .allowsHitTesting(model.fieldVisible)
      // ヘッダ右端の表示専用バッジ（Attention の ⌘⌘）。opt-in（nil の既存パレットは従来どおり）。
      if let badge = model.headerBadge {
        Text(badge)
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
          .padding(.horizontal, Theme.Space.step)
          .padding(.vertical, Theme.Space.hair)
          .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Color.theme.smallPillFill))
      }
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  /// 入力欄の双方向バインド。`onQueryChange`（＝「入力欄が編集された」）は **setter からだけ**呼ぶ。
  /// `.onChange(of: model.query)` は「値が変わった」に反応するため、パレットモデル自身の書き込み
  /// （モード遷移時に query を空へ戻す等）まで拾って再構築を誘発し、モデルが置いた選択（サブパレットの
  /// 現在値の行）を潰していた。setter ならモデル側の書き込みは getter しか通らず、跳ね返らない。
  private var queryBinding: Binding<String> {
    Binding(
      get: { model.query },
      set: { edited in
        guard edited != model.query else { return }
        model.query = edited
        model.onQueryChange()
      })
  }

  /// 絞り込み/改名の入力欄（純 SwiftUI `TextField`・裸のテキスト＝パレットのヘッダ様式）。
  private var queryField: some View {
    TextField("", text: queryBinding)
      .textFieldStyle(.plain)
      .font(Font.theme.title)
      .foregroundStyle(Color.theme.textPrimary)
      .focused($focus, equals: .field)
      // 純正 placeholder は色を握れず IME 変換中も消えないため、共通モディファイアで muted 描画しつつ
      // marked text がある間は抑制する。
      .imePlaceholder(
        model.placeholder, showWhenEmpty: model.query.isEmpty, focused: focus == .field,
        font: Font.theme.title, color: Color.theme.textMuted
      )
      .frame(maxWidth: .infinity)
      // 確定＝onSubmit（IME 変換確定の Enter では発火しない＝誤爆しない）。
      .onSubmit { model.onActivate() }
      // ↑↓＝一覧ナビ、⌘↑↓＝有効な先頭/末尾行へジャンプ、→＝ドリルイン（改名中はカーソルに委ねる）、Esc＝戻る。
      // ←＝filter 入力欄では戻る（onLeft）、editor 入力欄（改名）ではカーソル移動。
      // 矢印は単一の catch-all に集約し ⌘ 有無で分岐する（bare ハンドラが ⌘↑ を食う不確実性を構造で排除）。
      .onKeyPress { press in
        switch press.key {
        case .upArrow:
          if press.modifiers.contains(.command) { model.onJumpTop() } else { model.onUp() }
          return .handled
        case .downArrow:
          if press.modifiers.contains(.command) { model.onJumpBottom() } else { model.onDown() }
          return .handled
        default:
          return .ignored
        }
      }
      .onKeyPress(.rightArrow) { model.onRight() ? .handled : .ignored }
      .onKeyPress(.leftArrow) {
        guard model.fieldIsFilter else { return .ignored }
        model.onLeft()
        return .handled
      }
      // filter 入力欄でクエリが空のときだけ delete を継承解除（onDelete）へ回す。空欄 backspace は元々
      // no-op なので後退なく相乗りできる。非空・非 filter は TextField の backspace（文字削除）に委ねる。
      .onKeyPress(.delete) {
        guard model.fieldIsFilter, model.query.isEmpty else { return .ignored }
        model.onDelete()
        return .handled
      }
      .onKeyPress(.escape) {
        model.onEscape(); return .handled
      }
  }

  /// 1 行の描画。`customContent` があれば器（`SelectableRow`）へ直接流す（WS切替行・dormant 減光も乗せる）。無ければ `PaletteRow`。
  @ViewBuilder private func rowView(_ i: Int, _ row: PaletteModel.RowItem) -> some View {
    let selected = i == model.selected && row.enabled
    let tap: () -> Void = { model.onTapRow(i) }
    // ホバー開始で選択をその行へ追従（着色行を常に 1 つに）。モダリティ判定は hoverSelect が握る。
    let hoverEnter: () -> Void = { if row.enabled { model.hoverSelect(i) } }
    if let customContent = row.customContent {
      SelectableRow(selected: selected, action: tap, onHoverEnter: hoverEnter) { customContent }
        .opacity(row.dimmed && !selected ? Theme.Opacity.dormant : 1)
    } else {
      PaletteRow(
        title: row.label, selected: selected, showsChevron: row.chevron, kind: rowKind(row),
        inherited: row.inherited, leading: row.leading, detail: row.detail,
        trailingBadge: row.trailingBadge, action: tap, onHoverEnter: hoverEnter)
    }
  }

  private func rowKind(_ row: PaletteModel.RowItem) -> PaletteRow.Kind {
    if row.createStyle { return .createAction }
    if !row.enabled { return .info }
    return row.dimmed ? .dormant : .normal
  }
}

/// カード器を常設の first responder 候補にして ↑↓←→/↵/esc を捕捉する祖先 modifier。
/// 入力欄ありモードでは focus=.field のため子の TextField がキーを消費し、器へは
/// 子が消費しなかったキーだけ伝播する。入力欄に委ねるべき ←→（カーソル移動）と
/// ↵（IME 安全な onSubmit 確定）は fieldVisible のとき `.ignored` を返し、入力欄へ渡す。
private struct CardKeyCapture: ViewModifier {
  @Bindable var model: PaletteModel
  let focus: FocusState<PaletteFocus?>.Binding

  func body(content: Content) -> some View {
    content
      .focusable()
      .focusEffectDisabled()
      .focused(focus, equals: .card)
      // 矢印は単一の catch-all に集約し ⌘ 有無で先頭/末尾ジャンプと 1 行移動を分岐する。
      .onKeyPress { press in
        switch press.key {
        case .upArrow:
          if press.modifiers.contains(.command) { model.onJumpTop() } else { model.onUp() }
          return .handled
        case .downArrow:
          if press.modifiers.contains(.command) { model.onJumpBottom() } else { model.onDown() }
          return .handled
        default:
          return .ignored
        }
      }
      .onKeyPress(.leftArrow) {
        guard !model.fieldVisible else { return .ignored }
        model.onLeft(); return .handled
      }
      .onKeyPress(.rightArrow) {
        guard !model.fieldVisible else { return .ignored }
        _ = model.onRight(); return .handled
      }
      .onKeyPress(.return) {
        guard !model.fieldVisible else { return .ignored }
        model.onActivate(); return .handled
      }
      .onKeyPress(.delete) {
        guard !model.fieldVisible else { return .ignored }
        model.onDelete(); return .handled
      }
      .onKeyPress(.escape) {
        model.onEscape(); return .handled
      }
  }
}

/// フルウィンドウ overlay。Scrim（暗幕＋blur）＋上端 66px アンカーのカード。
/// カード幅= min(560, 窓幅−32)。scrim タップで閉じる。
struct PaletteOverlay: View {
  @Bindable var model: PaletteModel

  /// カード上端の窓上端からの距離・カードの基準幅（WorkspaceSwitcher）。
  private let topAnchor: CGFloat = 66
  private let cardWidth: CGFloat = 560

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .top) {
        Scrim(strength: model.scrimStrength)
          .contentShape(Rectangle())
          .onTapGesture { model.onScrimTap() }
        PaletteCard(model: model)
          .frame(width: min(cardWidth, geo.size.width - Theme.Space.bar * 2))
          .padding(.top, topAnchor)
          .frame(maxWidth: .infinity, alignment: .top)
      }
    }
    .ignoresSafeArea()
    // 実マウス移動（NSEvent .mouseMoved）だけを拾ってモダリティを .pointer に落とす透明レイヤ。
    // スクロールで行がカーソル下を横切る SwiftUI onHover と違い、mouseMoved は物理移動でのみ出る。
    .overlay(MouseMovedDetector { model.inputModality = .pointer })
  }
}

#if DEBUG
  /// cap＋内部スクロール＋行を狭めた見た目の検証用。18 行・チップ付き・選択は下方（onAppear の scrollTo 追従）。
  private func capPreviewModel(fieldVisible: Bool) -> PaletteModel {
    let model = PaletteModel()
    model.fieldVisible = fieldVisible
    model.placeholder = fieldVisible ? "Switch workspace / type to create" : ""
    model.hint =
      fieldVisible ? "↵ Switch/Create   → Details   esc Close" : "↵ Launch   → Details   esc Close"
    let rollups: [[(state: String, count: Int)]] = [
      [("working", 2), ("waiting", 1)], [("done", 4)], [], [("idle", 1)],
    ]
    model.rows = (0..<18).map { i in
      let name = "workspace-\(String(format: "%02d", i))"
      return .init(
        label: name, dimmed: i % 7 == 6,
        customContent: AnyView(
          WorkspaceSwitcherRow(
            name: name, rollup: rollups[i % rollups.count], path: "~/dev/\(name)")))
    }
    model.selected = 14
    return model
  }

  #Preview("PaletteCard — cap / scroll / slim") {
    HStack(alignment: .top, spacing: Theme.Space.phrase) {
      PaletteCard(model: capPreviewModel(fieldVisible: true))
      PaletteCard(model: capPreviewModel(fieldVisible: false))
    }
    .padding(Theme.Space.phrase)
    .frame(width: 820, height: 560)
    .background(Color.theme.bgSunken)
  }
#endif
