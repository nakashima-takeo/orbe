import Foundation

/// ベースの選択肢を組む事実（provider が git の列挙から渡す。fetch の着地や削除で引き直すたびに更新）。
struct WorktreeBaseFacts: Equatable {
  /// workspace に保存された前回のベース。今の列挙（ローカルとリモートのブランチ）にあるときだけ。
  var previous: String?
  /// 既定ブランチの今の解決値（表示名。作成時は意図 `.defaultBranch` で解決し直す）。
  var defaultBranch: String
  /// 今の worktree のブランチ（ローカル名）。detached は nil。
  var current: String?
}

/// ベースの選択肢の役割（ボタンの札）。並びもこの順。
enum WorktreeBaseRole: Hashable {
  case previous, defaultBranch, current
  /// ベースを選ぶ画面で選んだ名前。
  case picked
  /// 「ほか…」。ベースを選ぶ画面への入口。
  case other
}

/// ベースのバーの 1 つの選択肢。
struct WorktreeBaseChoice: Equatable {
  let role: WorktreeBaseRole
  /// 作成に渡す意図。「ほか…」は nil。
  let base: WorktreeBase?
  /// ボタンに出す名前。「ほか…」は空。
  let name: String
}

/// 事実と「ほかで選んだ名前」から選択肢の列を組む純関数。
enum WorktreeBaseChoices {
  /// 前回・既定・現在・ほかで選んだ名前の順に、同じ名前に解決するものを 1 つにまとめて並べ（札は前に
  /// 来る役割を残す）、最後に「ほか…」を置く。
  static func build(facts: WorktreeBaseFacts?, picked: String?) -> [WorktreeBaseChoice] {
    var candidates: [WorktreeBaseChoice] = []
    if let facts {
      if let previous = facts.previous {
        candidates.append(.init(role: .previous, base: .ref(previous), name: previous))
      }
      candidates.append(
        .init(role: .defaultBranch, base: .defaultBranch, name: facts.defaultBranch))
      if let current = facts.current {
        candidates.append(.init(role: .current, base: .ref(current), name: current))
      }
    }
    if let picked {
      candidates.append(.init(role: .picked, base: .ref(picked), name: picked))
    }
    var seen: Set<String> = []
    let unique = candidates.filter { seen.insert($0.name).inserted }
    return unique + [.init(role: .other, base: nil, name: "")]
  }

  /// まだ選んでいないときの選択（前回、無ければ既定）。
  static func initialRole(in choices: [WorktreeBaseChoice]) -> WorktreeBaseRole? {
    [.previous, .defaultBranch].first { role in choices.contains { $0.role == role } }
  }
}

/// 作成行を出すかの、名前と作成先の衝突の規則。git の答え（ブランチ名として有効か）とは別に、
/// ぶつかる名前・作成先の作成行を出さない。
struct WorktreeNewBranchRules: Equatable {
  /// 作れない名前。ローカルブランチ（worktree で checkout 中のものを含む）と、リモートブランチの行が
  /// 作るローカル名——リモートブランチと同じ名前を別のベースから切ると、その行と同じ名前の別物になる。
  var takenNames: Set<String>
  /// 既存の worktree のパス（シンボリックリンクを解いた値）。
  var worktreePaths: Set<String>
  /// 作成先のテンプレート（設定 `worktree-dir` の実効値）と、それを解決する repo の場所。
  var template: String
  var repoPath: String

  init(takenNames: Set<String>, worktreePaths: [String], template: String, repoPath: String) {
    self.takenNames = takenNames
    self.worktreePaths = Set(worktreePaths.map(Self.canonical))
    self.template = template
    self.repoPath = repoPath
  }

  /// その名前の作成行を出してよいか。作成先が既存の worktree と同じ場所になる名前（`issue-212` と
  /// `issue/212` は同じ slug）は、作成が必ず失敗するので出さない。
  func allows(_ name: String) -> Bool {
    guard !takenNames.contains(name) else { return false }
    let path = WorktreePathTemplate.resolve(
      template: template, repoPath: repoPath, slug: WorktreePathTemplate.slug(forBranch: name))
    return !worktreePaths.contains(Self.canonical(path))
  }

  private static func canonical(_ path: String) -> String {
    (path as NSString).resolvingSymlinksInPath
  }
}

/// ベースを選ぶ画面の候補 1 つ。
struct WorktreeBaseCandidate: Equatable {
  let name: String
  let relativeDate: String
  let isRemote: Bool
}
