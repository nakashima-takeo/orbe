import AppKit
import CoreText
import SwiftUI

/// chrome のユーザー由来文字列に混じる端末系グリフ（Nerd アイコン＝私用領域・点字スピナー・絵文字）を、
/// 同梱フォントへ run 単位で明示割り当てする。
/// CoreText は私用領域をフォールバック探索から除外するため、カスケード指定でも
/// LastResort（「?」の箱）へ落ちる。描けるのは明示割り当てのみ。点字も既定フォールバックの
/// AppleBraille は空点を含む点字紙様の字形で、端末（JuliaMono）と見えが揃わないため同様に充てる。
/// 基底フォントは適用サイトごとに異なる（タブ chrome 11pt・パレット行 12pt・EditorPane 10.5pt 等）ため
/// 引数に取り、グリフフォントは基底のサイズへ揃えて解決する。設定連動（絵文字 Noto/Apple・タブ
/// タイトルフォント）は `ChromeFontResolver` がこの機構を実効設定で駆動する。
enum TitleGlyphs {
  /// chrome 用カラー絵文字は端末セルと同じ Noto Color Emoji（CBDT→sbix 変換を同梱・
  /// `scripts/convert-noto-emoji-sbix.py` で生成。端末側は `TerminalFonts.registerBundled` の
  /// .process 登録＋gui.conf の font-codepoint-map で解決する）。ここはファイルから直接ロードする。
  /// バンドル無し（`swift run` 等）では nil → Apple Color Emoji へ退避。
  static let notoEmoji: NSFont? = {
    guard let url = Bundle.main.url(forResource: "NotoColorEmoji-sbix", withExtension: "ttf"),
      let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
      let desc = descs.first
    else { return nil }
    return CTFontCreateWithFontDescriptor(desc, Theme.Typography.chrome.pointSize, nil) as NSFont
  }()

  /// run に充てるグリフの種別（nil＝基底フォントのまま）。
  private enum Kind {
    case nerd, julia, emoji
  }

  /// Nerd アイコン（BMP 私用領域＋plane 15。Nerd Fonts 3 は Material 系を plane 15 に置く）と
  /// 点字の種別。それ以外は nil（基底フォントのまま）。
  private static func glyphKind(for scalar: Unicode.Scalar) -> Kind? {
    switch scalar.value {
    case 0xE000...0xF8FF, 0xF0000...0xFFFFD: return .nerd
    case 0x2800...0x28FF: return .julia
    default: return nil
    }
  }

  /// 文字→run 割り当て種別（nil＝素の基底フォントのまま）。`needsAssignment`（早期打ち切りゲート）と
  /// `segments`（run 分割）が同一分類を共有し、片方だけ触れて食い違う silent-breakage を断つ。
  private static func kind(for ch: Character) -> Kind? {
    if let glyph = ch.unicodeScalars.first.flatMap(glyphKind(for:)) { return glyph }
    return (isEmojiPresentation(ch) || emojiPromoted(ch) != nil) ? .emoji : nil
  }

  /// 端末系グリフ/絵文字を含み run 割り当てが要るか。含まない文字列（大半の本文行）は
  /// AttributedString を組まず素の描画で済ませる早期打ち切りの判定。
  static func needsAssignment(_ text: String) -> Bool {
    text.contains { kind(for: $0) != nil }
  }

  /// 表示用文字列。端末系グリフ/絵文字の run にだけフォントを埋め、他 run は無指定
  /// （view 側の `.font()` を継承）。グリフフォントは `base` のサイズで解決する。
  /// `emoji` は絵文字 run に充てるフォント（nil＝割り当てなし＝Apple Color Emoji へ委譲。
  /// VS16 昇格はどちらでも維持されカラー表示は保たれる）。
  static func attributed(_ title: String, base: NSFont, emoji: NSFont?) -> AttributedString {
    var out = AttributedString()
    for segment in segments(title) {
      var run = AttributedString(segment.text)
      let font = segment.kind.flatMap {
        glyphFont(for: $0, size: base.pointSize, emoji: emoji)
      }
      if let font { run.font = Font(font as CTFont) }
      out += run
    }
    return out
  }

  /// `attributed` と同じ割り当てでの描画幅。タブの自然幅計算が描画とずれないための対。
  static func width(_ title: String, base: NSFont, emoji: NSFont?) -> CGFloat {
    segments(title).reduce(0) { acc, segment in
      let font =
        segment.kind.flatMap { glyphFont(for: $0, size: base.pointSize, emoji: emoji) } ?? base
      return acc + (segment.text as NSString).size(withAttributes: [.font: font]).width
    }
  }

  /// 種別ごとの実フォントを基底サイズで解決する。同梱 TTF は `.process` 登録済みのため名前解決できる。
  /// バンドル無しでは nil → 割り当てせず素の chrome 描画へ退避。
  private static func glyphFont(for kind: Kind, size: CGFloat, emoji: NSFont?) -> NSFont? {
    switch kind {
    case .nerd: return NSFont(name: "JetBrainsMonoNF-Regular", size: size)
    case .julia: return NSFont(name: "JuliaMono-Regular", size: size)
    case .emoji:
      guard let emoji else { return nil }
      return emoji.pointSize == size ? emoji : NSFont(descriptor: emoji.fontDescriptor, size: size)
    }
  }

  /// 同じ割り当て種別が連続する文字をまとめた run 列。
  private static func segments(_ title: String) -> [(text: String, kind: Kind?)] {
    var result: [(text: String, kind: Kind?)] = []
    for ch in title {
      let k = kind(for: ch)
      // 昇格した text 記号（✳ 等）だけ run テキストを VS16 付きへ差し替える（実絵文字・グリフは素のまま）。
      let text = (k == .emoji ? emojiPromoted(ch) : nil) ?? String(ch)
      if !result.isEmpty, result[result.count - 1].kind == k {
        result[result.count - 1].text += text
      } else {
        result.append((text, k))
      }
    }
    return result
  }

  /// emoji presentation で描かれる文字（既定 emoji、または VS16 明示）。
  private static func isEmojiPresentation(_ ch: Character) -> Bool {
    ch.unicodeScalars.contains { $0.properties.isEmojiPresentation }
      || ch.unicodeScalars.contains { $0.value == 0xFE0F }
  }

  /// text 既定の emoji 可能記号（非 ASCII・明示のバリアント選択子なし）は VS16 を足して
  /// emoji presentation（カラー）へ昇格する。Claude Code がタイトル先頭に出す ✳ 等が対象で、
  /// WezTerm などのタブ表示と見えを揃える。VS15 付き（複数スカラー）は書かれたとおり text を尊重する。
  private static func emojiPromoted(_ ch: Character) -> String? {
    guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
      scalar.value > 0x7F, scalar.properties.isEmoji, !scalar.properties.isEmojiPresentation
    else { return nil }
    return String(ch) + "\u{FE0F}"
  }
}
