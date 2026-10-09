import Foundation

// MARK: - 観測（status・index の読み）

/// 前の値と比べた status の読み。
enum GitStatusRead: Equatable {
  case changed(GitStatus)
  /// 前の値と同じ。
  case unchanged
  /// git が失敗した。
  case failed
}

extension GitRepo {
  /// status の見え方を左右するユーザー設定を引数で封じる——`status.showUntrackedFiles`（未追跡はファイル単位）・
  /// `diff.ignoreSubmodules`・`status.aheadBehind`（先行/遅れは必ず数える）・`status.renames`（rename は必ず検出する）。
  /// ブランチのヘッダを必ず出す。`--no-optional-locks` で index を書き換えない。パスは `-z` で verbatim に出る
  /// （`core.quotepath` は参照されない）。
  static let statusArguments = [
    "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--ahead-behind",
    "--renames", "--untracked-files=all", "--ignore-submodules=none",
  ]

  /// worktree の status を `previous` と比べて返す（nil と比べれば、成功は必ず `changed`）。未追跡が多いと出力も値も
  /// 大きい（2 万件で約 0.4MB・2 万エントリ）ので、解析と比較は裏のスレッドで済ませ、main には変わったかと新しい値だけを
  /// 渡す。同じだったときの新しい値も裏で捨てる。
  func status(
    comparedTo previous: GitStatus?, completion: @escaping (GitStatusRead) -> Void
  ) {
    runner.run(
      Self.statusArguments, cwd: root,
      transform: { output -> GitStatusRead in
        guard output.isSuccess else { return .failed }
        let status = GitStatus.parse(output.stdout)
        return status == previous ? .unchanged : .changed(status)
      }, completion: completion)
  }

  /// index にある blob の OID（相対パス → OID。stage 0 だけ＝競合中のパスは含まない）。
  /// 空の問い合わせは git を起こさない。git が失敗したら nil。
  ///
  /// パスはファイル名そのもの（ユーザーのデータ）なので pathspec として解釈させない——`:` 始まりは magic、
  /// `*` `[` は glob で、`:(` 始まりは fatal になって根の全 baseline が凍る。`:(literal)` を前置し、
  /// これを無効化する環境変数は `GitRunner` が落とす。
  func indexEntries(relativePaths: [String], completion: @escaping ([String: String]?) -> Void) {
    guard !relativePaths.isEmpty else {
      completion([:])
      return
    }
    runner.run(
      ["ls-files", "-s", "-z", "--"] + relativePaths.map { ":(literal)" + $0 }, cwd: root
    ) { output in
      guard output.isSuccess else {
        completion(nil)
        return
      }
      var entries: [String: String] = [:]
      for record in output.stdout.split(separator: 0) {
        // `<mode> <oid> <stage>\t<path>`
        guard let line = String(bytes: record, encoding: .utf8),
          let tab = line.firstIndex(of: "\t")
        else { continue }
        let fields = line[..<tab].split(separator: " ")
        guard fields.count == 3, fields[2] == "0" else { continue }
        entries[String(line[line.index(after: tab)...])] = String(fields[1])
      }
      completion(entries)
    }
  }

  /// HEAD のツリーにある blob の OID（相対パス → OID。無いもの・ファイルでないもの（submodule・ディレクトリ）は含まない。
  /// 初回コミット前は空）。空の問い合わせは git を起こさない。git が失敗したら nil。
  ///
  /// 名前は `HEAD:<パス>` で cat-file に問う——pathspec を通らないので、パスが magic・glob に解釈されない。答えは問いの順に
  /// 1 行ずつで、無ければ `<名前> missing`。パスは改行を含みうるので、行で割らず問いの名前で前から読む。
  func headEntries(relativePaths: [String], completion: @escaping ([String: String]?) -> Void) {
    guard !relativePaths.isEmpty else {
      completion([:])
      return
    }
    let names = relativePaths.map { "HEAD:" + $0 }
    runner.run(
      ["cat-file", "-z", "--batch-check=%(objectname) %(objecttype)"], cwd: root,
      stdin: Data(names.map { $0 + "\0" }.joined().utf8)
    ) { output in
      guard output.isSuccess else { return completion(nil) }
      completion(Self.blobAnswers(output.stdout, names: names, paths: relativePaths))
    }
  }

  /// `cat-file --batch-check=%(objectname) %(objecttype)` の答えを問いの順に読む（blob だけ）。形が崩れていれば nil。
  static func blobAnswers(_ data: Data, names: [String], paths: [String]) -> [String: String]? {
    let bytes = [UInt8](data)
    var at = 0
    var entries: [String: String] = [:]
    for (name, path) in zip(names, paths) {
      let missing = Array((name + " missing\n").utf8)
      if bytes.count - at >= missing.count, bytes[at..<(at + missing.count)].elementsEqual(missing)
      {
        at += missing.count
        continue
      }
      guard let end = bytes[at...].firstIndex(of: 0x0A),
        let line = String(bytes: bytes[at..<end], encoding: .utf8)
      else { return nil }
      at = end + 1
      let fields = line.split(separator: " ")
      guard fields.count == 2, fields[0].allSatisfy(\.isHexDigit) else { return nil }
      if fields[1] == "blob" { entries[path] = String(fields[0]) }
    }
    return entries
  }

  /// blob を作業ツリーに出したときの中身——`relativePath` の属性で smudge filter と eol 変換を掛けた
  /// バイト列（clean と smudge が往復する filter なら、git が clean と言う姿と同じ底）。smudge の実行コマンドは
  /// config 側にしか書けないので、信頼できないリポジトリのコードが実行される面は checkout と同じ。textconv・
  /// 外部 diff は通らない。git が失敗したら nil。
  func blob(oid: String, relativePath: String, completion: @escaping (Data?) -> Void) {
    runner.run(
      ["cat-file", "--filters", "--path=" + relativePath, oid], cwd: root
    ) { output in
      completion(output.isSuccess ? output.stdout : nil)
    }
  }
}
