import SwiftUI

/// ボードの SwiftUI ルート。器（`BoardView`）の中の別 root なので環境は明示注入する。地は端末・エディター面と同じ veil。
/// 中身は上から部品の並びとフッター。部品が無ければ中央の一文だけ。地のクリックはボードの当て直し（選んでいる場所へ）を通る
/// ので、続けてキーが効く。
struct BoardRoot: View {
  let model: BoardModel
  let translucency: ChromeTranslucency
  let localization: LocalizationStore
  let fontResolver: ChromeFontResolver

  var body: some View {
    Group {
      if model.parts.isEmpty {
        BoardEmptyView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: 0) {
          ForEach(model.parts, id: \.self) { part in
            BoardPartView(part: part, model: model)
              .frame(maxHeight: .infinity)
          }
          BoardFooter(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .contentShape(Rectangle())
    .background(translucency.baseFill)
    .simultaneousGesture(TapGesture().onEnded { model.refocus() })
    .environment(\.localization, localization)
    .environment(\.chromeFontResolver, fontResolver)
  }
}

/// 部品 1 つ。種類ごとの網羅の分岐で、種類が増えたときの描き忘れをコンパイラが止める。
struct BoardPartView: View {
  let part: BoardPart
  let model: BoardModel

  var body: some View {
    switch part {
    case .automation: BoardAutomationPart(board: model)
    }
  }
}

/// 自動化の部品: 上に全幅の依頼の欄、その下に左の一覧と右の欄（選んだ自動化の詳細か、欄を選んでいる間の案内）。焦点の宛先は
/// 欄と一覧の器の 2 つで、場所の正はモデル（`place`）だけ。届いていない合図（`focusToken`）はボードを通して受け取って写し
/// （現れただけでは写さず、焦点がボードの外にあれば捨てる）、SwiftUI が自分で焦点を動かした（窓が key になったときの既定の
/// 焦点など）ら、モデルの場所へ戻す。クリックはジェスチャがモデルへ届ける。ストアの変化で場所が替わった（行がすべて消えて欄に
/// なった）ときは、焦点が部品の中にあるときだけ追う（外にある焦点を奪わない）。
struct BoardAutomationPart: View {
  let board: BoardModel
  @FocusState private var focused: BoardAutomationModel.Place?

  private var model: BoardAutomationModel { board.automation }

  var body: some View {
    VStack(spacing: 0) {
      BoardAutomationRequestField(model: model, focused: $focused)
      // 時刻の文言（「今日」・「次回 17:00」）を分の境で描き直す。今は分の境ごとに走らせ役から 1 回読み、中身の入力として渡す
      // （入力が変わらなければ SwiftUI は中身を描き直さない）。
      TimelineView(.everyMinute) { _ in
        BoardAutomationColumns(model: model, now: model.runner.now(), focused: $focused)
      }
    }
    .onChange(of: model.focusToken, initial: true) {
      if let place = board.takeFocusRequest() { focused = place }
    }
    .onChange(of: model.place) { _, place in
      if focused != nil { focused = place }
    }
    .onChange(of: focused) { _, place in
      if let place, place != model.place { focused = model.place }
    }
    .onChange(of: model.store.automations, initial: true) { model.reconcile() }
  }
}

/// 左の一覧と右の欄。右は自動化を選んでいる間はその詳細、欄を選んでいる間は案内と入力例（0 件でも選べるのは欄だけなので
/// 案内）。一覧の器は 0 件でも常に置く焦点の宛先で、一覧のキーはここで受ける。器のクリック（行・地）は一覧へ。並び・文は
/// `now` から計算する。
struct BoardAutomationColumns: View {
  let model: BoardAutomationModel
  let now: Date
  let focused: FocusState<BoardAutomationModel.Place?>.Binding
  @Environment(\.localization) private var l10n

  var body: some View {
    let text = model.text(l10n, now: now)
    let standings = model.standings(at: now)
    HStack(spacing: 0) {
      BoardAutomationList(model: model, standings: standings, text: text)
        .contentShape(Rectangle())
        .onTapGesture { model.go(.list) }
        .focusable()
        .focusEffectDisabled()
        .focused(focused, equals: .list)
        .onKeyPress { model.handleKey($0) }
      if case .automation(let id) = model.list.selectedID,
        let standing = standings.first(where: { $0.id == id }),
        let summary = model.summary(id, text: text)
      {
        BoardAutomationDetail(standing: standing, summary: summary, text: text)
      } else {
        BoardAutomationGuide()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
