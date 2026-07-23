import SwiftUI

/// Attention の 2 段行（パレットとメニューバードロップダウンで共用・デザイン第10/11シーン準拠）。
/// 上段: 状態グリフ 12 / WS 名 12 / `›` 10 / タブタイトル 11（省略）/ 右端 経過時間 10。
/// 下段（message 非 nil のみ）: 11px・行送り 1.55・3 行 clamp・waiting は statusText / done は muted。
/// 経過時間は 1 秒周期の TimelineView で自走する（表示中のみ・タイマー配線不要）。
/// 選択地（tint 塗り）は器（`SelectableRow`）に委ねる。
struct AttentionRowView: View {
  let row: AttentionRow

  @Environment(\.agentIconResolver) private var iconResolver
  @Environment(\.chromeFontResolver) private var fontResolver

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Space.step) {
        if let kind = AgentStateIcon.kind(state: row.state) {
          StatusGlyphView(kind: kind, size: 12, symbol: iconResolver.symbol(for: kind))
        }
        fontResolver.text(row.workspaceName, base: Theme.Typography.workspaceName)
          .font(Font.theme.workspaceName)
          .foregroundStyle(Color.theme.textPrimary)
          .lineLimit(1)
          .layoutPriority(1)
        Text("›")
          .font(Font.theme.meta)
          .foregroundStyle(Color.theme.textMuted)
        fontResolver.text(row.tabTitle, base: Theme.Typography.chrome)
          .font(Font.theme.chrome)
          .foregroundStyle(Color.theme.textSecondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: Theme.Space.step)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(AttentionSnapshot.elapsedLabel(from: row.stateChangedAt, to: context.date))
            .font(Font.theme.meta)
            .foregroundStyle(Color.theme.textMuted)
        }
      }
      if let message = row.message {
        fontResolver.text(message, base: Theme.Typography.chrome)
          .font(Font.theme.chrome)
          .foregroundStyle(
            row.state == "waiting" ? Color.theme.statusText : Color.theme.textMuted
          )
          .lineSpacing(Theme.Typography.chrome.pointSize * (Theme.Typography.lineTerminal - 1))
          .lineLimit(3)
          .multilineTextAlignment(.leading)
          .padding(.top, Theme.Space.tick)
          .padding(.bottom, Theme.Space.hair)
          .padding(.leading, Theme.Space.span)
      }
    }
    // 器（SelectableRow・ドロップダウン行）の縦 padding は 5。attention の 2 段行は
    // デザイン第10/11シーンで 7×10 なので、差分 2 を行内で足して実効 7 にする。
    .padding(.vertical, Theme.Space.hair)
  }
}

#if DEBUG
  #Preview("AttentionRowView") {
    VStack(spacing: 0) {
      AttentionRowView(
        row: AttentionRow(
          paneId: 1, workspaceName: "api-gateway", tabTitle: "deploy スクリプト整理",
          state: "waiting",
          message:
            "ビルド成果物の掃除方法を選んでください。1) rm -rf dist で全削除して作り直す 2) dist/legacy だけ残して選択削除 3) 何もしない。"
            + "CI キャッシュは 1) の場合のみ無効化が必要です。どれで進めますか？",
          stateChangedAt: Date().addingTimeInterval(-45)))
      AttentionRowView(
        row: AttentionRow(
          paneId: 2, workspaceName: "ghostty-fork", tabTitle: "renderer テスト追加",
          state: "working", message: nil, stateChangedAt: Date().addingTimeInterval(-60)))
      AttentionRowView(
        row: AttentionRow(
          paneId: 3, workspaceName: "orbe-core", tabTitle: "docs 同期", state: "done",
          message: "PR #142 を作成しました +18 −4。emit API の説明を README と docs/emit.md の両方に反映済み。",
          stateChangedAt: Date().addingTimeInterval(-120)))
    }
    .padding(Theme.Space.bar)
    .frame(width: 520)
    .background(Color.theme.bgBase)
  }
#endif
