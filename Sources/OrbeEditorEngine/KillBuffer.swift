/// キルバッファ（⌃K で消した文字列。⌃Y で入れる）。アプリ全体で 1 つ——AppKit のものは公開の口が無いので、エンジンが持つ。
@MainActor
enum KillBuffer {
  static var contents = ""
}
