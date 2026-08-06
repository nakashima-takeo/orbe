import CoreText
import Foundation

/// ターミナル本文の等幅チェーンを構成する `.app` 同梱 TTF を起動時に `.process` 登録する。
/// libghostty のフォント解決（surface 生成時）より前に呼ぶ必要があるため、
/// `Ghostty.shared` 初期化の直前で実行する。バンドル無し（`swift run`）では nil→no-op。
enum TerminalFonts {
  /// 登録対象。プライマリ JetBrains Mono は Regular/Bold/Italic/BoldItalic の4スタイルを揃える。
  /// ghostty はスタイルごとに font-family を CoreText discovery し、bold/italic の実 face が
  /// 無いと faux 合成へ倒れる（埋め込み variable の実 bold/italic は fallback 挿入順で負ける）。
  /// 4スタイルを登録することで bold/italic が設計字形で決定論的に解決する（システム導入に非依存）。
  /// JuliaMono（v0.63.2）は `font-family` チェーンには入れず、**discovery の候補**として登録する。
  /// `font-family` 行の face は fallback=false で挿さり presentation を無視して奪うため、チェーンに
  /// 置くと絵文字を白黒字形で取り、記号の解決先も全角字形のフォントから欧文の半角字形へすり替わる
  /// （理由の詳細と実測値は `app/orbe-defaults.conf`）。登録だけ残せば macOS のシステムフォールバック
  /// から見え、JetBrains に無い記号（数学記号・多言語など）の受け皿として discovery で引かれる。
  /// これが成立するのは SVG テーブルを持たない版だけ——カラーフォント判定されると discovery の
  /// presentation 検証が text 用途で拒否し、登録が無言で無効化する（テストが非カラー判定を固定する）。
  /// Noto Color Emoji（CBDT→sbix 変換・family 名は「Noto Color Emoji」のまま）は端末セルの絵文字を
  /// gui.conf の font-codepoint-map（emoji-font 設定）で名指し解決させるために登録する。
  /// この集合は `scripts/build-app.sh` が `.app` へコピーする TTF 集合と一致する（片方だけ足しても無警告で効かない）。
  /// module 内可視なのは、この一致を `Tests/OrbeTests/TerminalFontDelegationTests` が照合するため。
  static let bundledResources = [
    "JetBrainsMonoNerdFont-Regular",
    "JetBrainsMonoNerdFont-Bold",
    "JetBrainsMonoNerdFont-Italic",
    "JetBrainsMonoNerdFont-BoldItalic",
    "JuliaMono-Regular",
    "NotoColorEmoji-sbix",
  ]

  /// `.app` 同梱 TTF を `.process` スコープで登録する。バンドル無しでは何もしない。
  static func registerBundled() {
    for resource in bundledResources {
      guard let url = BundledResources.root?.appendingPathComponent("\(resource).ttf"),
        FileManager.default.fileExists(atPath: url.path)
      else { continue }
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }
}
