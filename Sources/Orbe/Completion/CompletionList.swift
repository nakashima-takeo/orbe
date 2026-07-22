import SwiftUI

/// 補完ドロップダウンの表示状態（表示順に並べ替え済みの候補・選択 index・入力済みプレフィックス）。
/// host が update/moveSelection で更新する。
@MainActor @Observable final class CompletionListModel {
  var choices: [CompletionChoice] = []
  var selected = 0
  /// 現在トークンの入力済み部分。候補値の先頭一致部を accent 色で示す（Autocomplete）。
  var query = ""
}

/// 候補の種別。fig の suggestion `type` のみから導出する（description 文字列には結合しない＝git 固有判定を避ける）。
/// 表示グループ順とサイドカードのグリフの SSOT。
enum CompletionKind: CaseIterable {
  case subcommand
  case argument
  case path
  case option

  /// fig type 文字列から種別を導出。type を持たない候補（generator 出力等）は `.argument` に落ちる。
  static func from(_ type: String?) -> CompletionKind {
    switch type {
    case "option": return .option
    case "subcommand": return .subcommand
    case "file", "folder": return .path
    default: return .argument
    }
  }

  /// 表示グループ順（位置候補を先・修飾子を後）。
  var order: Int {
    switch self {
    case .subcommand: return 0
    case .argument: return 1
    case .path: return 2
    case .option: return 3
    }
  }
}

/// ドロップダウンの宣言的レイアウト（Autocomplete＝素の候補リスト）。
/// 各行はテキストのみ（mono 11.5・padding 1×6・radius 5）・入力済みプレフィックスを accent 色で示す・
/// 選択行は selectionFill の淡塗り＋text.primary。説明はインライン列を持たず side card だけが持つ。
/// 幅は内容にフィット（最長候補で決まる・上限 280）。見出し・フッターは持たない。
/// 候補は engine から全件受け取るが、可視 ~7 行（`capHeight`）ぶんだけを**仮想描画**する
/// （react-window / inshellisense の「窓だけ描画」同型）——`scrollY`／`capHeight` から可視インデックス
/// 範囲を算出し、その行だけ生成する。数百件でも生成行は十数行に収まる。
/// スライスは `-scrollY` 相当の offset を当て外側を clip し、右に細いつまみ＋下端フェードを重ねる。
/// `scrollY` は `model.selected` から派生のみで算出し（格納状態を持たない）、選択行が常に可視域に入る。
/// focusable な要素を持たない（端末がフォーカスを維持する）。
/// 外郭は GlassPanel(.popup・radius 8)＋popup 影。scrim を持たず端末に重なる。
struct CompletionList: View {
  @Bindable var model: CompletionListModel
  /// 背景透過（既定は不透明＝preview は現行のガラスカード）。CompletionController が実ホルダーを渡す。
  var translucency = ChromeTranslucency()

  // 寸法は Autocomplete 固有（コンポーネント局所。グローバルトークンは追加しない）。
  private static let rowHeight: CGFloat = 20  // fontSize 11.5＋padding 縦1×2＋行間
  private static let minWidth: CGFloat = 64  // 極端に短い候補でも掴める下限
  private static let maxWidth: CGFloat = 280  // 極長候補の上限（内容 fit の頭打ち）
  private static let capHeight: CGFloat = 148  // 可視 ~7 行の打ち切り高
  private static let scrollbarWidth: CGFloat = 3
  private static let fadeHeight: CGFloat = 26

  /// engine 由来の flat 候補を表示グループ順（種別順・グループ内は元順序を保つ）に並べ替える。
  /// controller が update 時に 1 度だけ適用し、選択 index はこの並びの上で回る。
  static func displayOrdered(_ choices: [CompletionChoice]) -> [CompletionChoice] {
    choices.enumerated()
      .sorted { a, b in
        let ka = CompletionKind.from(a.element.type).order
        let kb = CompletionKind.from(b.element.type).order
        return ka != kb ? ka < kb : a.offset < b.offset
      }
      .map(\.element)
  }

  /// パネル幅＝内容フィット（最長候補の実測幅＋行余白。min/max で clamp・決定的）。
  private var panelWidth: CGFloat {
    let font = Theme.Typography.codeCompact
    let longest =
      model.choices
      .map { ceil(($0.value as NSString).size(withAttributes: [.font: font]).width) }
      .max() ?? 0
    // 行 padding 6×2 ＋ パネル padding 2×2 ＋ つまみ余白
    let fit = longest + 12 + 4 + Self.scrollbarWidth * 2
    return min(max(fit, Self.minWidth), Self.maxWidth)
  }

  var body: some View {
    let width = panelWidth
    let count = model.choices.count
    let content = CGFloat(count) * Self.rowHeight
    let viewportHeight = min(content, Self.capHeight)
    let maxScroll = max(0, content - Self.capHeight)
    // 選択行が可視域に収まるよう selected から派生。下端追従＋クランプ。下端フェード分の
    // マージン（fadeHeight）を足し、最下端にピン留めされた選択行がフェードに食われないよう上へ退避する。
    let selectedBottom = CGFloat(model.selected + 1) * Self.rowHeight
    let scrollY = min(max(0, selectedBottom + Self.fadeHeight - Self.capHeight), maxScroll)
    let overflow = content > Self.capHeight

    // 可視窓だけを実体化する（窓だけ描画）。scrollY から可視域に入る行の index 範囲を出し、その行だけ生成。
    // firstVisible は部分スクロール分を含む先頭行、visibleCount は viewport を満たす行数＋上下の部分行余白。
    let firstVisible = max(0, Int(scrollY / Self.rowHeight))
    let visibleCount = Int(ceil(Self.capHeight / Self.rowHeight)) + 2
    let lastVisible = min(count, firstVisible + visibleCount)
    // スライス先頭行の content 内 top（firstVisible*rowHeight）と scrollY の差だけ持ち上げる（-rowHeight..0）。
    let sliceOffset = CGFloat(firstVisible) * Self.rowHeight - scrollY

    return GlassPanel(level: .popup, cornerRadius: Theme.Radius.row) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(firstVisible..<lastVisible), id: \.self) { index in
          CompletionRow(
            choice: model.choices[index], query: model.query, selected: index == model.selected,
            rowHeight: Self.rowHeight)
        }
      }
      .frame(width: width - 4, alignment: .leading)
      .offset(y: sliceOffset)
      .frame(width: width - 4, height: viewportHeight, alignment: .topLeading)
      .clipped()
      .overlay(alignment: .bottom) {
        // 下にまだ続きがあるときだけ出す（末尾＝scrollY==maxScroll では「下に続く」誤示唆と選択行の食われを防ぐ）。
        if overflow && scrollY < maxScroll {
          // フェード先はカードの実効濃度へ合わせる（透過時に不透明帯が残らないよう effectiveOpacity でスケール）。
          LinearGradient(
            colors: [
              Color.theme.bgBase.opacity(0),
              Color.theme.bgBase.opacity(translucency.effectiveOpacity),
            ],
            startPoint: .top, endPoint: .bottom
          )
          .frame(height: Self.fadeHeight)
          .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .trailing) {
        if overflow {
          CompletionScrollbar(
            scrollY: scrollY, maxScroll: maxScroll, content: content, viewport: viewportHeight,
            width: Self.scrollbarWidth)
        }
      }
      .padding(Theme.Space.hair)
    }
    // GlassPanel(.popup) が背景透過/ブラーを読む注入点（別 NSHostingView ゆえ root で配る）。
    .environment(\.chromeTranslucency, translucency)
  }
}

/// スクロール可能時の右つまみ（track surface0／thumb surface2・幅 3px）。上下 6px インセット。非対話。
private struct CompletionScrollbar: View {
  let scrollY: CGFloat
  let maxScroll: CGFloat
  let content: CGFloat
  let viewport: CGFloat
  let width: CGFloat

  var body: some View {
    let inset: CGFloat = 6
    let trackH = max(0, viewport - inset * 2)
    let thumbH = max(16, trackH * viewport / content)
    let thumbY = maxScroll > 0 ? (trackH - thumbH) * scrollY / maxScroll : 0
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: width / 2)
        .fill(Color.theme.surface0)
        .frame(width: width, height: trackH)
      RoundedRectangle(cornerRadius: width / 2)
        .fill(Color.theme.surface2)
        .frame(width: width, height: thumbH)
        .offset(y: thumbY)
    }
    .padding(.vertical, inset)
    .padding(.trailing, width)
    .allowsHitTesting(false)
  }
}

/// 1 候補の行。テキストのみ・mono 11.5・padding 1×6・radius 5。
/// 入力済みプレフィックスは accent 色、残りは選択時 text.primary／通常 text.secondary。非対話。
private struct CompletionRow: View {
  let choice: CompletionChoice
  let query: String
  let selected: Bool
  let rowHeight: CGFloat

  var body: some View {
    prefixedValue
      .font(Font.theme.codeCompact)
      .lineLimit(1)
      .padding(.horizontal, Theme.Space.note)
      .frame(height: rowHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(selected ? Color.theme.selectionFill : Color.clear)
      )
  }

  /// 候補値を「入力済みプレフィックス（accent 色）＋残り」に分けた Text。
  /// プレフィックス不一致（あいまい一致など）のときは全体を通常色で出す。
  private var prefixedValue: Text {
    let rest = selected ? Color.theme.textPrimary : Color.theme.textSecondary
    guard !query.isEmpty, choice.value.lowercased().hasPrefix(query.lowercased()) else {
      return Text(choice.value).foregroundColor(rest)
    }
    let head = String(choice.value.prefix(query.count))
    let tail = String(choice.value.dropFirst(query.count))
    return Text(head).foregroundColor(Color.theme.accentPrimary)
      + Text(tail).foregroundColor(rest)
  }
}

#if DEBUG
  #Preview("CompletionList") {
    let model = CompletionListModel()
    model.query = "ch"
    model.choices = CompletionList.displayOrdered([
      CompletionChoice(
        value: "checkout", description: "Switch branches / restore files", insertValue: nil,
        type: "subcommand"),
      CompletionChoice(
        value: "cherry-pick", description: "Apply commits", insertValue: nil, type: "subcommand"),
      CompletionChoice(value: "cherry", description: "", insertValue: nil, type: "subcommand"),
      CompletionChoice(value: "switch", description: "", insertValue: nil, type: "subcommand"),
    ])
    model.selected = 0
    return HStack(alignment: .top, spacing: Theme.Space.note) {
      CompletionList(model: model)
      CompletionSideCard(
        name: "git checkout <branch>", kind: .subcommand,
        description: "Switch branches. Recent branches:")
    }
    .padding(Theme.Space.phrase)
    .background(Color.theme.bgBase)
  }
#endif
