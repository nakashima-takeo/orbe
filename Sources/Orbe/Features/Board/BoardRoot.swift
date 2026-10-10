import SwiftUI

/// ボードの SwiftUI ルート。器（`BoardView`）の中の別 root なので環境は明示注入する。地は端末・エディター面と同じ veil。
/// 中身は上から部品（自動追加）とフッター。地のクリックはボードの当て直し（部品の最後に居た場所へ）を通るので、続けてキーが効く。
struct BoardRoot: View {
  let model: BoardModel
  let translucency: ChromeTranslucency
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    VStack(spacing: 0) {
      BoardIntakePart(model: model.intake)
        .padding(.top, Theme.Layout.boardInsetTop)
        .padding(.horizontal, Theme.Layout.boardInsetSide)
        .padding(.bottom, Theme.Space.phrase)
      BoardFooter(model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contentShape(Rectangle())
    .background(translucency.baseFill)
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }
}

/// 自動追加の部品: 見出し「タスクの自動追加 4 件」・依頼の欄・一覧（左 3）と詳細（右 2）。焦点の宛先は欄と一覧の器の 2 つで、
/// モデルの場所（`place`）を合図（`focusToken`）のたびに写す。クリックやキーで焦点が移れば、場所をモデルへ書き戻す——ボードの
/// 外へ出た（宛先が無くなった）ときは書き戻さず、戻ったときに最後に居た場所へ当て直せるようにする。
struct BoardIntakePart: View {
  let model: BoardIntakeModel
  @FocusState private var focused: BoardIntakeModel.Place?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.phrase) {
      VStack(alignment: .leading, spacing: Theme.Space.beat) {
        BoardIntakeHeading(model: model)
        BoardIntakeRequestField(model: model, focused: $focused)
      }
      // 時刻の文言（「今日」・「次 17:00」）を分の境で描き直す。時刻そのものは走らせ役の今から読む。
      TimelineView(.everyMinute) { _ in
        BoardIntakeColumns(model: model, focused: $focused)
      }
    }
    .onChange(of: model.focusToken, initial: true) { focused = model.place }
    .onChange(of: focused) { _, place in
      if let place { model.arrive(place) }
    }
    .onChange(of: model.store.intakes, initial: true) { model.reconcile() }
  }
}

/// 部品の見出し「タスクの自動追加 4 件」。
struct BoardIntakeHeading: View {
  let model: BoardIntakeModel
  @Environment(\.localization) private var l10n

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step + Theme.Space.hair) {
      Text(l10n.string(.boardIntakeTitle))
        .font(Font.theme.boardHeading)
        .foregroundStyle(Color.theme.textPrimary)
      Text(l10n.format(.boardIntakeCount, model.store.intakes.count))
        .font(Font.theme.boardValue)
        .foregroundStyle(Color.theme.textSecondary)
    }
    .frame(height: Theme.Typography.boardHeading.pointSize * Theme.Typography.lineBoardRow)
  }
}

/// 一覧（左 3）と詳細（右 2）。一覧の器は 0 件でも常に置く焦点の宛先で、一覧のキーはここで受ける。器のクリック（行・地）は一覧へ。
struct BoardIntakeColumns: View {
  let model: BoardIntakeModel
  let focused: FocusState<BoardIntakeModel.Place?>.Binding
  @Environment(\.localization) private var l10n

  var body: some View {
    let text = model.text(l10n)
    GeometryReader { geometry in
      let listWidth = (geometry.size.width - Theme.Layout.boardColumnGap) * 3 / 5
      HStack(alignment: .top, spacing: Theme.Layout.boardColumnGap) {
        Group {
          if model.standings.isEmpty {
            Text(l10n.string(.boardIntakeEmpty))
              .font(Font.theme.boardValue)
              .foregroundStyle(Color.theme.textMuted)
          } else {
            BoardIntakeList(model: model, text: text, maxHeight: geometry.size.height)
          }
        }
        .frame(width: listWidth, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { model.go(.list) }
        .focusable()
        .focusEffectDisabled()
        .focused(focused, equals: .list)
        .onKeyPress { model.handleKey($0) }
        if let selected = model.selected {
          BoardIntakeDetail(standing: selected, text: text)
        }
      }
    }
  }
}

/// 部品を 1 つも持たないボード: 中央に沈んだ一文。
struct BoardEmptyView: View {
  @Environment(\.localization) private var l10n

  var body: some View {
    Text(l10n.string(.boardEmpty))
      .font(Font.theme.editorLead)
      .foregroundStyle(Color.theme.textMuted)
  }
}
