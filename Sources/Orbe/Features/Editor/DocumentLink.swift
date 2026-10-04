import Foundation
import OrbeEditorCore

/// 開いている文書 1 つと、その実体が属する根のサービスを結ぶ。文書と同寿命で、サービスを握る者であり
/// 自分の 1 ファイルに関心を申告する観測者。外部変更の照合と baseline の受け渡しを担う。
///
/// 根は文書の実体のディレクトリから解く（タブの根ではない——制御 API で外のファイルを開いても、その文書の
/// baseline と外部変更は自分のリポジトリで見る）。
@MainActor
final class DocumentLink: RootFilesObserver {
  let files: RootFiles
  let document: EditorDocument
  /// 文書の実体のパス（根の綴り＝正規形）。監視の通知のパスと比べる。
  private let path: String

  init(document: EditorDocument) {
    self.document = document
    path = GitWorktreeRoot.normalizedPath(document.url.path)
    files = RootFiles.shared(
      for: GitWorktreeRoot.root(of: (path as NSString).deletingLastPathComponent))
    files.addObserver(self, interest: document.url)
    document.baseline = files.baseline(for: document.url)
  }

  deinit {
    let files = self.files
    MainActor.assumeIsolated { files.removeObserver(self) }
  }

  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    guard change.includes(path) else { return }
    document.reconcileWithDisk()
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {}

  func rootFiles(_ files: RootFiles, baselineDidChange url: URL) {
    guard url == document.url else { return }
    document.baseline = files.baseline(for: url)
  }
}
