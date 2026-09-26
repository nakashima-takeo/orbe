import Foundation

/// プロジェクト検索のディスク側——git grep の引数と、`-z -n` の出力を流しながら行へ割る解析。根が git 管理下でも管理外でも
/// 同じ 1 つの形（`--no-index --exclude-standard`）で探す: どこでも `.gitignore`（入れ子も）・`.git/info/exclude`・
/// `core.excludesFile` が効き、バイナリ（`-I`）と既定の除外は外れ、サブモジュールと入れ子のリポジトリの中も探す。
/// 出力の形に効く設定（`grep.*`・`color.*`）は引数で明示して、ユーザーの git 設定に形を変えさせない。
enum GitGrep {
  /// 既定の除外（VS Code の `search.exclude` と `files.exclude` の既定）。ディレクトリは配下ごと、ファイルは名前で。
  static let excludedDirectories = ["node_modules", "bower_components", ".git", ".svn", ".hg", ".jj"]
  static let excludedFiles = [".DS_Store", "Thumbs.db"]
  static let excludedExtensions = ["code-search"]

  /// grep だけに足す環境——UTF-8 のロケールが無いと PCRE2 の大小無視が ASCII に落ちる。
  static let environment = ["LC_ALL": "en_US.UTF-8"]

  static func arguments(pattern: String) -> [String] {
    [
      "grep", "--no-index", "--exclude-standard", "-z", "-n", "--no-column", "-I", "--no-color",
      "--no-textconv", "-P", "-e", pattern, "--", ".",
    ]
      + excludedDirectories.map { ":(exclude,glob)**/\($0)/**" }
      + excludedFiles.map { ":(exclude,glob)**/\($0)" }
      + excludedExtensions.map { ":(exclude,glob)**/*.\($0)" }
  }

  /// 根からの相対パスが既定の除外に当たるか（開いている文書をメモリで探すかの判定。git に渡す除外と同じ規則）。
  static func isExcluded(_ relativePath: String) -> Bool {
    let components = relativePath.split(separator: "/").map(String.init)
    guard let name = components.last else { return false }
    return components.dropLast().contains(where: excludedDirectories.contains)
      || excludedFiles.contains(name)
      || excludedExtensions.contains((name as NSString).pathExtension)
  }

  /// 一致した 1 行。`number` は 1 始まり、`text` は改行を除いた行（`\r` は残る）。
  struct Line: Equatable {
    let path: String
    let number: Int
    let text: String
  }

  /// `path\0number\0text\n` の列を、塊の境で割れた行を持ち越しながら行へ割る。パスは `-z` なので引用されず、`\n` を
  /// 含みうる（区切りは NUL で読む）。本文の UTF-8 でないバイトは置換文字で読む。
  struct Parser {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [Line] {
      pending.append(data)
      var lines: [Line] = []
      var start = pending.startIndex
      while let pathEnd = pending[start...].firstIndex(of: 0),
        let numberEnd = pending[(pathEnd + 1)...].firstIndex(of: 0),
        let textEnd = pending[(numberEnd + 1)...].firstIndex(of: 0x0A)
      {
        let number = Int(Self.decode(pending[(pathEnd + 1)..<numberEnd])) ?? 0
        lines.append(
          Line(
            path: Self.decode(pending[start..<pathEnd]), number: number,
            text: Self.decode(pending[(numberEnd + 1)..<textEnd])))
        start = textEnd + 1
      }
      pending = Data(pending[start...])
      return lines
    }

    /// 不正なバイトは U+FFFD へ落として読む。lint は失敗しうる initializer を求めるが、ここで欲しいのは読めた分の行
    /// （UTF-8 でないファイルの 1 バイトで、その行の一致を丸ごと捨てない）。
    private static func decode(_ bytes: Data) -> String {
      // swiftlint:disable:next optional_data_string_conversion
      String(decoding: bytes, as: UTF8.self)
    }
  }

  /// 終了の読み: 0 は一致あり、1 は一致なし、それ以外は stderr の最初の行を問いのエラーとして出す。
  static func failure(of output: GitRunner.Output) -> String? {
    guard output.exited, output.status != 0, output.status != 1 else { return nil }
    let first = output.stderrText.split(separator: "\n").first.map(String.init)
    return first ?? "git grep \(output.status)"
  }
}
