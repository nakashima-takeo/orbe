import SwiftUI

/// 初回起動の言語選択（Onboarding の前段）。UI 言語だけを選ばせ、確定後に既存 Onboarding へ進む。
/// 流れの駆動（確定→永続→メニュー再構築→次段）は WindowController が持ち、本モデルは表示状態と入力意味だけ。
/// 描画は `LanguageSelectOverlay`（`AppShell` の `.overlay` が compose）。真のモーダル（scrim では閉じない）。
@Observable final class LanguageSelectModel {
  /// 選択中の言語（`Language.allCases` の index）。
  var selected: Int
  /// focus トリガ。提示元がインクリメントし、SwiftUI が監視して `@FocusState` を立てる。
  var focusToken = 0
  /// ↵ / 行押下で選ばれた言語を確定する。
  var onConfirm: (Language) -> Void = { _ in }

  init(current: Language) {
    selected = Language.allCases.firstIndex(of: current) ?? 0
  }

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { focusToken &+= 1 }

  /// 選択移動（上下）。
  func move(_ direction: Int) {
    selected = min(max(0, selected + direction), Language.allCases.count - 1)
  }

  /// ↵。選択中の言語で確定する。
  func activate() {
    guard Language.allCases.indices.contains(selected) else { return }
    onConfirm(Language.allCases[selected])
  }

  /// 行タップ＝決定。選択をその行へ確定してから ↵ と同じ funnel（`activate()`）を通す。
  func activate(at index: Int) {
    guard Language.allCases.indices.contains(index) else { return }
    selected = index
    activate()
  }
}

/// 言語選択のカード（中身だけ。全面 scrim・中央寄せは host 側）。現在言語（OS 追従の既定）で自らの
/// 見出し・ヒントを描き、各言語の行は endonym（日本語 / English）で名乗る。
struct LanguageSelectCard: View {
  @Bindable var model: LanguageSelectModel
  @Environment(\.localization) private var l10n

  var body: some View {
    GlassPanel(level: .settings) {
      VStack(alignment: .leading, spacing: Theme.Space.bar) {
        Text(l10n.string(.languageSelectTitle))
          .font(Font.theme.title)
          .foregroundStyle(Color.theme.textPrimary)

        VStack(spacing: 0) {
          ForEach(Array(Language.allCases.enumerated()), id: \.offset) { i, language in
            PaletteRow(
              title: language.displayName, selected: i == model.selected, showsChevron: false,
              action: { model.activate(at: i) }, onHoverEnter: { model.selected = i })
          }
        }

        Text(l10n.string(.languageSelectHint))
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
      }
      .padding(Theme.Space.phrase)
      .frame(width: 440, alignment: .leading)
    }
  }
}

/// フルウィンドウ overlay。dim scrim ＋ 中央のカード。真のモーダルで scrim はヒットを吸収するだけ
/// （クリックで閉じない）。↑↓ で選択・↵ / 行タップで確定。入力欄が無いためカード器を `.focusable()` にして捕捉する。
struct LanguageSelectOverlay: View {
  @Bindable var model: LanguageSelectModel
  @FocusState private var focused: Bool

  var body: some View {
    ZStack {
      Scrim(strength: .strong)
        .contentShape(Rectangle())
      LanguageSelectCard(model: model)
    }
    .ignoresSafeArea()
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onKeyPress { press in
      switch press.key {
      case .upArrow: model.move(-1); return .handled
      case .downArrow: model.move(1); return .handled
      default: return .ignored
      }
    }
    .onKeyPress(.return) {
      model.activate(); return .handled
    }
    .onChange(of: model.focusToken, initial: true) { focused = true }
  }
}
