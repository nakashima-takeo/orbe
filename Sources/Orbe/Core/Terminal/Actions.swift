import AppKit
import GhosttyKit

/// `action_cb` の配線。libghostty はタイトル・描画要求・ベル・URL 等を
/// アクションとして host に通知する。戻り値はそのアクションを処理したか。
extension Ghostty {
  func handleAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s)
    -> Bool
  {
    switch action.tag {
    case GHOSTTY_ACTION_RENDER:
      let surf: ghostty_surface_t? = surface(of: target)
      guard let surf else { return false }
      drawSurface(surf)
      return true

    case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
      // ペインのタイトルを更新し、所属タブのラベルへ反映する。
      guard let surf = surface(of: target), let cstr = action.action.set_title.title else {
        return true
      }
      let title = String(cString: cstr)
      DispatchQueue.main.async { [weak self] in
        guard let v = self?.view(for: surf) else { return }
        v.paneTitle = title
        v.controller?.paneTitleChanged(v)
      }
      return true

    case GHOSTTY_ACTION_PWD:
      // OSC 7 の cwd を該当ペインに保持し、1 列 chrome の cwd 表示と永続保存へ流す。
      guard let surf = surface(of: target), let cstr = action.action.pwd.pwd else { return true }
      let pwd = String(cString: cstr)
      DispatchQueue.main.async { [weak self] in
        guard let v = self?.view(for: surf) else { return }
        v.currentPwd = pwd
        v.controller?.panePwdChanged()
      }
      return true

    case GHOSTTY_ACTION_RING_BELL:
      DispatchQueue.main.async { NSSound.beep() }
      return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      // 非 soft（キーバインド reload_config 等）はディスクからの再読込要求 → 全体へ差し替える。
      guard action.action.reload_config.soft else {
        reloadConfig()
        return true
      }
      // soft は条件状態（ライト/ダークでの theme 切替等）の変化で飛ぶ。
      // 現在の app config を対象へ再適用すると、surface が自分の条件状態を被せて再解決する。
      if let surf = surface(of: target) {
        ghostty_surface_update_config(surf, config)
      } else if let app {
        ghostty_app_update_config(app, config)
      }
      return true

    case GHOSTTY_ACTION_SEARCH_TOTAL, GHOSTTY_ACTION_SEARCH_SELECTED:
      return handleSearchCount(action, target: target)

    case GHOSTTY_ACTION_CELL_SIZE:
      return handleCellSize(action, target: target)

    case GHOSTTY_ACTION_SCROLLBAR:
      return handleScrollbar(action, target: target)

    case GHOSTTY_ACTION_OPEN_URL:
      return handleOpenURL(action)

    default:
      // 未対応アクションは未処理として返す
      return false
    }
  }

  /// SEARCH_TOTAL / SEARCH_SELECTED: スクロールバック検索の件数を該当ペインへ反映する。
  private func handleSearchCount(_ action: ghostty_action_s, target: ghostty_target_s) -> Bool {
    guard let surf = surface(of: target) else { return true }
    DispatchQueue.main.async { [weak self] in
      guard let v = self?.view(for: surf) else { return }
      if action.tag == GHOSTTY_ACTION_SEARCH_TOTAL {
        let raw = action.action.search_total.total
        v.updateSearchTotal(raw >= 0 ? Int(raw) : nil)
      } else {
        let raw = action.action.search_selected.selected
        v.updateSearchSelected(raw >= 0 ? Int(raw) : nil)
      }
    }
    return true
  }

  /// CELL_SIZE: セルのピクセル寸法。scrollbar の行↔ピクセル換算に使う（ラップ層が読む）。
  private func handleCellSize(_ action: ghostty_action_s, target: ghostty_target_s) -> Bool {
    guard let surf = surface(of: target) else { return true }
    let size = action.action.cell_size
    let cell = CGSize(width: Int(size.width), height: Int(size.height))
    DispatchQueue.main.async { [weak self] in self?.view(for: surf)?.updateCellSize(cell) }
    return true
  }

  /// SCROLLBAR: scrollback の総量・先頭可視行・可視行数。NSScrollView のつまみへ反映する。
  private func handleScrollbar(_ action: ghostty_action_s, target: ghostty_target_s) -> Bool {
    guard let surf = surface(of: target) else { return true }
    let sb = action.action.scrollbar
    let state = ScrollbarState(total: Int(sb.total), offset: Int(sb.offset), len: Int(sb.len))
    DispatchQueue.main.async { [weak self] in self?.view(for: surf)?.updateScrollbar(state) }
    return true
  }

  /// OPEN_URL: ターミナル内の URL/ファイルパスを macOS の作法で開く。
  /// これを処理しないと libghostty のフォールバック（`os/open.zig` の無限ループバグ）を踏む。
  /// C 側の `url` ポインタはコールバック中だけ有効なので、bytes を即コピーしてから main へ渡す。
  private func handleOpenURL(_ action: ghostty_action_s) -> Bool {
    let v = action.action.open_url
    let kind = OpenURL.Kind(v.kind)
    let raw: String
    if let ptr = v.url {
      raw = String(data: Data(bytes: ptr, count: Int(v.len)), encoding: .utf8) ?? ""
    } else {
      raw = ""
    }
    guard !raw.isEmpty else { return true }
    DispatchQueue.main.async { OpenURL.open(kind: kind, url: OpenURL.resolve(raw)) }
    return true
  }

  /// target が surface を指すなら取り出す（optional の取り違えを避けるため一旦 optional に束ねる）。
  private func surface(of target: ghostty_target_s) -> ghostty_surface_t? {
    guard target.tag == GHOSTTY_TARGET_SURFACE else { return nil }
    let s: ghostty_surface_t? = target.target.surface
    return s
  }

  private func drawSurface(_ surface: ghostty_surface_t) {
    if Thread.isMainThread {
      ghostty_surface_draw(surface)
    } else {
      DispatchQueue.main.async { ghostty_surface_draw(surface) }
    }
  }
}
