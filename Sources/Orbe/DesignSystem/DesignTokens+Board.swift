import AppKit

/// ボードのトークンが所有する自己完結ファイル（`DesignTokens+Editor.swift` と同型）。値は見本『Home』の実寸。既存の
/// トークンと同じ値（14・12 など）は既存のものを使い、無い値だけを持つ。
extension Theme.Typography {
  /// 部品の見出し「タスクの自動追加」（mono 15 semibold）。
  static let boardHeading = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
  /// 詳細の見出し（選んだ自動追加の名前。mono 14 semibold）。
  static let boardDetailTitle = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
  /// 見出しの件数と、詳細の値（mono 13）。
  static let boardValue = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  /// 一覧の行の 2 段（名前・いつ）の行高。
  static let lineBoardRow: CGFloat = 1.5
}

extension Theme.Layout {
  /// 面の内側の余白（上・左右）。下は `Theme.Space.phrase`。
  static let boardInsetTop: CGFloat = 28
  static let boardInsetSide: CGFloat = 48
  /// 一覧と詳細の間。幅は一覧 3 : 詳細 2 で分ける。
  static let boardColumnGap: CGFloat = 32
  /// 一覧の行の最小の高さと、行の左の点。
  static let boardRowMinHeight: CGFloat = 58
  static let boardDot: CGFloat = 7
  /// 選んだ行で効くキーのフッターの高さ。
  static let boardFooter: CGFloat = 44
}

extension NSFont {
  /// CSS の line-height（倍率）で 1 行が占める高さと、字の自然な行の高さの差（行間に足す量）。
  func extraLeading(lineHeight multiple: CGFloat) -> CGFloat {
    max(0, pointSize * multiple - (ascender - descender + leading))
  }
}
