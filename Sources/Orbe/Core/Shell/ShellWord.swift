import Foundation

/// シェルの単語 1 つとしての引用。安全な文字だけならそのまま、それ以外は単引用符で囲む（中の単引用符は `'\''`）。
enum ShellWord {
  static func quoted(_ word: String) -> String {
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static let safe = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@+%")
}
