import Foundation
import OrbeEditorCore

/// 一覧と新規作成。
extension RootFiles {
  /// 名前 `name` の項目を一覧に出すか。`.git` は、フォルダでもファイル（worktree・サブモジュールの印や、壊れた `.git`）でも
  /// 出さない。ツリーの一覧・連なりの先読み・絞り込みの対象の走査が、この 1 つの判定で数える。
  nonisolated static func isListed(_ name: String) -> Bool {
    name != ".git"
  }

  /// ディレクトリの中身（`.git` を除く。ドットファイルは含む）。名前順（`FileNameOrder`——検索結果と同じ比べ方）。
  /// 種別は 1 件ずつ属性辞書（`attributesOfItem`。owner / group の名前解決まで走る）で取ると数千件で
  /// main が止まるので、resource value で取る。URL は呼び手の綴り（正準形）で組み直す——一覧が返す URL は
  /// 実パス（`/private/…`）になる。
  func entries(of directory: URL) throws -> [Entry] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
    )
    .filter { Self.isListed($0.lastPathComponent) }
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

  /// フォルダ `directory` の中身（`.git` を除く）がフォルダ 1 つだけなら、その名前。読むのは多くて 2 件で、symlink は
  /// フォルダと数えない（`entries(of:)` と同じ土俵）。読めなければ nil。裏で呼ぶ。
  nonisolated static func onlyChildDirectory(of directory: URL) -> String? {
    var only: String?
    var isOnly = true
    forEachChild(of: directory.path) { name, isDirectory in
      guard only == nil, isDirectory else {
        isOnly = false
        return false
      }
      only = name
      return true
    }
    return isOnly ? only : nil
  }

  /// フォルダ `path` の中身のうち一覧に出すもの（`isListed`）を 1 件ずつ、名前とフォルダか（symlink はフォルダと数えない）で
  /// `body` へ渡す。`body` が false を返したらそこで止める。UTF-8 として読めない名前は飛ばす。読めなければ何も渡さない。
  nonisolated static func forEachChild(of path: String, _ body: (String, Bool) -> Bool) {
    guard let stream = opendir(path) else { return }
    defer { closedir(stream) }
    while let entry = readdir(stream) {
      let bytes = withUnsafeBytes(of: entry.pointee.d_name) { raw in Data(raw.prefix { $0 != 0 }) }
      guard let name = String(bytes: bytes, encoding: .utf8), name != ".", name != "..",
        isListed(name)
      else {
        continue
      }
      var type = entry.pointee.d_type
      if type == UInt8(DT_UNKNOWN) {
        // `d_type` を返さないファイルシステムでは、symlink を辿らずに種類を引く。
        var info = stat()
        guard lstat(path + "/" + name, &info) == 0 else { continue }
        type = info.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
      }
      if !body(name, type == UInt8(DT_DIR)) { return }
    }
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
