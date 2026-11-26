import SwiftUI

/// 実行中の札（上のバーの右下の置き場に出す。0.3 秒を越えて走る操作があるときだけ）。札の地に、上端の流れる線・操作の名前・
/// git の進捗の行（リモートと話す段だけ。mono 11・末尾省略）・右端の「止める」（走っている段を止め、2 段の操作なら次の段を
/// 起こさない）を並べる。進捗の行が無ければ、幅は中身なり。在れば、進捗の列は行の字数に依らず幅 420 を取る——進捗の行は
/// 届くたびに字数が変わるので、右寄せの置き場で札の左端が揺れないように。置き場が狭ければ、進捗の列から縮む。
struct ScmRunningCard: View {
  let kind: SourceControl.Kind
  let progress: String?
  let stop: () -> Void
  @Environment(\.localization) private var l10n

  var body: some View {
    EditorCardGround {
      HStack(spacing: Theme.Layout.editorRunningGap) {
        Text(l10n.string(kind.runningLabel))
          .font(Font.theme.editorDockCard)
          .foregroundStyle(Color.theme.textPrimary)
          .fixedSize()
        if let progress {
          Text(progress)
            .font(Font.theme.editorRunningProgress)
            .foregroundStyle(Color.theme.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            // 置き場が許す限り幅 420 を取る（字の幅に縮めない）。
            .frame(maxWidth: Theme.Layout.editorRunningProgressWidth, alignment: .leading)
        }
        EditorTextButton(title: l10n.string(.editorScmStop), style: .filled, action: stop)
      }
      .padding(.leading, Theme.Layout.editorRunningPadLeading)
      .padding(.trailing, Theme.Layout.editorRunningPadTrailing)
    }
    .overlay(alignment: .top) {
      // 角丸に掛からないよう、角丸の半径の分だけ内側で流す。
      EditorProgressLine()
        .padding(.horizontal, Theme.Layout.editorCardRadius)
        .allowsHitTesting(false)
    }
  }
}

extension SourceControl.Kind {
  /// 実行中の札の操作名。
  var runningLabel: L10nKey {
    switch self {
    case .stage: .editorScmRunningStage
    case .unstage: .editorScmRunningUnstage
    case .discard: .editorScmRunningDiscard
    case .commit: .editorScmRunningCommit
    case .amend: .editorScmRunningAmend
    case .undo: .editorScmRunningUndo
    case .pull: .editorScmRunningPull
    case .push: .editorScmRunningPush
    case .fetch: .editorScmRunningFetch
    case .sync: .editorScmRunningSync
    case .publish: .editorScmRunningPublish
    case .commitAndPush: .editorScmRunningCommitAndPush
    }
  }
}
