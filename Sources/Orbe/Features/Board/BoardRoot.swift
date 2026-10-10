import SwiftUI

/// ボードの SwiftUI ルート。器（`BoardView`）の中の別 root なので環境は明示注入する。地は端末・エディター面と同じ veil。
/// 中身は上から見出し・部品（自動追加の一覧と詳細）・フッター。焦点の宛先は一覧の器 1 つで、モデルの合図
/// （`focusToken`）から写す。どこをクリックしても同じ当て直しを通るので、続けてキーが効く。
struct BoardRoot: View {
  let model: BoardModel
  let translucency: ChromeTranslucency
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Theme.Space.phrase) {
        BoardIntakeHeading(model: model.intake)
        // 時刻の文言（「今日」・「次 17:00」）を分の境で描き直す。時刻そのものは走らせ役の今から読む。
        TimelineView(.everyMinute) { _ in
          BoardIntakePart(model: model.intake, focused: $focused)
        }
      }
      .padding(.top, Theme.Layout.boardInsetTop)
      .padding(.horizontal, Theme.Layout.boardInsetSide)
      .padding(.bottom, Theme.Space.phrase)
      BoardFooter(model: model.intake)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contentShape(Rectangle())
    .background(translucency.baseFill)
    .simultaneousGesture(TapGesture().onEnded { model.focus() })
    .onChange(of: model.focusToken, initial: true) { focused = true }
    .onChange(of: model.intake.store.intakes, initial: true) { model.intake.reconcile() }
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
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
  }
}

/// 自動追加の部品: 一覧（左 3）と詳細（右 2）。一覧の器は 0 件でも常に置く焦点の宛先で、キーはここで受ける。
struct BoardIntakePart: View {
  let model: BoardIntakeModel
  let focused: FocusState<Bool>.Binding
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
        .focusable()
        .focusEffectDisabled()
        .focused(focused)
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
