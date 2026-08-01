import AppKit
import SwiftUI

/// ペインに重ねるスクロールバック検索バー。
/// 検索エンジンは libghostty 側（surface の search アクション）。本バーは needle 入力・
/// 件数表示・次/前ジャンプのトリガを surface へ橋渡しするだけ。
///
/// 中身は `NSHostingView<SearchField>`（純 SwiftUI）＋ `SearchBarModel`。入力欄は SwiftUI の
/// `TextField`。次へ＝`onSubmit`（IME 確定の Enter では発火しない）、前へ＝Shift+Return を
/// `onKeyPress` で限定捕捉、閉じる＝Esc。focus は `@FocusState`＋model のトークン。
/// 公開 API は AppKit のまま維持し、配線（`SurfaceView+Search`）は不変。
final class SearchBar: NSView {
  private let model = SearchBarModel()
  private let host: NSHostingView<SearchField>

  var onNeedleChange: ((String) -> Void)? {
    didSet { model.onNeedleChange = onNeedleChange }
  }
  var onNext: (() -> Void)? { didSet { model.onNext = onNext } }
  var onPrev: (() -> Void)? { didSet { model.onPrev = onPrev } }
  var onClose: (() -> Void)? { didSet { model.onClose = onClose } }

  /// 背景透過・現在言語ホルダー（WindowController 所有）を root へ渡す。透過時は端末上でも veil 濃度を揃え、
  /// 現在言語はプレースホルダ・件数表示を選択言語で描き設定切替に一斉追従させる（別 NSHostingView root ゆえ明示注入）。
  init(translucency: ChromeTranslucency, localization: LocalizationStore) {
    host = NSHostingView(
      rootView: SearchField(model: model, translucency: translucency, localization: localization))
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    // SwiftUI 背景の alpha を端末面まで通す（透過時に素通し半透明が端末へ抜けるよう不透明ラスタを止める）。
    host.wantsLayer = true
    host.layer?.isOpaque = false
    host.translatesAutoresizingMaskIntoConstraints = false
    addSubview(host)
    // 親（SurfaceView）は top/trailing しか張らない。サイズは host の中身（SwiftUI）から導く。
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// 入力欄を first responder にする。トークンを進めて SwiftUI 側の `@FocusState` を立てる
  /// （`SurfaceView` は addSubview 直後にこれを呼ぶ。SwiftUI が描画後に focus を確定する）。
  func focusField() {
    model.focusToken &+= 1
  }

  /// ヒット件数表示を更新（selected/total は libghostty の通知由来。負値は nil で渡る）。
  func updateCount(selected: Int?, total: Int?) {
    if model.needle.isEmpty {
      model.matchTotal = nil  // 未検索＝件数を出さない
      model.matchSelected = nil
      return
    }
    guard let total, total > 0 else {
      model.matchTotal = 0  // 一致なし
      model.matchSelected = nil
      return
    }
    model.matchTotal = total
    model.matchSelected = selected
  }
}

/// SearchBar の入力・表示状態を保持する SwiftUI モデル。
@MainActor @Observable final class SearchBarModel {
  var needle = ""
  var focused = false
  /// ヒット総数（nil＝未検索で件数非表示・0＝一致なし・>0＝件数）。文言は View が現在言語で描く。
  var matchTotal: Int?
  /// 現在ヒット index（`selected/total` 表示に使う。nil なら総数のみ）。
  var matchSelected: Int?
  /// 一致なし（danger 色）か。
  var countIsNoMatch: Bool { matchTotal == 0 }
  /// facade の `focusField()` がインクリメントする focus トリガ。SwiftUI が監視して `@FocusState` を立てる。
  var focusToken = 0

  var onNeedleChange: ((String) -> Void)?
  var onNext: (() -> Void)?
  var onPrev: (() -> Void)?
  var onClose: (() -> Void)?

  /// focus かつ非空（＝入力中）のときだけ focus リングを出す（§5.5）。
  var typing: Bool { focused && !needle.isEmpty }
}

/// 検索バーの宣言的レイアウト（§5.5）。地は bg.sunken＋1px surface.1＋radius md。
/// 入力中は外枠 2px accent.focus リングで focus を示す。件数は captionDigit。
/// no-match は danger(赤)。入力欄は純 SwiftUI `TextField`。
struct SearchField: View {
  /// コンテナ（ガラス枠）の固定幅。VS Code find widget 方式で件数の有無・桁数に依らず窓幅を一定に保つ。
  /// 入力欄は残り幅を埋める flex。最悪件数（EN "No matches"＝64pt）でも入力欄は 256-8-64≒184pt を保つ。
  private static let fieldWidth: CGFloat = 256

  @Bindable var model: SearchBarModel
  /// 背景透過（既定は不透明＝preview は現行のガラスカード）。SearchBar が実ホルダーを渡す。
  var translucency = ChromeTranslucency()
  /// 現在言語（別 NSHostingView root のため SearchBar が実ホルダーを渡す。既定は OS 追従）。
  var localization = LocalizationStore(language: .systemDefault)
  @FocusState private var isFocused: Bool

  /// ヒット件数の表示（未検索は nil＝非表示）。一致なし＝文言、`selected` があれば `n/total`、無ければ件数。
  private var countText: String? {
    guard let total = model.matchTotal else { return nil }
    if total == 0 { return localization.string(.searchNoMatch) }
    if let selected = model.matchSelected { return "\(selected)/\(total)" }
    return localization.plural(total, one: .searchMatchesOne, other: .searchMatchesOther)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.step) {
      TextField("", text: $model.needle)
        .textFieldStyle(.plain)
        .font(Font.theme.body)
        .foregroundStyle(Color.theme.textPrimary)
        .focused($isFocused)
        // 純正 placeholder は色を握れず IME 変換中も消えないため、共通モディファイアで muted 描画しつつ
        // marked text がある間は抑制する（§5.5）。
        .imePlaceholder(
          localization.string(.searchPlaceholder), showWhenEmpty: model.needle.isEmpty,
          focused: isFocused, font: Font.theme.body, color: Color.theme.textMuted
        )
        // 次へ＝onSubmit。IME 変換確定の Enter では発火しない＝誤爆しない。
        .onSubmit { model.onNext?() }
        // 前へ＝Shift+Return のみ。plain Return は素通し（IME 確定を壊さない）。
        .onKeyPress { press in
          guard press.key == .return, press.modifiers.contains(.shift) else { return .ignored }
          model.onPrev?()
          return .handled
        }
        .onKeyPress(.escape) {
          model.onClose?()
          return .handled
        }
        // 入力欄は残り幅を埋める flex。件数が出るとその自然幅ぶん入力欄が縮むだけで、コンテナ幅は一定。
        // focus は外枠リングが示すため下線は持たない。上下対称 padding が TextField を枠の縦中央へ載せる。
        .frame(maxWidth: .infinity)
      if let countText {
        Text(countText)
          .font(Font.theme.captionDigit)
          .foregroundStyle(model.countIsNoMatch ? Color.theme.danger : Color.theme.textMuted)
          .fixedSize()
      }
    }
    // コンテナを固定幅にし、件数の有無・桁数で窓の外形が変わらないようにする（VS Code find widget 方式）。
    .frame(width: SearchField.fieldWidth)
    .padding(.horizontal, Theme.Space.step)
    .padding(.vertical, Theme.Space.step)
    // 端末上に浮くバーなのでガラス面（popup）で背後を鎮める（bgSunken は半透明トークンで沈まない）。
    // blur=ON か不透明時のみ withinWindow ブラーで背後（端末）を鎮め、透過かつ blur=OFF は素通し半透明。
    // surface tint は effectiveOpacity でスケールし、端末・chrome と veil 濃度を揃える（均一ガラス）。
    .background {
      ZStack {
        if !translucency.translucent || translucency.blur {
          VisualEffectView(material: .menu)
        }
        Color(nsColor: Theme.Glass.surface(.popup)).opacity(translucency.effectiveOpacity)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .strokeBorder(
          Color(nsColor: Theme.Glass.border(.popup)), lineWidth: Theme.Stroke.hairline)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.md)
        .strokeBorder(
          Color.theme.accentFocus, lineWidth: model.typing ? Theme.Stroke.focusRing : 0)
    )
    .onChange(of: isFocused) { model.focused = isFocused }
    .onChange(of: model.needle) { model.onNeedleChange?(model.needle) }
    .onChange(of: model.focusToken, initial: true) { isFocused = true }
  }
}

#if DEBUG
  /// SearchBar の story/snapshot 用フィクスチャ（empty / typing / no-match / match / overflow）。
  /// 本物の `SearchField`＋`SearchBarModel` を流す（stub で塗りつぶさない）。
  enum SearchBarFixtures {
    enum State: String, CaseIterable {
      case empty
      case typing
      case noMatch = "no-match"
      case match
      case overflow
    }

    @MainActor static func model(_ state: State) -> SearchBarModel {
      let model = SearchBarModel()
      switch state {
      case .empty:
        break
      case .typing:
        model.needle = "needle"
        model.focused = true
      case .noMatch:
        model.needle = "zzz"
        model.focused = true
        model.matchTotal = 0
      case .match:
        model.needle = "fn"
        model.focused = true
        model.matchSelected = 2
        model.matchTotal = 7
      case .overflow:
        // 最悪条件: 幅を超える長い needle ＋ 大きい件数（フィールドが崩れないこと）。
        model.needle = "very_long_search_needle_overflow"
        model.focused = true
        model.matchSelected = 128
        model.matchTotal = 4096
      }
      return model
    }

    @MainActor static func view(_ state: State) -> some View {
      SearchField(model: model(state))
    }

    /// 全状態を縦に積んだギャラリー（gallery スナップショッタが描く）。
    @MainActor static func gallery() -> some View {
      VStack(alignment: .leading, spacing: Theme.Space.bar) {
        ForEach(State.allCases, id: \.self) { state in
          VStack(alignment: .leading, spacing: Theme.Space.hair) {
            Text(state.rawValue)
              .font(Font.theme.meta)
              .foregroundStyle(Color.theme.textMuted)
            view(state)
          }
        }
      }
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
    }
  }

  #Preview("SearchBar — states") {
    SearchBarFixtures.gallery()
      .frame(width: 320, height: 400)
  }
#endif
