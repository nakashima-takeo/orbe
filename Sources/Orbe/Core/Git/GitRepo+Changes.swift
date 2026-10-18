import Foundation

// MARK: - 変更の書き込み（ステージ・解除・破棄。コミット・取り消しは `GitRepo+Commit`）

/// 利用者が起こす index・作業ツリー・HEAD への書き込み。どれも無出力で打ち切らず、`handle` で止める（hook・filter・
/// 署名の沈黙は「何も起きていない」ことを意味しない）。順番は呼び出し側（根のサービス）が作る——同じ worktree の
/// index へ同時に書けば、git は index.lock で待たずに落ちる。completion は main で返る。
///
/// パスはファイル名そのもの（ユーザーのデータ）なので、NUL 区切りの標準入力で渡し、その呼び出しだけ pathspec を
/// literal にする（`*` `:` を含む名前で別のファイルに当たらない。引数の長さの上限も越えない）。
extension GitRepo {
  /// 行をステージする（変更・削除・未追跡のどれでも、作業ツリーの姿を index へ）。含めるパスは呼んだ時点の index と
  /// 作業ツリーで選び直す（`selection`）。
  func stage(
    rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    select(rows, handle: handle) { selected in
      switch selected {
      case .failure(let failure): completion(failure)
      case .success(let selection):
        self.runOnPaths(
          ["add", "-A"], paths: selection.paths, handle: handle, completion: completion)
      }
    }
  }

  /// 行のステージを解く（index を HEAD の版へ。初回コミット前なら index から外す）。rename の行は元パスも常に含める
  /// ——index 側で rename の両側を揃えて戻すため。`restore --staged` は HEAD が無いと落ちるので `reset` を使う。
  func unstage(
    rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    runOnPaths(
      ["reset", "-q"], paths: rows.flatMap(\.paths), handle: handle, completion: completion)
  }

  /// 行の変更を捨てる。含めるパスは呼んだ時点の index と作業ツリーで選び直す（`selection`）。
  /// - 追跡中のパスは作業ツリーを index の版へ戻す（ステージ済みの分は残る）。サブモジュールの中は、利用者の
  ///   `submodule.recurse` に依らず触れない（従うと中の未コミットの作業を消し、中で作ったコミットから HEAD を戻す）。
  /// - 未追跡のパスはゴミ箱へ移す（元に戻せる）。戻す前に、戻す場所を塞いでいる未追跡のもの（`blockers`。git の restore
  ///   はそれを黙って消す）と同じ段で移す——戻した後では、戻したディレクトリが未追跡のパスに当たりうる（塞いでいた親の行・
  ///   大文字小文字だけ違う名前）。restore が落ちても、それまでに移した分はゴミ箱に在る。
  /// - intent-to-add（`git add -N`）のパスは、作業ツリーに在れば最初に index から外し、未追跡のパスと同じ段でゴミ箱へ
  ///   ——index の版は空なので、戻すと中身を失う。作業ツリーから消えたものは index の版（空）へ戻る。
  ///
  /// 追跡中かは観測の status でなく呼んだ時点の index で決める（status が古いとき、追跡中のファイルをゴミ箱へ送らない）。
  /// ゴミ箱へは裏のスレッドで 1 件ずつ移し、その都度止められたかを見る（件数が多いと main を止めるため）。移せなければ
  /// 失敗で返し、消さない。
  func discard(
    rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    select(rows, handle: handle) { selected in
      switch selected {
      case .failure(let failure): completion(failure)
      case .success(let selection): self.discard(selection, handle: handle, completion: completion)
      }
    }
  }

  private func discard(
    _ selection: Selection, handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    intentToAdd(among: selection.indexed, handle: handle) { found in
      guard case .success(let intended) = found else {
        if case .failure(let failure) = found { completion(failure) }
        return
      }
      let restore = selection.indexed.subtracting(intended)
      let unindex = ["rm", "--cached", "-q"]
      self.runOnPaths(unindex, paths: Array(intended), handle: handle) { removed in
        if let removed { return completion(removed) }
        let untracked = {
          self.blockers(of: restore, submodules: selection.submodules)
            + selection.paths.filter { !restore.contains($0) }
        }
        self.moveToTrash(untracked, handle: handle) { cleared in
          if let cleared { return completion(cleared) }
          let checkout = ["restore", "--worktree", "--no-recurse-submodules"]
          self.runOnPaths(checkout, paths: Array(restore), handle: handle, completion: completion)
        }
      }
    }
  }

  /// ステージ・破棄に含めるパスと、そのうち呼んだ時点の index に載っているもの・サブモジュールとして載っているもの。
  /// `unmerged` は、その index に競合（stage が 0 でないエントリ）が残っているか。
  struct Selection {
    let paths: [String]
    let indexed: Set<String>
    let submodules: Set<String>
    let unmerged: Bool
  }

  /// 行から、ステージ・破棄に含めるパスを呼んだ時点の index と作業ツリーで選び直す。
  /// - 行のパスは、index に在るか作業ツリーに在るときだけ（status を読んだ後に消えた未追跡は含めない——add の pathspec が
  ///   一致しないと、git は全体を止める）。
  /// - rename の元パスは、index に在るときだけ。作業ツリー側の rename（`.R`）では元パスは index に在り、その削除が含まれる。
  ///   ステージ済みの rename（`R.`・`RM`）では元パスは index に無く、そこへ置き直された別の未追跡ファイルを巻き込まない。
  ///
  /// index は丸ごと読む——`ls-files` はパスを標準入力で受けられず、引数では長さの上限を越えうる。読みと作業ツリーの
  /// 確かめは裏のスレッドで済ませる。stage の番号つきで読み、競合が残っているかも同じ読みで答える（コミットが使う）。
  func select(
    _ rows: [GitStatus.Row], handle: GitRunner.Handle,
    completion: @escaping (Result<Selection, GitWriteFailure>) -> Void
  ) {
    let asked = Set(rows.flatMap(\.paths))
    runner.run(
      ["ls-files", "-s", "-z"], cwd: root, handle: handle,
      transform: { listed -> Result<Selection, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        var indexed = Set<String>()
        var submodules = Set<String>()
        var unmerged = false
        // `<mode> <object> <stage>\t<path>`
        for entry in listed.stdout.split(separator: 0) {
          guard let tab = entry.firstIndex(of: 0x09) else { continue }
          if tab > entry.startIndex, entry[entry.index(before: tab)] != 0x30 { unmerged = true }
          if let path = String(bytes: entry[entry.index(after: tab)...], encoding: .utf8),
            asked.contains(path)
          {
            indexed.insert(path)
            if entry.starts(with: Self.gitlinkMode) { submodules.insert(path) }
          }
        }
        var paths: [String] = []
        for row in rows {
          if indexed.contains(row.path) || Self.exists(self.url(of: row.path)) {
            paths.append(row.path)
          }
          if let original = row.originalPath, indexed.contains(original) { paths.append(original) }
        }
        return .success(
          Selection(paths: paths, indexed: indexed, submodules: submodules, unmerged: unmerged))
      }, completion: completion)
  }

  /// `paths` のうち intent-to-add のもの（index の版は空の blob で、作業ツリーとの差は「追加」として出る）。
  private func intentToAdd(
    among paths: Set<String>, handle: GitRunner.Handle,
    completion: @escaping (Result<Set<String>, GitWriteFailure>) -> Void
  ) {
    guard !paths.isEmpty else {
      return DispatchQueue.main.async { completion(.success([])) }
    }
    runner.run(
      ["diff-files", "-z", "--name-only", "--diff-filter=A"], cwd: root, handle: handle,
      transform: { listed -> Result<Set<String>, GitWriteFailure> in
        if let failure = GitWriteFailure.of(listed) { return .failure(failure) }
        return .success(
          Set(
            listed.stdout.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }
              .filter(paths.contains)))
      }, completion: completion)
  }

  /// ゴミ箱の行き先の差し替え（テスト用。隔離ハーネスが毎テスト caseDir の下へ張る）。nil なら利用者のゴミ箱。
  nonisolated(unsafe) static var trashDirectoryOverride: URL?

  /// index でサブモジュール（gitlink）のエントリの mode。
  private static let gitlinkMode = Data("160000 ".utf8)

  /// 戻すパス `paths` の場所を塞いでいる未追跡のもの——パスの場所にあるディレクトリ（サブモジュールの場所を除く。同じ名前の
  /// ディレクトリ・入れ子のリポジトリ）と、ディレクトリでない親の階層（ファイル・symlink に置き換えた親）。裏のスレッドで呼ぶ。
  private func blockers(of paths: Set<String>, submodules: Set<String>) -> [String] {
    var found: [String] = []
    var clear = Set<String>()
    for path in paths.sorted() {
      var parent = ""
      var blocked = false
      for component in path.split(separator: "/").dropLast() {
        parent = parent.isEmpty ? String(component) : parent + "/" + component
        guard !clear.contains(parent) else { continue }
        let type = Self.fileType(at: url(of: parent))
        guard type == nil || type == .typeDirectory else {
          if !found.contains(parent) { found.append(parent) }
          blocked = true
          break
        }
        clear.insert(parent)
        if type == nil { break }
      }
      if !blocked, !submodules.contains(path), Self.fileType(at: url(of: path)) == .typeDirectory {
        found.append(path)
      }
    }
    return found
  }

  /// 裏のスレッドで `paths` を引き、1 件ずつゴミ箱へ移し、その都度止められたかを見る。completion は main で返る。
  private func moveToTrash(
    _ paths: @escaping () -> [String], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      var failure: GitWriteFailure?
      // 無いパスは、捨てるものが無いので飛ばす——選んだ後に消えたもの・同じ段で先に移したもの（同じパス・その中・大文字小文字だけ違う名前）。
      for url in paths().map(self.url(of:)) where Self.exists(url) {
        guard !handle.isCancelled else {
          failure = .cancelled
          break
        }
        do {
          try Self.moveToTrash(url)
        } catch {
          failure = .reason(error.localizedDescription)
          break
        }
      }
      DispatchQueue.main.async { completion(failure) }
    }
  }

  private static func moveToTrash(_ url: URL) throws {
    guard let directory = trashDirectoryOverride else {
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      return
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: url, to: directory.appendingPathComponent(url.lastPathComponent))
  }

  /// パスの操作。空なら git を起こさずに成功で返す——パスの無い `add -A`・`reset`・`restore`・`rm` は全体に効く。
  func runOnPaths(
    _ args: [String], paths: [String], handle: GitRunner.Handle,
    completion: @escaping (GitWriteFailure?) -> Void
  ) {
    guard !paths.isEmpty else { return DispatchQueue.main.async { completion(nil) } }
    let list = paths.map { $0 + "\0" }.joined()
    runner.run(
      args + ["--pathspec-from-file=-", "--pathspec-file-nul"], cwd: root, stdin: Data(list.utf8),
      environment: ["GIT_LITERAL_PATHSPECS": "1"], timesOut: false, handle: handle
    ) { completion(.of($0)) }
  }

  private func url(of relativePath: String) -> URL {
    URL(fileURLWithPath: root).appendingPathComponent(relativePath)
  }

  /// symlink を辿らずに在るか（壊れた symlink も在る）。
  private static func exists(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  /// symlink を辿らない種類（無ければ nil）。
  private static func fileType(at url: URL) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
  }
}
