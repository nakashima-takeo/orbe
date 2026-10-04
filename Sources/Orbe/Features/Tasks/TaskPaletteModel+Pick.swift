import Foundation

/// 選ぶ状態。2 つの方向があり、それぞれ自分の一覧の状態を持つ——相手のタブの状態を借りると、抜けたときに元の
/// 絞り込みと選択が消える。
enum TaskPalettePick {
  /// GitHub の項目を結び付けるタスクを選ぶ（GitHub タブの L から。タスクのタブの行で選ぶ）。
  case task(for: TaskLink, list: TaskPaletteListState<TaskPaletteRowID>)
  /// タスクに結び付ける項目を選ぶ（詳細の「＋ 結び付ける」から。GitHub タブの行で選ぶ）。
  case item(for: Int, list: TaskPaletteListState<TaskPaletteGitHubRowID>)
}

/// 選ぶ状態に入る・決める・やめる。結び付けと付け替えは、ストアの 1 回の変異（`attach`）で行う。
extension TaskPaletteModel {
  /// L（GitHub タブの一覧・右の欄）。選んだ項目を結び付ける（結び付いていれば付け替える）タスクを、タスクの
  /// タブで選ぶ状態に入る。
  func linkSelectedGitHubItem() {
    guard pick == nil, let row = selectedGitHubRow else { return }
    leaveEditingForAction()
    area = .list
    pick = .task(for: TaskLink(item: row.id, kind: row.item.kind), list: .init())
    reconcile()
    focus()
  }

  /// 詳細の「＋ 結び付ける」の ↵・クリック。そのタスクに結び付ける項目を、GitHub タブで選ぶ状態に入る。
  func beginPickingItem() {
    guard pick == nil, let task = selectedTask else { return }
    leaveEditingForAction()
    area = .list
    pick = .item(for: task.id, list: .init())
    reconcile()
    focus()
  }

  /// 「＋ 結び付ける」のクリック。焦点をその行に置いてから選ぶ状態へ入る（やめたらその行へ戻る）。
  func tapAddLink() {
    guard selectedTask != nil else { return }
    leaveEditingForAction()
    area = .detail(.addLink)
    beginPickingItem()
  }

  /// 選ぶ状態の ↵。タスクを選ぶ状態はそのタスクへ結び付けて GitHub タブのその行へ、項目を選ぶ状態はその項目を
  /// 結び付けて詳細のその結び付きへ戻る。その項目を既に持つタスクでは何もしない。完了の見出しは開閉し、
  /// 「さらに」は区分を開く。
  func confirmPick() {
    switch pick {
    case .task(let link, _):
      switch selectedID {
      case .task(let id):
        guard pickedItemOwner?.id != id, attach(link, to: id) else { return }
        endPick(returningTo: .list)
        githubList.select(.item(link.item), in: gitHubSelectableIDs)
      case .doneHeader: toggleDoneExpanded()
      case .add, nil: break
      }
    case .item(let taskID, _):
      switch selectedGitHubID {
      case .item(let id):
        guard let row = selectedGitHubRow, row.task?.id != taskID,
          attach(TaskLink(item: id, kind: row.item.kind), to: taskID)
        else { return }
        endPick(returningTo: selectedTask?.id == taskID ? .detail(.link(id)) : .list)
      case .more(let kind): expand(kind)
      case nil: break
      }
    case nil: break
    }
  }

  /// esc。何も変えずに、入る前の場所へ戻る。
  func cancelPick() {
    switch pick {
    case .task: endPick(returningTo: .list)
    case .item(let taskID, _):
      endPick(returningTo: selectedTask?.id == taskID ? .detail(.addLink) : .list)
    case nil: break
    }
  }

  /// 選んでいる項目を持つタスク（タスクを選ぶ状態で、付け替えかを言うため）。
  var pickedItemOwner: TaskItem? {
    guard case .task(let link, _) = pick else { return nil }
    return store.tasks.first { $0.links.contains { $0.item == link.item } }
  }

  /// 開いた workspace のリポジトリの open 一覧にある項目の値（絞り込みに依らない）。
  func openItem(_ id: GitHubItemID) -> GitHubOpenItem? {
    guard id.repo == gitHubRepo, let repository = openLists.repositories[id.repo] else {
      return nil
    }
    let items = (repository.issues.items ?? []) + (repository.pullRequests.items ?? [])
    return items.first { $0.number == id.number }
  }

  /// 対象のタスクか項目が消えたら（agent の削除・一覧から消えた）、選ぶ状態を終えて戻る。付け直し
  /// （`reconcile`）の最初に呼ぶ。
  func endStalePick() {
    switch pick {
    case .task(let link, _) where openItem(link.item) == nil:
      pick = nil
      area = .list
    case .item(let taskID, _) where !store.tasks.contains(where: { $0.id == taskID }):
      pick = nil
      area = .list
    default: break
    }
  }

  private func endPick(returningTo area: TaskPaletteArea) {
    pick = nil
    self.area = area
    reconcile()
    focus()
  }

  /// 1 回の変異で結び付ける。ストアが受け付けなければ理由を出して false。
  private func attach(_ link: TaskLink, to id: Int) -> Bool {
    leaveEditingForAction()
    do throws(TaskStoreError) {
      try store.attach(link, to: id)
      return true
    } catch .invalid {
      error = .link
    } catch {
    }
    reconcile()
    return false
  }
}
