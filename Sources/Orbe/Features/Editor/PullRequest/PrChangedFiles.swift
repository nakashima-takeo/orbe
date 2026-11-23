import Foundation
import OrbeEditorCore

/// PR の変更ファイルの 2 つの並びと、パスからの索引。PR ごとの状態が中身を読んだときに 1 回作り、PR のパネルの行の組と
/// 上のバーの変更ファイルの一覧が同じ並びを使う（描くたび・一覧を開くたびに並べ直さず、全件を探さない）。
struct PrChangedFiles {
  /// 1 つの並びと、パスからその並びの番号への索引。
  struct Order {
    let files: [GitHubPullRequestContent.File]
    let index: [String: Int]

    init(_ files: [GitHubPullRequestContent.File]) {
      self.files = files
      index = Dictionary(
        files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
    }
  }

  static let empty = PrChangedFiles([])

  /// リスト表示の並び——ソース管理の行と同じパス順。
  let list: Order
  /// ツリー表示の並び——ツリーを全部開いたときにファイルの行が上から並ぶ順（どの段でもフォルダが先、名前順）。フォルダの
  /// 配下のファイルは、この並びの中で続いて並ぶ。
  let tree: Order

  init(_ files: [GitHubPullRequestContent.File]) {
    list = Order(
      files.map { (FileNameOrder.PathKey($0.path), $0) }
        .sorted { FileNameOrder.comparePaths($0.0, $1.0) == .orderedAscending }
        .map(\.1))
    tree = Order(Self.treeOrder(files))
  }

  /// ツリー表示なら `tree`、リスト表示なら `list`。
  func order(asTree: Bool) -> Order { asTree ? tree : list }

  /// ファイル `path` の変化の種類（変更ファイルに無ければ nil）。
  func change(of path: String) -> GitHubPullRequestContent.Change? {
    list.index[path].map { list.files[$0].change }
  }

  /// フォルダの木の 1 段。
  private final class Folder {
    var folders: [String: Folder] = [:]
    var files: [GitHubPullRequestContent.File] = []
  }

  private static func treeOrder(_ files: [GitHubPullRequestContent.File])
    -> [GitHubPullRequestContent.File]
  {
    let root = Folder()
    for file in files {
      var folder = root
      for name in file.path.split(separator: "/").dropLast().map(String.init) {
        let next = folder.folders[name] ?? Folder()
        folder.folders[name] = next
        folder = next
      }
      folder.files.append(file)
    }
    var ordered: [GitHubPullRequestContent.File] = []
    ordered.reserveCapacity(files.count)
    append(root, into: &ordered)
    return ordered
  }

  private static func append(_ folder: Folder, into ordered: inout [GitHubPullRequestContent.File])
  {
    for name in folder.folders.keys.sorted(by: FileNameOrder.precedes) {
      append(folder.folders[name]!, into: &ordered)
    }
    ordered += folder.files.sorted {
      FileNameOrder.precedes(
        ($0.path as NSString).lastPathComponent, ($1.path as NSString).lastPathComponent)
    }
  }
}
