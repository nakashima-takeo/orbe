import Foundation

/// ベースのバーの選択（⇧⇥ の巡回・クリック・ベースを選ぶ画面の決定）と、入力欄の ↵ の振り分け。選択は
/// インデックスではなく役割で持つ——選択肢の増減（fetch の着地で前回が現れる等）で、別のベースを指さない。
extension WorktreePaletteModel {

  /// 今の選択肢。選んだ役割が列に無ければ（未選択・組み直しで消えた）初期規則の役割。
  var selectedBaseChoice: WorktreeBaseChoice? {
    let role = selectedBaseRole ?? WorktreeBaseChoices.initialRole(in: baseChoices)
    return baseChoices.first { $0.role == role }
  }

  /// 選択行が作成行か（ベースのバーで選べるのはこのときだけ）。
  var isCreateRowSelected: Bool {
    if case .createBranch = selectedItem?.action { return true }
    return false
  }

  /// ⇧⇥。作成行の選択中だけ、ベースを次の選択肢へ巡回する（末尾から先頭へ回る）。
  func cycleBase() {
    guard !isLocked, isCreateRowSelected, let current = selectedBaseChoice,
      let index = baseChoices.firstIndex(of: current)
    else { return }
    selectedBaseRole = baseChoices[(index + 1) % baseChoices.count].role
  }

  /// ベースのボタンのクリック。「ほか…」はそのままベースを選ぶ画面を開く。
  func chooseBase(_ role: WorktreeBaseRole) {
    guard !isLocked, isCreateRowSelected, baseChoices.contains(where: { $0.role == role }) else {
      return
    }
    selectedBaseRole = role
    if role == .other { enterBasePicker() }
  }

  /// ベースを選ぶ画面で名前を決めた。列に入った（同じ名前の選択肢があればそれにまとまった）選択肢を選ぶ。
  func pickBase(_ name: String) {
    pickedBase = name
    selectedBaseRole = baseChoices.first { $0.name == name }?.role
  }

  /// ベースを選ぶ画面の行タップ＝決定。
  func confirmBasePick(at index: Int) {
    guard let picker = basePicker, picker.items.indices.contains(index) else { return }
    picker.selected = index
    confirmBasePick()
  }

  /// 入力欄の ↵（IME 変換確定では発火しない `onSubmit`）。画面ごとの決定へ振り分ける。
  func submit() {
    switch mode {
    case .list: activate()
    case .basePicker: confirmBasePick()
    case .clean, .refresh: break
    }
  }

  /// 今の入力への有効性の答えがまだ無い（作成行の有無が確定していない）。
  var isAwaitingBranchNameAnswer: Bool {
    !query.isEmpty && newBranchRules != nil && branchNameAnswer?.name != query
  }
}
