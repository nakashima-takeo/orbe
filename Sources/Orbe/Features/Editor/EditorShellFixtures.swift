#if DEBUG
  import AppKit
  import OrbeEditorCore
  import SwiftUI

  /// 骨込みのエディター面の gallery fixture。渡された置き場に実在のソース断片（このリポジトリのファイル）を
  /// 写して git リポジトリにし、M / A / U を 1 つずつ作り、文書を 3 つ開く（1 つは未保存、1 つは仮の文書）。展示データは作らない。
  /// status は git の子プロセス後に、色とハンクは文書の裏の仕事の後に届くので、撮る側は `warmUp()` の後 `isReady`
  /// を待つ。プロジェクト検索はこのリポジトリを実際に探す（`search` の後 `isSearchDone` を待つ）。
  enum EditorShellFixtures {
    /// 写すファイル（リポジトリ相対）。
    private static let copied = [
      "README.md", "Package.swift",
      "Sources/Orbe/Features/Editor/EditorSession.swift",
      "Sources/Orbe/Features/Editor/FileChip.swift",
      "Sources/Orbe/Features/Editor/FileTree.swift",
      "docs/spec/editor/faces.md", "docs/spec/editor/code.md", "docs/design/tokens.json",
    ]

    @MainActor final class Scene {
      private let tab: TerminalTab
      /// fixture のリポジトリ（置き場の下。消すのは置き場の持ち主）。
      let directory: URL
      var group: TabGroup { tab.group }
      var pane: EditorPaneView { group.view.editor }
      private var warmWindow: NSWindow?

      init(tab: TerminalTab, directory: URL) {
        self.tab = tab
        self.directory = directory
      }

      /// 面を窓から外す。
      func cleanup() {
        warmWindow = nil
        pane.removeFromSuperview()
      }

      /// 面を窓に付けてツリーに根のサービスを握らせる（status の取り直しが始まる）。撮った後は面が窓から
      /// 外れるので、操作を窓の中で起こしたい flow は操作の前にもう一度呼ぶ（寸法は撮る絵と同じに）。
      func warmUp(size: NSSize = NSSize(width: 1100, height: 640)) {
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
          backing: .buffered, defer: false)
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        warmWindow = window
      }

      /// git バッジが揃い、文書の裏の仕事（色・ハンク）が追いついた。
      var isReady: Bool {
        pane.tree.status?.badge(of: "README.md") == .modified
          && pane.tree.status?.badge(of: "docs/spec/editor/shell.md") == .added
          && group.editor.documents.allSatisfy { $0.waitUntilCaughtUp(timeout: 0) }
      }

      /// 開いているファイルの一覧の姿のために文書を足す——shell.md（A）と notes.txt（U。打って未保存）を開き、未保存の
      /// README（M）を外で書き換えて「ディスクが変わった」にし、仮の文書 tokens.json → FileTree.swift の順に使う。一覧は
      /// FileTree・tokens.json・notes.txt・shell.md・README の順になる。撮る側は `isOpenFilesReady` を待つ。
      func openMoreFiles() throws {
        let session = group.editor
        try session.open(directory.appendingPathComponent("docs/spec/editor/shell.md"), as: .pinned)
        let notes = try session.open(directory.appendingPathComponent("notes.txt"), as: .pinned)
        notes.surface.responder.perform(Selector(("insertText:")), with: "- ")
        try "# outside\n".write(
          to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for name in ["tokens.json", "FileTree.swift"] {
          if let document = session.documents.first(where: { $0.url.lastPathComponent == name }) {
            session.activate(document.url)
          }
        }
      }

      /// 足した文書の印と状態の字が揃った。
      var isOpenFilesReady: Bool {
        let session = group.editor
        let badges = session.documents.map { session.badge(of: $0) }
        return session.documents.count == 5
          && session.documents.contains { $0.isDiskChanged }
          && badges.contains(.added) && badges.contains(.untracked) && badges.contains(.modified)
      }

      /// 検索パネルを出し、問いで実際に検索する（開いている文書は保存前の中身、ほかは git grep）。
      func search(_ query: SearchQuery) {
        pane.filesPanel = .search
        pane.projectSearch.restore(query)
        pane.projectSearch.search()
      }

      /// 検索が終わった（エラーで始まらなかったときも）。
      var isSearchDone: Bool { !pane.projectSearch.isSearching }

      /// 撮る view（pane をそのまま載せる）。
      var view: some View { ShellPane(pane: pane) }
    }

    /// 骨込みの面。gallery が dark / light・広い幅・狭い幅（サイドバーが切り詰まる）を撮る。リポジトリは `place` の下に
    /// 作る。git が失敗すれば投げる（→ `FixtureGit`）。
    @MainActor static func scene(queriesRoot: URL, in place: URL) throws -> Scene {
      let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let dir = place.appendingPathComponent("orbe-editor-shell-\(UUID().uuidString)")
      for relative in copied {
        let dest = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
          at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent(relative), to: dest)
      }
      let git = FixtureGit(directory: dir)
      try git(["init", "-q", "-b", "main"])
      try git(["config", "user.email", "gallery@orbe.dev"])
      try git(["config", "user.name", "gallery"])
      try git(["add", "-A"])
      try git(["commit", "-qm", "gallery"])
      // M: README を書き換える / A: shell.md を足して add / U: notes.txt を未追跡で置く。
      let readme = dir.appendingPathComponent("README.md")
      try (try String(contentsOf: readme, encoding: .utf8) + "\n<!-- gallery -->\n")
        .write(to: readme, atomically: true, encoding: .utf8)
      try "# 面の骨\n".write(
        to: dir.appendingPathComponent("docs/spec/editor/shell.md"), atomically: true,
        encoding: .utf8)
      try git(["add", "docs/spec/editor/shell.md"])
      try "todo\n".write(
        to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

      let group = TabGroup(
        key: GitWorktreeRoot.root(of: dir.path),
        editorSurfaces: EditorSurfaces(queriesRoot: queriesRoot, language: { .ja }))
      let tab = TerminalTab(cwd: dir.path, group: group)
      group.view.add(terminal: tab.terminal)
      group.view.show(terminal: tab.terminal)
      group.editor.selectScreen(.files)
      let readmeDocument = try group.editor.open(readme, as: .pinned)
      readmeDocument.surface.responder.perform(Selector(("insertText:")), with: "# ")
      _ = try group.editor.open(dir.appendingPathComponent("docs/design/tokens.json"), as: .preview)
      _ = try group.editor.open(
        dir.appendingPathComponent("Sources/Orbe/Features/Editor/FileTree.swift"), as: .pinned)
      return Scene(tab: tab, directory: dir)
    }

    private struct ShellPane: NSViewRepresentable {
      let pane: EditorPaneView

      func makeNSView(context: Context) -> EditorPaneView { pane }

      func updateNSView(_ view: EditorPaneView, context: Context) {}
    }
  }
  /// 上のバーの部品と、3 つの画面の姿の並び（見本の Main・PullRequest・Files の部品を、バーの行と共通の部品で組んだもの）。
  /// gallery が部品の姿と幅ごとの姿を、flow が幅を狭めていく並びを撮る。
  extension EditorShellFixtures {
    /// 部品の姿——中ほどの札（素の姿・地つきの変種・押せない姿・表示だけの札）・26 角のボタン（ふつう・押された姿）・右端の
    /// ボタン（ふつう・開いている・押せない・添え書きつき・固定の添えつき）。
    @MainActor static func barParts() -> some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          branchChip
          syncChip(isEnabled: true)
          syncChip(isEnabled: false)
          pullRequestChip
          EditorBarChip(
            help: "ブランチ",
            content: {
              EditorGlyphView(
                glyph: EditorGlyphs.branch, size: 12, color: Color.theme.textPrimary)
              EditorReadableName(
                "feat/editor-overlay", prefixLength: Theme.Layout.editorBarChipReadablePrefix,
                truncation: .tail
              ) { Text($0) }
            }
          )
          .frame(width: 120)
        }
        HStack(spacing: 8) {
          EditorBarIconButton(glyph: EditorGlyphs.sidebarToggle, help: "ツリーを開く") {}
          EditorBarIconButton(
            glyph: EditorGlyphs.sidebarToggle, isPressed: true, help: "ツリーを閉じる"
          ) {}
          EditorBarIconButton(glyph: EditorGlyphs.refresh, help: "再読込") {}
          EditorBarIconButton(glyph: EditorGlyphs.openFile, help: "GitHub で開く") {}
        }
        HStack(spacing: 8) {
          commitButton(isOpen: false)
          commitButton(isOpen: true)
          EditorBarActionButton(
            title: "コミット", isEnabled: false, help: "ステージ済みの変更がありません", action: {})
        }
        HStack(spacing: 8) {
          reviewButton(isOpen: false)
          reviewButton(isOpen: true)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
      .environment(\.localization, LocalizationStore(language: .ja))
    }

    /// 画面 `screen` の姿の上のバーを、幅 `widths` ごとに上から並べる（左の列を開いた姿）。
    @MainActor static func bars(_ screen: EditorScreen, widths: [CGFloat]) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(widths, id: \.self) { width in
          bar(screen).frame(width: width)
        }
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
      .environment(\.localization, LocalizationStore(language: .ja))
    }

    /// Files の画面の上のバーの、ファイル内検索の欄の姿を上から並べる（幅 1100。左の列を開いた姿）——一致あり・仮の文書つき・
    /// 一致なし・フォーカスなし・検索語が空。
    @MainActor static func filesFindBars() -> some View {
      VStack(alignment: .leading, spacing: 8) {
        bar(.files, field: findModel("isEditorOpen", selected: 2, total: 3))
        bar(
          .files, file: previewFile, field: findModel("isEditorOpen", selected: nil, total: 3))
        bar(.files, field: findModel("isEditorOpne", selected: nil, total: 0))
        bar(.files, field: findModel("isEditorOpen", selected: 2, total: 3, focused: false))
        bar(.files, field: findModel("", selected: nil, total: nil))
      }
      .frame(width: 1100)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
      .environment(\.localization, LocalizationStore(language: .ja))
    }

    /// ファイル内検索の欄の状態（件数は面と同じく、位置が無ければ `?/全体`）。
    @MainActor private static func findModel(
      _ needle: String, selected: Int?, total: Int?, focused: Bool = true
    ) -> SearchBarModel {
      let model = SearchBarModel()
      model.showsUnknownPosition = true
      model.needle = needle
      model.focused = focused
      model.updateCount(selected: selected, total: total)
      return model
    }

    /// 画面 `screen` の姿の上のバー。Changes はブランチ名の札・同期・コミット、PR は PR の札・再読込・GitHub で開く・
    /// レビュー、Files は今のファイルのボタン（仮の文書なら「プレビュー」の札と「開いたままにする」つき）・ファイル内検索の欄
    /// （`field` を渡さなければ、一致ありでフォーカスのある姿）。
    @MainActor static func bar(
      _ screen: EditorScreen, file: EditorShellModel.CurrentFile = currentFile,
      field: SearchBarModel? = nil
    ) -> some View {
      EditorBarRow {
        EditorSidebarToggle(isOpen: true) {}
        EditorScreenSwitch(
          selection: screen, changesCount: 6, pullRequestNumber: 214, select: { _ in }
        )
        .fixedSize()
        switch screen {
        case .changes:
          HStack(spacing: EditorBarRoot.spacing) {
            EditorBarSeparator()
            branchChip
          }
          .editorBarPart(drops: .chip, grows: .chipWide)
          syncChip(isEnabled: true)
        case .pullRequest:
          HStack(spacing: EditorBarRoot.spacing) {
            EditorBarSeparator()
            pullRequestChip
          }
          .editorBarPart(drops: .chip, grows: .chipWide)
          EditorBarIconButton(glyph: EditorGlyphs.refresh, help: "再読込") {}
          EditorBarIconButton(glyph: EditorGlyphs.openFile, help: "GitHub で開く") {}
        case .files:
          HStack(spacing: EditorBarRoot.spacing) {
            EditorBarSeparator()
            EditorItemButton(
              isOpen: false, help: "開いているファイルの一覧", action: {},
              label: { EditorCurrentFileLabel(file: file) })
          }
          .editorBarPart(grows: .itemWide)
          if file.isPreview {
            EditorTag(text: "プレビュー")
            EditorTextButton(title: "開いたままにする", style: .filled) {}
          }
          EditorBarFindField(model: field ?? findModel("isEditorOpen", selected: 2, total: 3))
        }
        EditorPeekHint(isPeeking: false).editorBarPart(.trailing, drops: .hint)
        switch screen {
        case .changes: commitButton(isOpen: false)
        case .pullRequest: reviewButton(isOpen: false)
        case .files: EmptyView()
        }
      }
    }

    private static let currentFile = EditorShellModel.CurrentFile(
      chip: FileChip.resolve(URL(fileURLWithPath: "/repo/App/Layout/AppShell.swift")),
      directory: "App/Layout/", name: "AppShell.swift", isPreview: false, mark: .unsaved,
      showsKeepOpenKey: false)

    private static let previewFile = EditorShellModel.CurrentFile(
      chip: FileChip.resolve(URL(fileURLWithPath: "/repo/App/Layout/AppShell.swift")),
      directory: "App/Layout/", name: "AppShell.swift", isPreview: true, mark: .none,
      showsKeepOpenKey: false)

    /// ブランチ名の札（広い姿は名前の全体、狭い姿は名前を省略）。
    @MainActor private static var branchChip: some View {
      EditorBarChip(
        help: "ブランチを選ぶ", action: {},
        content: {
          EditorGlyphView(glyph: EditorGlyphs.branch, size: 12, color: Color.theme.textPrimary)
          EditorReadableName(
            "feat/editor-overlay", prefixLength: Theme.Layout.editorBarChipReadablePrefix,
            truncation: .tail
          ) { Text($0) }
          EditorGlyphView(
            glyph: EditorGlyphs.chevronDown, size: 12, color: Color.theme.textMuted)
        })
    }

    @MainActor private static func syncChip(isEnabled: Bool) -> some View {
      EditorBarChip(
        style: .filled, isEnabled: isEnabled, help: "同期 ↑2 ↓1", action: {},
        content: {
          Text("同期")
          Text("↑2 ↓1")
            .font(Font.theme.editorBarCount)
            .foregroundStyle(Color.theme.textSecondary)
        }
      )
      .fixedSize()
    }

    /// PR の札（広い姿は「→ ベース」つき、次に名前の全体、狭い姿は名前を省略）。
    @MainActor private static var pullRequestChip: some View {
      EditorBarChip(
        help: "プルリクエストを選ぶ", action: {},
        content: {
          Text("#214").foregroundStyle(Color.theme.textMuted)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Layout.editorBarChipGap) {
              Text("feat/editor-overlay")
              EditorGlyphView(
                glyph: EditorGlyphs.arrowRight, size: 12, color: Color.theme.textMuted)
              Text("main").foregroundStyle(Color.theme.textMuted)
            }
            .fixedSize()
            EditorReadableName(
              "feat/editor-overlay", prefixLength: Theme.Layout.editorBarChipReadablePrefix,
              truncation: .tail
            ) { Text($0) }
          }
          EditorGlyphView(
            glyph: EditorGlyphs.chevronDown, size: 12, color: Color.theme.textMuted)
        })
    }

    @MainActor private static func commitButton(isOpen: Bool) -> some View {
      EditorBarActionButton(
        title: "コミット", isOpen: isOpen, help: "コミット", action: {},
        detail: {
          HStack(spacing: 6) {
            Text("ステージ済み")
            Text("+125 −3").font(Font.theme.editorBarCount)
          }
          .font(Font.theme.editorItemListHint)
          .foregroundStyle(Color.theme.textSecondary)
        })
    }

    @MainActor private static func reviewButton(isOpen: Bool) -> some View {
      EditorBarActionButton(
        title: "レビュー", isOpen: isOpen, help: "レビュー、未送信のコメント 1", action: {},
        badge: {
          HStack(spacing: 3) {
            EditorGlyphView(
              glyph: EditorGlyphs.comment, size: 12, color: Color.theme.stateWaiting)
            Text("1").font(Font.theme.editorBarCount).foregroundStyle(Color.theme.stateWaiting)
          }
        })
    }
  }
#endif
