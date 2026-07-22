import AppKit
import GhosttyKit
import SwiftUI

/// 補完 popup の入口（表示/更新/破棄・候補取得・キー横取り・位置決め）。
/// popup 表示・accept・キー横取りは main で行う（libghostty surface API と AppKit は main 規律）。
/// 候補算出は `CompletionEngine`（専用 queue・JSContext）に委ね、結果を main へ hop して受ける。
extension SurfaceView {
  /// `.app` 同梱の zsh 補完スクリプト（`<bundle>/Contents/Resources/orbe-completion.zsh`）の
  /// 絶対パス。`swift run`（バンドル無し）では nil → env 未注入で widget が no-op。
  static var completionScriptPath: String? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let path = resources.appendingPathComponent("orbe-completion.zsh").path
    return FileManager.default.isReadableFile(atPath: path) ? path : nil
  }

  /// `completion_update`: engine で現在トークンの候補を算出し、1 件以上なら popup を出す/更新する。
  /// 非同期（engine は専用 queue）。連続入力は debounce で coalesce し、結果は stale ガードで
  /// 最新リクエストのみ採用する。IME 変換中（preedit）は誤誘導になるため抑止する。
  func completionUpdate(buffer: String, cursor: Int) {
    guard markedText.length == 0 else {
      completionEnd()
      return
    }
    // Enter 確定直後、buffer/cursor が確定時から不変の間は popup を再表示しない（再表示ループを断つ）。
    if let suppressed = completionSuppressed {
      if suppressed.buffer == buffer && suppressed.cursor == cursor {
        completionEnd()  // 閉じたまま維持
        return
      }
      completionSuppressed = nil  // buffer/cursor が動いた＝ユーザ編集。通常動作へ戻す
    }
    let cwd = currentPwd ?? initialCwd ?? NSHomeDirectory()
    completionRequestSeq &+= 1
    let seq = completionRequestSeq

    completionDebounce?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      CompletionEngine.shared.suggestions(buffer: buffer, cursor: cursor, cwd: cwd) { result in
        // main。発行後に新しい update が来ていれば破棄（高速タイプの古い候補を出さない）。
        guard seq == self.completionRequestSeq else { return }
        // この結果が最新リクエストの帰結＝popup が編集状態を映した、と記録する（accept の退避判定）。
        self.completionAppliedSeq = seq
        // engine 返却の全件をそのまま popup へ渡す（総数キャップ無し）。可視分は CompletionList が
        // 仮想描画（窓だけ実体化）で捌き、暴走は engine の generator 2s タイムアウトが抑える。
        let choices = result.choices
        guard !choices.isEmpty else {
          self.completionEnd()
          return
        }
        // オフセットは scalar 単位（zsh の cursor・engine の replaceLength と揃える。NFD パス対策）。
        let chars = Array(buffer.unicodeScalars)
        let cur = max(0, min(cursor, chars.count))
        let start = max(0, cur - result.replaceLength)
        // 一択かつ現在トークンが候補の表示名と完全一致なら、popup は無意味なので出さない。
        let tokenText = String(String.UnicodeScalarView(chars[start..<cur]))
        if Self.isRedundantSoleChoice(choices, tokenText: tokenText) {
          self.completionEnd()
          return
        }
        let controller: CompletionController
        if let existing = self.completion {
          controller = existing
        } else {
          controller = CompletionController(
            translucency: self.chromeTranslucency ?? ChromeTranslucency())
          self.addSubview(controller)
          self.completion = controller
        }
        controller.update(
          buffer: buffer, cursor: cursor, choices: choices, replaceStart: start, replaceEnd: cur)
        self.positionCompletion(controller)
      }
    }
    completionDebounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
  }

  /// `completion_accept`: 選択中候補を現在トークンへ適用した buffer/cursor を返す（main・同期）。
  /// advance=true（Tab）は素の候補に末尾空白を補い次トークンへ進める。advance=false（Enter）は
  /// 常に空白なしで確定し popup を閉じ、確定結果を completionSuppressed へ記録して再表示を抑える。
  /// popup 非表示 / 候補なし / seq 不一致（type 直後の in-flight）なら nil（widget はフォールバック）。
  func completionAccept(advance: Bool) -> (buffer: String, cursor: Int)? {
    // popup が最新の編集状態を映していない間（type 直後の debounce/engine in-flight）は、古い
    // controller.buffer から行を再構築すると直前の打鍵を握り潰すため適用せず native Tab へ退避する。
    guard completionAppliedSeq == completionRequestSeq else { return nil }
    guard let controller = completion, let choice = controller.current else { return nil }
    let appendSpace = advance ? (choice.insertValue == nil) : false
    let result = Self.applyChoice(
      buffer: controller.buffer, replaceStart: controller.replaceStart,
      replaceEnd: controller.replaceEnd,
      insert: Self.insertText(choice.insertValue ?? choice.value, advance: advance),
      appendSpace: appendSpace)
    completionEnd()
    if !advance {
      completionSuppressed = result  // Enter 確定は completionEnd の後に記録（掃除で消えないよう順序が要る）
    }
    // 「候補が使われた」瞬間を学習する（advance=Tab・確定=Enter 双方）。全候補が対象で、
    // 除外は record 側の相対ナビゲーション（`../` 等）のみ——呼び出し側は無条件で呼んでよい。
    CompletionLearning.shared.record(
      scopes: CompletionLearning.scopes(
        buffer: controller.buffer, replaceStart: controller.replaceStart),
      candidate: choice.value, type: choice.type, now: Date().timeIntervalSince1970)
    return result
  }

  /// Enter 確定（advance=false）では末尾のパス区切り `/` を1つ落とす（ディレクトリを `src` の形で確定）。
  /// Tab（advance=true）は次階層へ潜れるよう末尾 `/` を保つ。folder/特殊パス候補のみ末尾 `/` を帯びる。
  /// `raw.count > 1` ガードは単独 `/`（ルート）を空文字化しないための安全弁。
  static func insertText(_ raw: String, advance: Bool) -> String {
    guard !advance, raw.count > 1, raw.hasSuffix("/") else { return raw }
    return String(raw.dropLast())
  }

  /// 候補が唯一で、かつ accept しても buffer が変わらない（Enter の実挿入文字列＝現在トークン）とき true。
  /// このとき popup は無意味（すでに打ち切っている）なので出さない。比較は表示名ではなく `insertText` を
  /// 通した実挿入形で行う（folder は `src/`→`src`、素の名前はそのまま）——`insertValue` で展開される候補
  /// （オプションのパス接頭辞など）は no-op でないため閉じない。case-sensitive の `==` で判定する。
  static func isRedundantSoleChoice(_ choices: [CompletionChoice], tokenText: String) -> Bool {
    guard choices.count == 1 else { return false }
    let choice = choices[0]
    return insertText(choice.insertValue ?? choice.value, advance: false) == tokenText
  }

  /// 現在トークン（`replaceStart..<replaceEnd`・コードポイント〈scalar〉オフセット）を `insert` で
  /// 置換した buffer/cursor を組む純関数。境界はクランプし、カーソル以降の suffix は保つ。
  /// `appendSpace`（＝候補に insertValue が無い素の名前）のときだけ挿入直後に半角空白を1つ補い
  /// 次トークンへ進める（上流 inshellisense の `insertValue ?? name + " "` 忠実）。
  /// ただし後続文字が既に空白なら二重化を避けて足さない。
  /// オフセットは書記素でなく scalar 単位——zsh の $CURSOR・engine の replaceLength と揃え、
  /// NFD（結合文字を含むファイル名等）で置換位置・返却カーソルがずれないようにする。
  static func applyChoice(
    buffer: String, replaceStart: Int, replaceEnd: Int, insert: String, appendSpace: Bool
  ) -> (buffer: String, cursor: Int) {
    let chars = Array(buffer.unicodeScalars)
    let start = max(0, min(replaceStart, chars.count))
    let end = max(start, min(replaceEnd, chars.count))
    let head = String(String.UnicodeScalarView(chars[0..<start]))
    let tail = String(String.UnicodeScalarView(chars[end..<chars.count]))
    let needsSpace = appendSpace && tail.first != " "
    let suffix = needsSpace ? " " : ""
    return (
      head + insert + suffix + tail,
      start + insert.unicodeScalars.count + suffix.unicodeScalars.count
    )
  }

  /// popup を消す（`completion_end`・accept 後・Esc・preedit 開始）。保留中の debounce も無効化する。
  func completionEnd() {
    completionDebounce?.cancel()
    completionDebounce = nil
    completionRequestSeq &+= 1
    completionSuppressed = nil
    completion?.removeFromSuperview()
    completion = nil
    completionCard?.removeFromSuperview()
    completionCard = nil
  }

  /// popup 表示中のみ ↑/↓/⌘↑/⌘↓/Esc を横取りする（↑/↓=選択移動・⌘↑/⌘↓=先頭/末尾へジャンプ・Esc=dismiss）。
  /// 横取りしたら true。非表示時、および IME 変換中（preedit）は false を返し、surface（IME）へ素通しさせる
  /// ——変換中の矢印は候補移動、Esc は変換取消で IME のものなので奪わない。
  /// ⌘⇧↑↓（prevTool/nextTool）は shift 付きなので chrome へ譲る（`.shift` 等検出で false）。
  func completionHandleKey(_ event: NSEvent) -> Bool {
    guard completion != nil, markedText.length == 0 else { return false }
    let flags = event.modifierFlags
    let cmd = flags.contains(.command)
    switch event.keyCode {
    case 126:  // ↑
      if cmd {
        // ⌘⇧↑=prevTool 等の他修飾つきは chrome へ譲る（純粋な ⌘↑ だけジャンプ）。
        guard flags.isDisjoint(with: [.shift, .option, .control]) else { return false }
        completion?.jumpSelection(-1)
      } else {
        // 素の ↑ も shift/opt/ctrl つきも候補移動に畳む（surface へ流すとベル＋無意味な
        // エスケープ列になるだけなので握り取る）。chrome へ譲るのは ⌘⇧↑↓ のみ（上記 cmd 枝）。
        completion?.moveSelection(-1)
      }
      refreshCompletionCard()
      return true
    case 125:  // ↓
      if cmd {
        guard flags.isDisjoint(with: [.shift, .option, .control]) else { return false }
        completion?.jumpSelection(1)
      } else {
        completion?.moveSelection(1)
      }
      refreshCompletionCard()
      return true
    case 53: completionEnd(); return true  // Esc
    default: return false
    }
  }

  /// 選択移動後に side card を追従更新する（本体 frame は不変・card の内容/可視のみ更新）。
  private func refreshCompletionCard() {
    guard let controller = completion else { return }
    positionCompletionCard(controller)
  }

  /// popup をカーソル矩形（`ghostty_surface_ime_point`）の直下に置く。
  /// 下端で溢れるならカーソル上、右端で溢れるなら左へ寄せる。
  private func positionCompletion(_ controller: CompletionController) {
    guard let surface = surfacePtr else { return }
    var x = 0.0
    var y = 0.0
    var w = 0.0
    var h = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    let size = controller.preferredSize

    // ime_point は top-left 原点。NSView は bottom-left。カーソル矩形の下辺を view 座標へ。
    let cursorBottom = bounds.height - y - h
    var originY = cursorBottom - size.height
    if originY < 0 { originY = bounds.height - y }  // 画面下端で溢れる→カーソル上に出す
    originY = min(originY, bounds.height - size.height)  // カーソル上に反転しても view 上端で溢れさせない
    var originX = x
    if originX + size.width > bounds.width { originX = max(0, bounds.width - size.width) }
    controller.frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
    positionCompletionCard(controller)
  }

  /// side detail card を本体の脇に置く（選択候補に description があるときだけ）。
  /// 「右に gap を空けて出し、画面右端で溢れるなら本体の左へ」反転は利用可能空間を知る AppKit でしか正しく出せない。
  /// 縦は本体 top 揃え（選択行 Y への追従はしない＝YAGNI）・bounds 内にクランプ。なければ card を除去する。
  private func positionCompletionCard(_ controller: CompletionController) {
    let mainFrame = controller.frame
    guard let detail = controller.selectedDetail else {
      completionCard?.removeFromSuperview()
      completionCard = nil
      return
    }
    let rootView = CompletionSideCard(
      name: detail.name, kind: detail.kind, description: detail.description,
      translucency: chromeTranslucency ?? ChromeTranslucency())
    let card: NSHostingView<CompletionSideCard>
    if let existing = completionCard {
      card = existing
      card.rootView = rootView
    } else {
      card = NSHostingView(rootView: rootView)
      // SwiftUI 背景の alpha を端末面まで通す（透過時に素通し半透明が端末へ抜けるよう不透明ラスタを止める）。
      card.wantsLayer = true
      card.layer?.isOpaque = false
      addSubview(card)
      completionCard = card
    }
    card.layoutSubtreeIfNeeded()
    let size = card.fittingSize
    let gap = Theme.Space.step

    var originX = mainFrame.maxX + gap  // 既定は本体の右
    if originX + size.width > bounds.width {
      originX = mainFrame.minX - gap - size.width  // 右端で溢れる→本体の左へ反転
    }
    originX = max(0, min(originX, bounds.width - size.width))
    // bottom-left 原点。本体 top 揃え＝card の top（maxY）を本体 top（maxY）に合わせる。
    var originY = mainFrame.maxY - size.height
    originY = max(0, min(originY, bounds.height - size.height))
    card.frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
  }
}
