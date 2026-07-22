import SwiftUI

/// ファイル状態バッジ。**文字(M/A/D/U)が意味の本体・色は補強**（§3 二重符号化 / §5.4）。
/// 角丸 sm・type.caption/bold・文字色＝状態色・背景＝同色 12%。18×18。
struct FileBadge: View {
  enum Kind {
    case modified, added, deleted, conflict

    var letter: String {
      switch self {
      case .modified: return "M"
      case .added: return "A"
      case .deleted: return "D"
      case .conflict: return "U"
      }
    }

    var color: Color {
      switch self {
      case .modified: return Color.theme.stateDone  // M = 緑（done）
      case .added: return Color.theme.diffAdded  // A = 緑
      case .deleted: return Color.theme.diffRemoved  // D = 赤
      case .conflict: return Color.theme.conflict  // U = 黄（conflict）
      }
    }
  }

  let kind: Kind

  var body: some View {
    Text(kind.letter)
      .font(Font.theme.caption.weight(.bold))
      .foregroundStyle(kind.color)
      .frame(width: 18, height: 18)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.sm)
          .fill(kind.color.opacity(0.12))
      )
  }
}

#Preview("FileBadge") {
  HStack(spacing: Theme.Space.bar) {
    FileBadge(kind: .modified)
    FileBadge(kind: .added)
    FileBadge(kind: .deleted)
    FileBadge(kind: .conflict)
  }
  .padding(Theme.Space.phrase)
  .background(Color.theme.bgBase)
}
