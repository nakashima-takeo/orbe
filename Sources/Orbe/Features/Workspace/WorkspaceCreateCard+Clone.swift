import SwiftUI

// MARK: - カードの clone 関連 chrome（ソース切替タブ・inline エラー・clone 案内）

/// ソース切替タブ・clone 失敗の inline エラー・clone のフッター案内。いずれも `model` のみを読み focus に触れない
/// ため、focus（@FocusState private）を握る `WorkspaceCreateCard` 本体（別ファイル）から拡張として分離できる。
extension WorkspaceCreateCard {
  /// ヘッダ直後のソース切替（既存フォルダ / git clone）。選択中は accent 系・非選択は muted。
  /// 見本 `SrcTab` はフルカプセル（radius 999）・ピル間 gap 6。
  var sourceTabs: some View {
    HStack(spacing: Theme.Space.note) {
      sourceTab(.folder, l10n.string(.wsSourceFolder))
      sourceTab(.clone, "git clone")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.top, Theme.Space.bar)
  }

  func sourceTab(_ source: WorkspaceCreateModel.Source, _ label: String) -> some View {
    let active = model.source == source
    return Button {
      guard model.source != source else { return }
      model.setSource(source)  // 切替先ソースの主入力欄への focus 移動は setSource が focusToken を進めて担う
    } label: {
      Text(label)
        .font(Font.theme.chrome)
        .foregroundStyle(active ? Color.theme.accentPrimary : Color.theme.textMuted)
        .padding(.horizontal, Theme.Space.beat)
        .padding(.vertical, Theme.Space.note)
        .background(
          Capsule().fill(active ? Color.theme.accentPrimary.opacity(0.15) : Color.clear)
        )
        .overlay(
          Capsule()
            .strokeBorder(
              active ? Color.theme.accentPrimary.opacity(0.35) : Color.theme.inputBorder,
              lineWidth: Theme.Stroke.hairline)
        )
    }
    .buttonStyle(.plain)
    .focusable(false)  // ピルは focus 対象にしない（クリックで入力欄から focus を奪わない・常に欄が focus）
    .disabled(model.isCloning)  // clone 待機中はソース切替も止める
  }

  /// clone 失敗時の git stderr を inline 表示（フッター直上・DispatchCard と同じ danger）。
  @ViewBuilder var cloneErrorBanner: some View {
    if let error = model.cloneError {
      Text(error)
        .font(Font.theme.meta)
        .foregroundStyle(Color.theme.danger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.span)
        .padding(.bottom, Theme.Space.beat)
    }
  }

  /// clone: canCreate 時は「作成すると {name}(done) ({clone先/名前})(idle) が clone されます」。
  /// それ以外（URL 空・親不在）は muted の入力促し。
  @ViewBuilder var cloneGuide: some View {
    if model.canCreate {
      (Text(l10n.string(.wsCreateGuideLead)).foregroundColor(Color.theme.textMuted)
        + Text(model.curName).foregroundColor(Color.theme.stateDone)
        + Text(" (\(model.cloneFinalDest))").foregroundColor(Color.theme.stateIdle)
        + Text(l10n.string(.wsCloneGuideTail)).foregroundColor(Color.theme.textMuted))
        .font(Font.theme.workspaceName)
    } else {
      Text(l10n.string(.wsCloneEmptyHint))
        .font(Font.theme.workspaceName)
        .foregroundStyle(Color.theme.textMuted)
    }
  }
}

// MARK: - clone 本文（URL・clone 先＋/name）

/// git clone ソースの本文。URL 欄（空欄＋muted placeholder）／clone 先欄（親ディレクトリ＋末尾に `/{名前}`）／
/// 注記。clone 実行中は indeterminate スピナーの待機表示へ差し替える。キーは自前の `@FocusState` に集約する
/// （カードの folder 用 focus とは独立。clone へ切替＝この subview が mount され URL 欄へ focus）。
struct WorkspaceCreateCloneForm: View {
  @Bindable var model: WorkspaceCreateModel
  @Environment(\.localization) private var l10n
  private enum Field { case url, dir, name }
  @FocusState private var focus: Field?

  var body: some View {
    Group {
      if model.isCloning {
        waiting
      } else {
        form
      }
    }
    // 代入は次 runloop tick へ回す——clone へ切替＝この subview が新規 mount された直後で field editor が
    // 未準備／SrcTab クリックが focus をさらった状態。同期代入だと URL 欄に focus が乗らず esc も死ぬため、
    // 次 tick で確実に当てる（表示中は常に入力欄 focus の不変）。
    .onChange(of: model.focusToken, initial: true) {
      DispatchQueue.main.async { focus = .url }
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: Theme.Space.bar) {
      urlSection
      destSection
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  private var urlSection: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      workspaceFieldLabel(l10n.string(.wsFieldRepoURL))
      urlField
    }
  }

  private var urlField: some View {
    TextField("", text: urlBinding)
      .textFieldStyle(.plain)
      .font(Font.theme.code)
      .foregroundStyle(Color.theme.textPrimary)
      .tint(Color.theme.accentPrimary)
      .focused($focus, equals: .url)
      // 純正 placeholder は色を握れず IME 変換中も消えないため、共通モディファイアで muted の例を描きつつ
      // marked text がある間は抑制する。String 引数はリテラルでなく markdown 解釈されない＝リンク化しない。
      .imePlaceholder(
        "https://github.com/you/repo.git", showWhenEmpty: model.cloneURL.isEmpty,
        focused: focus == .url, font: Font.theme.code, color: Color.theme.textMuted
      )
      .modifier(FieldChrome(focused: focus == .url))
      .onKeyPress(.tab) {
        focus = .dir
        return .handled
      }
      .onKeyPress(.escape) {
        dismiss()
        return .handled
      }
      .onSubmit { model.submit() }
  }

  /// clone 先（親ディレクトリ）＋末尾に `/{名前}`（`/`＝idle・名前＝done で編集可）。B 案: 名前は URL 追従／
  /// 手入力でリンク解除・再リンク（folder と同じ 1 経路を共用）。注記「フォルダは作成時に作られます」。
  private var destSection: some View {
    VStack(alignment: .leading, spacing: Theme.Space.note) {
      HStack(spacing: Theme.Space.step) {
        workspaceFieldLabel(l10n.string(.wsFieldCloneDest))
        Spacer(minLength: 0)
        WorkspaceNameLinkStatus(model: model, followLabel: l10n.string(.wsFollowURL))
      }
      destField
      Text(l10n.string(.wsCloneDestNote))
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.textMuted)
    }
  }

  /// 見本どおり: 箱（`FieldChrome`）は clone 先の親だけを囲い、末尾 `/{名前}` は箱の外・右隣に並べる
  /// （gap 8・`/`＝idle・名前＝done で編集可）。箱と `/名前` は縦中央で揃える。
  private var destField: some View {
    HStack(spacing: Theme.Space.step) {
      TextField("", text: dirBinding)
        .textFieldStyle(.plain)
        .font(Font.theme.code)
        .foregroundStyle(Color.theme.textPrimary)
        .tint(Color.theme.accentPrimary)
        .focused($focus, equals: .dir)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onKeyPress(.tab) {
          focus = .name
          return .handled
        }
        .onKeyPress(.escape) {
          dismiss()
          return .handled
        }
        .onSubmit { model.submit() }
        .modifier(FieldChrome(focused: focus == .dir))
      HStack(spacing: 0) {
        Text("/")
          .font(Font.theme.code)
          .foregroundStyle(Color.theme.stateIdle)
        // folder と同じ curName/setName（1 経路共用）。
        TextField("", text: nameBinding)
          .textFieldStyle(.plain)
          .font(Font.theme.code)
          .foregroundStyle(Color.theme.stateDone)
          .tint(Color.theme.accentPrimary)
          .focused($focus, equals: .name)
          .fixedSize()  // 名前部は内容幅にハグ（末尾に /name を並べる）
          .onKeyPress(.tab) {
            focus = .url
            return .handled
          }
          .onKeyPress(.escape) {
            dismiss()
            return .handled
          }
          .onSubmit { model.submit() }
      }
    }
  }

  /// clone 実行中の待機表示（indeterminate スピナー・キャンセル不可）。Onboarding と同じスピナー流儀。
  private var waiting: some View {
    HStack(spacing: Theme.Space.beat) {
      ProgressView().controlSize(.small)
      Text(l10n.string(.wsCloning))
        .font(Font.theme.label)
        .foregroundStyle(Color.theme.textMuted)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Space.span)
    .padding(.vertical, Theme.Space.bar)
  }

  /// esc の畳み込み。clone 実行中は無視（待機表示中は入力欄が無いため実質到達しないが防御的に）。
  private func dismiss() {
    guard !model.isCloning else { return }
    model.onDismiss()
  }

  private var urlBinding: Binding<String> {
    Binding(get: { model.cloneURL }, set: { model.setCloneURL($0) })
  }

  private var dirBinding: Binding<String> {
    Binding(get: { model.cloneDir }, set: { model.setCloneDir($0) })
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { model.curName },
      set: { edited in
        guard edited != model.curName else { return }
        model.setName(edited)
      })
  }
}

// MARK: - 名前の追従/リンク解除の状態表示（folder=パス / clone=URL で共用）

/// 追従中＝done(green)「⌁ {follow}に追従中」、解除中＝waiting(黄)・下線の単一ボタン（押下で再リンク）。
struct WorkspaceNameLinkStatus: View {
  @Bindable var model: WorkspaceCreateModel
  let followLabel: String
  @Environment(\.localization) private var l10n

  var body: some View {
    if model.linked {
      Text(l10n.format(.wsLinkedFollowing, followLabel))
        .font(Font.theme.chrome)
        .foregroundStyle(Color.theme.stateDone)
    } else {
      // 解除中は下線付きの単一ボタン（押下で再リンク）。見本どおり全体が 1 つのアクション。
      Button {
        model.relink()
      } label: {
        Text(l10n.string(.wsUnlinkRelink))
          .font(Font.theme.chrome)
          .foregroundStyle(Color.theme.stateWaiting)
          .underline()
      }
      .buttonStyle(.plain)
      .focusable(false)  // 再リンク押下で名前欄から focus を奪わない（常に入力欄が focus の不変を保つ）
    }
  }
}

#if DEBUG
  #Preview("WorkspaceCreate — clone") {
    let model = WorkspaceCreateModel(path: "~/github")
    model.setSource(.clone)
    model.setCloneURL("https://github.com/you/repo.git")
    return ZStack {
      BackgroundGlow()
      WorkspaceCreateOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }

  #Preview("WorkspaceCreate — clone waiting") {
    // 親=home（実在）で canCreate→待機へ。
    let model = WorkspaceCreateModel(path: "~")
    model.setSource(.clone)
    model.setCloneURL("https://github.com/you/repo.git")
    model.onClone = { _, _, _ in }  // 完了を呼ばない＝running のまま
    model.submit()
    return ZStack {
      BackgroundGlow()
      WorkspaceCreateOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }

  #Preview("WorkspaceCreate — clone failed") {
    let model = WorkspaceCreateModel(path: "~")
    model.setSource(.clone)
    model.setCloneURL("https://github.com/you/repo.git")
    model.onClone = { _, _, done in
      done("fatal: repository 'https://github.com/you/repo.git' not found")
    }
    model.submit()
    return ZStack {
      BackgroundGlow()
      WorkspaceCreateOverlay(model: model)
    }
    .frame(width: 720, height: 560)
  }
#endif
