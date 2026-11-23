import AppKit
import SwiftUI

/// 差分のファイルの見出し（デザインの見本の `.fh`）の SwiftUI ルート。本体が diff の間、本体の上端に出る。左から、（PR だけ）
/// 確認済みのチェック・パス（フォルダは頭から省く）・（未保存なら）未保存の丸・状態の字・区切り線・（PR だけ）「確認済みにする」
/// と札 v・「ファイルを開く」。出すものは、pane が写した `subject` と、一覧の持ち主（ソース管理パネルの状態・PR ごとの状態）を
/// 読んで、`DiffFileHeader` が導く。器の中の別 root なので環境は明示注入する。
struct DiffFileHeaderRoot: View {
  /// pane が写す、本体の diff の値。
  struct Subject: Equatable {
    let key: EditorDiff.Key
    /// diff が新しい側に文書を使っている。
    let usesDocument: Bool
    /// 新しい側の文書が未保存。
    let isDirty: Bool
  }

  let localization: LocalizationStore
  var subject: Subject?
  /// Changes の状態の字と「ファイルを開く」を押せるかの持ち主（根が替われば pane が root ごと作り直す）。
  let scm: ScmPanel
  var openFile: () -> Void = {}
  var toggleViewed: () -> Void = {}

  var body: some View {
    Group {
      if let subject {
        DiffFileHeaderBar(
          header: subject.header(scm: scm), isPullRequest: subject.key.kind.isPullRequest,
          openFile: openFile, toggleViewed: toggleViewed)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.localization, localization)
  }
}

extension DiffFileHeaderRoot.Subject {
  /// この diff のファイルの見出しの値。一覧の持ち主（Changes はソース管理パネルの状態 `scm`、PR は diff が持つ PR ごとの
  /// 状態）から読む。見出しと、上のバーの今のファイルのボタンが、同じ値を使う。
  @MainActor func header(scm: ScmPanel) -> DiffFileHeader {
    DiffFileHeader(key, facts: facts(scm: scm), isDirty: isDirty)
  }

  @MainActor private func facts(scm: ScmPanel) -> DiffFileHeader.Facts {
    switch key.kind {
    case .workingTree, .staged:
      return .changes(scm.file(of: key), usesDocument: usesDocument)
    case .pullRequest(let state):
      return .pullRequest(
        state.changedFiles.change(of: key.path), isViewed: state.isViewed(key.path))
    }
  }
}

/// 見出しの帯（高さ 32）と、その下の影。
private struct DiffFileHeaderBar: View {
  let header: DiffFileHeader
  let isPullRequest: Bool
  let openFile: () -> Void
  let toggleViewed: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    VStack(spacing: 0) {
      row
        .frame(height: Theme.Layout.editorDiffHeader - Theme.Stroke.hairline)
        .background(Color.theme.surfaceInk.opacity(Theme.Opacity.editorDiffHeaderGround))
      Rectangle().fill(EditorInk(scheme).hairline(Theme.Opacity.editorDiffHeaderLine))
        .frame(height: Theme.Stroke.hairline)
      DiffFileHeaderShadow()
    }
  }

  private var row: some View {
    HStack(spacing: Theme.Layout.editorDiffHeaderGap) {
      if let viewed = header.viewed {
        EditorViewedCheck(isOn: viewed, action: toggleViewed)
      }
      path
      if header.isDirty {
        Circle().fill(Color.theme.textPrimary)
          .frame(width: Theme.Layout.editorDiffHeaderDot, height: Theme.Layout.editorDiffHeaderDot)
          .padding(.leading, -2)
          .help(l10n.string(.editorUnsaved))
          .accessibilityLabel(l10n.string(.editorUnsaved))
      }
      if let badge = header.badge {
        Text(badge.label)
          .font(Font.theme.editorDiffHeaderBadge)
          .foregroundStyle(badge.color)
          .frame(width: Theme.Layout.editorDiffHeaderBadge)
      }
      Rectangle().fill(EditorInk(scheme).hairline(Theme.Opacity.editorDiffHeaderDivider))
        .frame(width: Theme.Stroke.hairline, height: Theme.Layout.editorDiffHeaderDivider)
        .padding(.horizontal, Theme.Layout.editorDiffHeaderDividerInset)
      if let viewed = header.viewed {
        EditorTextButton(
          title: l10n.string(viewed ? .editorPrUnmarkViewed : .editorPrMarkViewed),
          key: .text("v"), action: toggleViewed)
      }
      EditorTextButton(
        title: l10n.string(.editorScmOpenFile), glyph: EditorGlyphs.openFile,
        isEnabled: header.canOpenFile, action: openFile)
      Spacer(minLength: 0)
    }
    .padding(
      .leading,
      isPullRequest
        ? Theme.Layout.editorDiffHeaderLeadingPullRequest : Theme.Layout.editorDiffHeaderLeading
    )
    .padding(.trailing, Theme.Layout.editorDiffHeaderTrailing)
  }

  /// パス（mono 12）。フォルダは text.muted で、収まらなければ頭から省く。ファイル名は semibold・text.primary で省かない。
  private var path: some View {
    HStack(spacing: 0) {
      Text(header.folder)
        .foregroundStyle(Color.theme.textMuted)
        .truncationMode(.head)
      Text(header.name)
        .font(Font.theme.editorDiffHeaderName)
        .foregroundStyle(Color.theme.textPrimary)
        .fixedSize()
    }
    .font(Font.theme.editorDiffHeaderPath)
    .lineLimit(1)
  }
}

/// 見出しの下の影（デザインの見本の `0 6px 14px -8px rgba(0,0,0,.55)`）。見本の影は、帯より 8 ずつ内側の矩形を 6 下げて 14
/// ぼかしたもの。そのうち帯の下にはみ出す裾（帯の下端から 14）を、縦の階調で描く。階調の濃さは、ぼかしの濃さの落ち方に沿わせる。
/// 下の面の上端に掛かるだけで、押下は受けない（host が素通しする）。
private struct DiffFileHeaderShadow: View {
  /// 帯の下端からの距離（裾の高さに対する割合）と、その位置の影の濃さ。
  private static let stops: [(location: CGFloat, alpha: Double)] = [
    (0, 0.213), (3 / 14, 0.131), (6 / 14, 0.070), (9 / 14, 0.032), (12 / 14, 0.0125), (1, 0),
  ]

  var body: some View {
    LinearGradient(
      stops: Self.stops.map { .init(color: Color.black.opacity($0.alpha), location: $0.location) },
      startPoint: .top, endPoint: .bottom
    )
    .frame(height: Theme.Layout.editorDiffHeaderShadow)
    .allowsHitTesting(false)
  }
}

/// 確認済みのチェック（14 角。PR のパネルの行のチェックと同じ姿——付いていれば地 accent にレ点、付いていなければ沈んだ地に枠）。
/// 押すと切り替える。押してもフォーカスを求めない。
struct EditorViewedCheck: View {
  let isOn: Bool
  let action: () -> Void
  @Environment(\.localization) private var l10n
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let size = Theme.Layout.editorPrCheckbox
    ZStack {
      RoundedRectangle(cornerRadius: 3)
        .fill(isOn ? Color.theme.accentPrimary : EditorInk(scheme).sunk(0.25))
      if isOn {
        EditorGlyphView(
          glyph: EditorGlyphs.checkboxCheck, size: 10, color: Color.theme.accentCheckStroke)
      } else {
        RoundedRectangle(cornerRadius: 2.5)
          .strokeBorder(EditorInk(scheme).hairline(0.22), lineWidth: 1)
      }
    }
    .frame(width: size, height: size)
    .contentShape(Rectangle().inset(by: -3))
    .onTapGesture(perform: action)
    .help(label)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
  }

  private var label: String { l10n.string(isOn ? .editorPrUnmarkViewed : .editorPrMarkViewed) }
}

/// 見出しの host。押してもフォーカスを取らない（上のバーと同じ）。帯の下の影の範囲は押下を素通しして、下の面へ届ける。
final class DiffFileHeaderHost: NSHostingView<DiffFileHeaderRoot> {
  override var acceptsFirstResponder: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard local.y < Theme.Layout.editorDiffHeader else { return nil }
    return super.hitTest(point)
  }
}

extension EditorDiff.Kind {
  var isPullRequest: Bool {
    if case .pullRequest = self { return true }
    return false
  }
}

#if DEBUG
  enum DiffFileHeaderFixtures {
    /// 見出しを、面の地（bgBase）の上に並べる——Changes の状態の字 M・A・U・C（未保存の丸あり・なし）、押せない
    /// 「ファイルを開く」、狭い幅で頭から省いたパス、PR の確認済みの前と後。gallery が dark / light を撮る。
    @MainActor static func gallery() -> some View {
      VStack(alignment: .leading, spacing: 8) {
        bar(changes("Sources/Orbe/Features/Editor/ChangesStream.swift", .modified), dirty: true)
        bar(changes("Sources/Orbe/Features/Editor/EditorOverlay.swift", .added))
        bar(changes("docs/spec/editor/faces.md", .untracked))
        bar(changes("Sources/Orbe/App/AppShell.swift", .conflicted))
        bar(changes("Sources/Orbe/Terminal/Retired.swift", .modified, opens: false))
        bar(
          changes(
            "Sources/Orbe/Features/Editor/PullRequest/Comments/PrCommentLayer.swift", .modified)
        )
        .frame(width: 420)
        bar(
          pullRequest("Sources/Orbe/Terminal/RenderBatcher.swift", .added, viewed: false), pr: true)
        bar(
          pullRequest("Sources/Orbe/Terminal/RenderBatcher.swift", .added, viewed: true), pr: true)
        bar(pullRequest("Sources/Orbe/Terminal/Old.swift", .deleted, viewed: false), pr: true)
      }
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
      .environment(\.localization, LocalizationStore(language: .ja))
    }

    private static func changes(
      _ path: String, _ badge: GitStatus.Badge, opens: Bool = true
    ) -> (EditorDiff.Key, DiffFileHeader.Facts) {
      let file = ScmChanges.File(
        row: GitStatus.Row(path: path, originalPath: nil), badge: badge, opensAsFile: opens,
        discardMovesToTrash: false)
      return (
        EditorDiff.Key(root: "/r", path: path, kind: .workingTree),
        .changes(file, usesDocument: opens)
      )
    }

    private static func pullRequest(
      _ path: String, _ change: GitHubPullRequestContent.Change, viewed: Bool
    ) -> (EditorDiff.Key, DiffFileHeader.Facts) {
      (
        EditorDiff.Key(root: "/r", path: path, kind: .workingTree),
        .pullRequest(change, isViewed: viewed)
      )
    }

    @MainActor private static func bar(
      _ subject: (EditorDiff.Key, DiffFileHeader.Facts), dirty: Bool = false, pr: Bool = false
    ) -> some View {
      DiffFileHeaderBar(
        header: DiffFileHeader(subject.0, facts: subject.1, isDirty: dirty), isPullRequest: pr,
        openFile: {}, toggleViewed: {}
      )
      .frame(height: Theme.Layout.editorDiffHeader + Theme.Layout.editorDiffHeaderShadow)
    }
  }

  #Preview("DiffFileHeader") {
    DiffFileHeaderFixtures.gallery().frame(width: 820, height: 520)
  }
#endif
