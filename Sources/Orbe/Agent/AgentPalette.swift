import SwiftUI

/// Cmd+Shift+A で開くエージェント起動パレットの状態機械（ドリルイン式）。
///
/// - 一覧: 検出済みエージェント CLI を ↑↓ で選択、Enter で新タブ起動、
///   → で詳細メニューに潜る、← / Esc で閉じる。● はデフォルト（Cmd+Shift+C の起動対象）。
///   breadcrumb を供給しないため、カードはヘッダなしで行リストから始まる。
/// - 詳細メニュー（デフォルトに設定）: 「‹ <コマンド>」ヘッダ。Enter で実行して一覧へ戻る、
///   ← か Esc で一覧へ戻る。
/// - 検出ゼロのときは情報行だけを出す（空状態）。
///
/// 描画は `PaletteOverlay`/`PaletteCard`（`AppShell` の `.overlay` が compose）。入力欄を持たず、
/// カード自身が `.focusable()` でキーを捕捉する。本モデルが意味を駆動し `render` へ立て下げる。
@Observable final class AgentPaletteModel {
  var onLaunch: ((AgentCLI) -> Void)?
  var onSetDefault: ((AgentCLI) -> Void)?
  var onDismiss: (() -> Void)?

  /// CLI 検出が未完了か（初回検出 in-flight 中に開いたとき、空状態でなく検出中を見せる）。
  var detecting = false { didSet { rebuild() } }

  let render = PaletteModel()
  private var agents: [AgentCLI] = []
  private var defaultCommand: String?
  private var submenuAgent: AgentCLI?  // nil = 一覧
  /// 現在言語（提示元 AgentLauncher が所有ストアを渡す。preview/test の既定は systemDefault）。
  private let localization: LocalizationStore

  init(localization: LocalizationStore = LocalizationStore(language: .systemDefault)) {
    self.localization = localization
    render.onScrimTap = { [weak self] in self?.onDismiss?() }
    render.onTapRow = { [weak self] i in
      self?.render.selected = i
      self?.activate()
    }
    render.onUp = { [weak self] in self?.render.move(-1) }
    render.onDown = { [weak self] in self?.render.move(1) }
    render.onJumpTop = { [weak self] in self?.render.jump(-1) }
    render.onJumpBottom = { [weak self] in self?.render.jump(1) }
    render.onActivate = { [weak self] in self?.activate() }
    render.onLeft = { [weak self] in self?.goBack() }
    render.onRight = { [weak self] in
      self?.drillIn()
      return true
    }
    render.onEscape = { [weak self] in self?.goBack() }
    rebuild()
  }

  /// キー操作を受けるため focusToken を進めて first responder を確定させる。
  func focus() { render.focusToken &+= 1 }

  /// 検出結果とデフォルト（Cmd+Shift+C の起動対象）を反映して再描画する
  /// （開いたまま裏の再検出が届いたときの再読込にも使う）。
  func setAgents(_ agents: [AgentCLI], defaultCommand: String?) {
    self.agents = agents
    self.defaultCommand = defaultCommand
    if let command = submenuAgent?.command {
      submenuAgent = agents.first(where: { $0.command == command })  // 再検出で消えたら一覧へ
    }
    rebuild()
  }

  // MARK: - 描画

  private func rebuild() {
    if let agent = submenuAgent {
      render.breadcrumb = "‹ " + agent.command
      render.hint = localization.string(.wsPaletteHintSubmenu)
      render.rows = [PaletteModel.RowItem(label: localization.string(.agentPaletteSetDefault))]
    } else if detecting {
      render.breadcrumb = nil
      render.hint = localization.string(.onboardingHintDetecting)
      render.rows = [
        PaletteModel.RowItem(label: localization.string(.onboardingDetecting), enabled: false)
      ]
    } else {
      render.breadcrumb = nil
      render.hint = localization.string(.agentPaletteHintList)
      render.rows =
        agents.isEmpty
        ? [
          PaletteModel.RowItem(
            label: localization.string(.agentNotFoundCLI), enabled: false)
        ]
        : agents.map {
          PaletteModel.RowItem(
            label: ($0.command == defaultCommand ? "● " : "  ") + $0.command, chevron: true)
        }
    }
    render.clampSelection()
  }

  // MARK: - 操作の意味（キー意図とテストの両方がここを駆動する）

  func activate() {
    if let agent = submenuAgent {
      onSetDefault?(agent)
      backToList()
    } else if agents.indices.contains(render.selected) {
      onLaunch?(agents[render.selected])
    }
  }

  func drillIn() {
    guard submenuAgent == nil, agents.indices.contains(render.selected) else { return }
    submenuAgent = agents[render.selected]
    render.selected = 0
    rebuild()
  }

  func goBack() {
    if submenuAgent != nil {
      backToList()
    } else {
      onDismiss?()
    }
  }

  private func backToList() {
    submenuAgent = nil
    render.selected = 0
    rebuild()
  }
}
