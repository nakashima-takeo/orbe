import Foundation

/// 監視——根と git dir の変化を観測者に知らせ、取り直しを求める。
extension RootFiles {
  func watch(roots: [String], gitDirs: [String]) -> RepoWatcher? {
    RepoWatcher(roots: roots, gitDirs: gitDirs) { [weak self] batch in self?.handle(batch) }
  }

  private func handle(_ batch: RepoWatcher.Batch) {
    if batch.scanAll {
      notify { $0.rootFiles(self, filesDidChange: .scanAll) }
    } else if !batch.paths.isEmpty {
      notify { $0.rootFiles(self, filesDidChange: .paths(batch.paths)) }
    }
    if repo != nil, batch.gitChanged || batch.scanAll {
      notify { $0.rootFilesGitStateDidChange(self, remoteRefsChanged: batch.remoteRefsChanged) }
    }
    requestStatusRefresh()
    requestVersionRefresh()
  }
}
