import Foundation
import OrbeEditorCore

/// 開いている文書 1 つと、その実体が属する根のサービスを結ぶ。文書と同寿命で、サービスを握る者であり
/// 自分の 1 ファイルの index の版に関心を申告する観測者。外部変更の照合と baseline の受け渡しを担う。
///
/// 根は文書の実体のディレクトリから解く（タブの根ではない——制御 API で外のファイルを開いても、その文書の
/// baseline と外部変更は自分のリポジトリで見る）。baseline は index の版の本文で、その版に無い・読めない・取れない
/// なら無し。
@MainActor
final class DocumentLink: RootFilesObserver {
  let files: RootFiles
  let document: EditorDocument
  /// 文書の実体のパス（根の綴り＝正規形）。監視の通知のパスと比べる。
  private let path: String
  /// 文書の index の版（根の外なら nil）。
  private let index: RootFiles.Version?

  init(document: EditorDocument) {
    self.document = document
    path = GitWorktreeRoot.normalizedPath(document.url.path)
    files = RootFiles.shared(
      for: GitWorktreeRoot.root(of: (path as NSString).deletingLastPathComponent))
    index = files.relativePath(of: document.url).map {
      RootFiles.Version(path: $0, revision: .index)
    }
    files.addObserver(self, versions: Set(index.map { [$0] } ?? []))
    applyBaseline()
  }

  deinit {
    let files = self.files
    MainActor.assumeIsolated { files.removeObserver(self) }
  }

  private func applyBaseline() {
    document.baseline = index.flatMap { files.state(of: $0)?.text }
  }

  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    guard change.includes(path) else { return }
    document.reconcileWithDisk()
  }

  func rootFilesStatusDidChange(_ files: RootFiles) {}

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {
    guard version == index else { return }
    applyBaseline()
  }
}
