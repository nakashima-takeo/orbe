import Foundation

/// ツリーの絞り込みの対象を git に問い合わせる 2 回のコマンドの、引数と出力の解析。どちらも作業ツリーの根を cwd にして実行し、
/// パスはその根からの相対パスで返る。
enum GitFileList {
  /// (a) 追跡しているファイル（`H` ほか。モードつき）・削除された追跡ファイル（`R`）・無視されていない未追跡のファイル（`?`）。
  /// skip-worktree の追跡ファイル（`S`。sparse checkout の範囲外など）は、ディスクに無くても `R` にならない。
  static let listedArguments = [
    "ls-files", "-z", "-t", "-s", "-c", "-d", "-o", "--exclude-standard",
  ]
  /// (b) 無視されているもの。フォルダとして無視されているものはフォルダのまま（末尾が `/`）で返り、git はその中を走査しない。
  static let ignoredArguments = [
    "ls-files", "-z", "-o", "-i", "--exclude-standard", "--directory",
  ]

  /// (a) の解析結果。
  struct Listed: Equatable {
    /// 対象のファイル（追跡しているもののうち削除されていないものと、未追跡のもの。同じパスは 1 つ）。
    var files: [String] = []
    /// skip-worktree の追跡ファイル。ディスクに在るかは出力から分からないので、呼び出し元が確かめる。
    var skipped: [String] = []
    /// 入れ子の根（サブモジュールと、入れ子のリポジトリ。末尾の `/` は外す）。
    var nestedRoots: [String] = []
  }

  private static let submoduleMode = "160000"

  /// (a) の出力を解析する。競合しているファイルは、ステージ番号 1〜3 で同じパスが重複して出力されるので 1 つにする。サブモジュールの
  /// 行（モード 160000）と、未追跡で末尾が `/` の行（入れ子のリポジトリ）は入れ子の根として返す。解析できない行は破棄する。
  static func parseListed(_ data: Data) -> Listed {
    var tracked: [String] = []
    var skipped: [String] = []
    var untracked: [String] = []
    var deleted = Set<String>()
    var nested: [String] = []
    for record in records(data) {
      guard record.count > 2, record.dropFirst().first == " " else { continue }
      let tag = record.first
      let rest = String(record.dropFirst(2))
      if tag == "?" {
        if rest.hasSuffix("/") {
          nested.append(String(rest.dropLast()))
        } else {
          untracked.append(rest)
        }
        continue
      }
      guard let tab = rest.firstIndex(of: "\t") else { continue }
      let fields = rest[..<tab].split(separator: " ")
      let path = String(rest[rest.index(after: tab)...])
      guard fields.count == 3, fields[0].count == 6, !path.isEmpty else { continue }
      if tag == "R" {
        deleted.insert(path)
      } else if fields[0] == submoduleMode {
        nested.append(path)
      } else if tag == "S" {
        skipped.append(path)
      } else {
        tracked.append(path)
      }
    }
    var seen = Set<String>()
    var listed = Listed()
    for path in tracked where !deleted.contains(path) && seen.insert(path).inserted {
      listed.files.append(path)
    }
    listed.files += untracked
    listed.skipped = skipped
    listed.nestedRoots = Array(Set(nested)).sorted()
    return listed
  }

  /// (b) の出力を解析する。末尾が `/` でない行（無視されているファイル）だけを対象にする。
  static func parseIgnored(_ data: Data) -> [String] {
    records(data).filter { !$0.hasSuffix("/") }
  }

  /// NUL で区切ったレコード。UTF-8 として読めないパスは破棄する。
  private static func records(_ data: Data) -> [String] {
    data.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
  }
}
