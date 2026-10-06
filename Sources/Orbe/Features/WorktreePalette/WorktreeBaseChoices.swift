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

/// ベースを選ぶ画面の候補 1 つ。
struct WorktreeBaseCandidate: Equatable {
  let name: String
  let relativeDate: String
  let isRemote: Bool
}
