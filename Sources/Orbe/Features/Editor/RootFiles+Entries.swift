import Foundation
import OrbeEditorCore

/// 一覧と新規作成。
extension RootFiles {
  /// ディレクトリの中身（`.git` を除く。ドットファイルは含む）。名前順（`FileNameOrder`——検索結果と同じ比べ方）。
  /// 種別は 1 件ずつ属性辞書（`attributesOfItem`。owner / group の名前解決まで走る）で取ると数千件で
  /// main が止まるので、resource value で取る。URL は呼び手の綴り（正準形）で組み直す——一覧が返す URL は
  /// 実パス（`/private/…`）になる。
  func entries(of directory: URL) throws -> [Entry] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
    )
    .filter { $0.lastPathComponent != ".git" }
    .map { found in
      let name = found.lastPathComponent
      let isDirectory =
        (try? found.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      return Entry(
        name: name, url: directory.appendingPathComponent(name, isDirectory: isDirectory),
        isDirectory: isDirectory)
    }
    .sorted { FileNameOrder.precedes($0.name, $1.name) }
  }

  /// 空ファイルを作る。既に在れば失敗。中間ディレクトリは作らない。
  func createFile(at url: URL) throws {
    guard !Self.exists(url) else { throw Error.alreadyExists(url) }
    try Data().write(to: url)
  }

  /// フォルダを作る。既に在れば失敗。中間ディレクトリは作らない。
  func createDirectory(at url: URL) throws {
    guard !Self.exists(url) else { throw Error.alreadyExists(url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }

  /// 一覧と同じ土俵（symlink を辿らない）。`fileExists` は辿るので、壊れた symlink を「無い」と見て
  /// リンク先（根の外もありうる）へ書いてしまう。
  private static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }
}
