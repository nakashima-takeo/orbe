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
  /// JuliaMono は広カバレッジ fallback（JetBrains に無い記号を discovery より前で確定）。
  /// Noto Color Emoji（CBDT→sbix 変換・family 名は「Noto Color Emoji」のまま）は端末セルの絵文字を
  /// gui.conf の font-codepoint-map（emoji-font 設定）で名指し解決させるために登録する。
  /// PlemolJP35 Console は囲み英数字・`★☆`・`※` を半角字形で描くために、同じく
  /// orbe-defaults.conf の font-codepoint-map から family 名で名指しする（登録しないと名前解決に失敗し委譲が黙って無効化される）。
  /// この集合は `scripts/build-app.sh` が `.app` へコピーする TTF 集合と一致する（片方だけ足しても無警告で効かない）。
  /// module 内可視なのは、この一致を `Tests/OrbeTests/TerminalFontDelegationTests` が照合するため。
  static let bundledResources = [
    "JetBrainsMonoNerdFont-Regular",
    "JetBrainsMonoNerdFont-Bold",
    "JetBrainsMonoNerdFont-Italic",
    "JetBrainsMonoNerdFont-BoldItalic",
    "JuliaMono-Regular",
    "NotoColorEmoji-sbix",
    "PlemolJP35Console-Regular",
  ]

  /// `.app` 同梱 TTF を `.process` スコープで登録する。バンドル無しでは何もしない。
  static func registerBundled() {
    for resource in bundledResources {
      guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else { continue }
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }
}
