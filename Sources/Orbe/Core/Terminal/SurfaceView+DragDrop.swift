import AppKit
import GhosttyKit

/// Finder からのファイル/フォルダ D&D を受理し、フルパスをカーソル位置へテキスト挿入する。
extension SurfaceView {
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    sender.draggingPasteboard.canReadObject(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    else { return false }

    // ドロップ先 surface へフォーカスを移す。移さないと、挿入されたパスが見えているペインと
    // 後でユーザーが押す Enter の実行先ペインが食い違う（mouseDown と同じ理由）。
    window?.makeFirstResponder(self)

    let text = urls.map { Self.escapeShellPath($0.path) }.joined(separator: " ")
    insertText(text, replacementRange: NSRange(location: 0, length: 0))
    return true
  }

  /// シェルに渡せるようパスをバックスラッシュエスケープする（ターミナルのライブバッファへ
  /// `insertText` で挿入する用途。コマンド文字列をまるごとクォートする用途ではない）。
  /// 文字集合は upstream Ghostty 本家 `Ghostty.Shell.escape`
  /// （vendor/ghostty/macos/Sources/Ghostty/Ghostty.Shell.swift）に合わせる。
  ///
  /// ただし制御文字の除去だけは上流に上乗せしている。挿入先は pty へ生バイトを書くため、
  /// 制御文字はバックスラッシュを前置しても中和されない——`\` が self-insert された後、
  /// 続く生バイトを ZLE がそのままキー操作として解釈するため。改行を含む名前のファイル
  /// （APFS 上で作れる）をドロップすると `^J` が accept-line になり、**ユーザーが Enter を
  /// 押していないのに**次の行が実行される。タブも同様に補完起動として食われる。
  /// エスケープでは対処できないので除去する。上流追随の際にこの 1 点を落とさないこと。
  static func escapeShellPath(_ path: String) -> String {
    let escapeCharacters: Set<Character> = [
      "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`", "!", "#", "$", "&", ";",
      "|", "*", "?",
    ]
    var result = ""
    for ch in path {
      if ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { continue }
      if escapeCharacters.contains(ch) { result.append("\\") }
      result.append(ch)
    }
    return result
  }
}
