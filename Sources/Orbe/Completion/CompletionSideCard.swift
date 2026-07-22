import SwiftUI

/// 形グリフで種別を二重符号化。オプション=二重線 / ファイル=縦長矩形 / サブコマンド・候補=node グリフ中抜き。
/// 色は中立グレー（既定 textMuted／選択時のみ一段明るい textTertiary）。
/// 寸法は枠 `side` に比例し Canvas で描く（stroke 1.4・小円 4px・L 字曲線）。side card が使う。
struct CompletionGlyph: View {
  let kind: CompletionKind
  let selected: Bool
  let side: CGFloat

  var body: some View {
    let color = selected ? Color.theme.textTertiary : Color.theme.textMuted
    Canvas { ctx, size in
      let w = size.width
      let h = size.height
      let lw: CGFloat = 1.4
      switch kind {
      case .option:
        // 二重線（上長・下短の左寄せテーパー）
        let x0 = w * 0.18
        for (len, y) in zip([w * 0.64, w * 0.42], [h / 2 - w * 0.16, h / 2 + w * 0.16]) {
          var p = Path()
          p.move(to: CGPoint(x: x0, y: y))
          p.addLine(to: CGPoint(x: x0 + len, y: y))
          ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
      case .path:
        // 矩形（縦長・中抜き）
        let rw = w * 0.62
        let rh = h * 0.78
        let rect = CGRect(x: (w - rw) / 2, y: (h - rh) / 2, width: rw, height: rh)
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: lw)
      case .subcommand, .argument:
        // node グリフ中抜き（小円2つ＋L字曲線で枝の分岐を象る）
        let r = w * 0.16
        let corner = w * 0.30
        let topC = CGPoint(x: w * 0.30, y: r + lw / 2)
        let botC = CGPoint(x: w * 0.80, y: h - r - lw / 2)
        var p = Path()
        p.move(to: CGPoint(x: topC.x, y: topC.y + r))
        p.addLine(to: CGPoint(x: topC.x, y: botC.y - corner))
        p.addQuadCurve(
          to: CGPoint(x: topC.x + corner, y: botC.y),
          control: CGPoint(x: topC.x, y: botC.y))
        p.addLine(to: CGPoint(x: botC.x - r, y: botC.y))
        ctx.stroke(
          p, with: .color(color),
          style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        for c in [topC, botC] {
          let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
          ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lw)
        }
      }
    }
    .frame(width: side, height: side)
  }
}

/// side card に渡す汎用データ（controller が選択候補から組む）。git メタは持たない。
struct CompletionDetail {
  let name: String
  let kind: CompletionKind
  let description: String
}

/// 選択候補の脇に出す詳細カード（Autocomplete サイドパネル）。幅 250・radius 10・
/// padding 10×12・要素間 gap 7。グリフ（選択 kind）＋名前(mono 11)＋種別ラベル＋説明（sans 10.5・行間 1.5）。
struct CompletionSideCard: View {
  let name: String
  let kind: CompletionKind
  let description: String
  /// 背景透過（既定は不透明＝preview は現行のガラスカード）。SurfaceView が実ホルダーを渡す。
  var translucency = ChromeTranslucency()

  private static let width: CGFloat = 250

  var body: some View {
    GlassPanel(level: .popup) {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: Theme.Space.note) {
          CompletionGlyph(kind: kind, selected: true, side: 13)
          Text(name)
            .font(Font.theme.codeSmall)
            .foregroundStyle(Color.theme.textPrimary)
            .lineLimit(1)
        }
        Text(description)
          .font(Font.theme.bodySmall)
          .foregroundStyle(Color.theme.textMuted)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, Theme.Space.beat)
      .frame(width: Self.width, alignment: .leading)
    }
    // GlassPanel(.popup) が背景透過/ブラーを読む注入点（別 NSHostingView ゆえ root で配る）。
    .environment(\.chromeTranslucency, translucency)
  }
}

#if DEBUG
  #Preview("CompletionSideCard") {
    HStack(spacing: Theme.Space.bar) {
      CompletionSideCard(
        name: "git checkout <branch>", kind: .argument,
        description: "Switch branches. Recent branches:")
      CompletionSideCard(
        name: "--verbose", kind: .option, description: "Show verbose output")
    }
    .padding(Theme.Space.phrase)
    .background(Color.theme.bgBase)
  }
#endif
