import SwiftUI

/// エージェント状態面 3 箇所（タブ行グリフ・TopBar ロールアップ・パレットの状態カウント表）へ、状態ごとの
/// アイコン上書き（state→SF Symbol 名）を届ける観測可能ホルダー。chrome は複数の独立した `NSHostingView`
/// に跨るため、モデル毎の糸通しでなく単一の Environment で配る（`ChromeTranslucency` と同型）。
/// 値の材料はアクティブ workspace の実効設定（`agentStateIcons`）で、`applyActiveWorkspaceConfig` が
/// 外観/gui.conf と同一 tick で更新する。所有は `WindowController`。装飾用途のグリフはこれを読まず素通し。
@Observable final class AgentIconResolver {
  /// 状態→SF Symbol 名。マップに無い状態＝Glass 既定（nil を返す）。
  var symbols: [AgentStateIcon.Kind: String] = [:]

  /// 状態の上書き symbol（未設定なら nil＝Glass）。
  func symbol(for kind: AgentStateIcon.Kind) -> String? { symbols[kind] }
}

private struct AgentIconResolverKey: EnvironmentKey {
  /// 未注入（preview・浮遊 popup 等）は上書き無し＝Glass 既定。
  static let defaultValue = AgentIconResolver()
}

extension EnvironmentValues {
  /// chrome 各面が状態アイコン上書きを読む Environment 窓口。`WindowController` が各 root へ注入する。
  var agentIconResolver: AgentIconResolver {
    get { self[AgentIconResolverKey.self] }
    set { self[AgentIconResolverKey.self] = newValue }
  }
}
