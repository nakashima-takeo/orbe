/// ブラウザ DB のスキーマ（版 1）。循環 FK の無い DAG 構造と CHECK / 複合 FK で不変条件を強制する。
extension BrowserDatabase {
  static let schema = """
    CREATE TABLE profiles (
      id          TEXT    PRIMARY KEY,
      name        TEXT    NOT NULL CHECK (length(trim(name)) > 0),
      color       TEXT    NOT NULL CHECK (color IN ('green', 'blue', 'amber', 'purple', 'pink', 'teal')),
      mcp_allowed INTEGER NOT NULL CHECK (mcp_allowed IN (0, 1)),
      position    INTEGER NOT NULL CHECK (position >= 0),
      created_at  INTEGER NOT NULL
    ) WITHOUT ROWID;

    CREATE TABLE spaces (
      id           TEXT    PRIMARY KEY,
      kind         TEXT    NOT NULL CHECK (kind IN ('free', 'local')),
      workspace_id TEXT,
      name         TEXT    NOT NULL,
      icon         TEXT    NOT NULL CHECK (icon IN ('person', 'briefcase', 'search', 'globe', 'code', 'star', 'local')),
      profile_id   TEXT    NOT NULL REFERENCES profiles (id),
      position     INTEGER NOT NULL CHECK (position >= 0),
      created_at   INTEGER NOT NULL,
      CHECK ((kind = 'local') = (workspace_id IS NOT NULL)),
      CHECK (kind = 'local' OR length(trim(name)) > 0),
      CHECK ((kind = 'local') = (icon = 'local')),
      UNIQUE (id, kind)
    ) WITHOUT ROWID;
    CREATE UNIQUE INDEX spaces_workspace ON spaces (workspace_id) WHERE workspace_id IS NOT NULL;
    CREATE INDEX spaces_profile ON spaces (profile_id);
    CREATE INDEX spaces_free_order ON spaces (position, created_at) WHERE kind = 'free';

    CREATE TABLE tabs (
      id             TEXT    PRIMARY KEY,
      space_id       TEXT    NOT NULL,
      space_kind     TEXT    NOT NULL CHECK (space_kind IN ('free', 'local')),
      section        TEXT    NOT NULL CHECK (section IN ('favorite', 'pinned', 'today')),
      position       INTEGER NOT NULL CHECK (position >= 0),
      url            TEXT,
      title          TEXT    NOT NULL DEFAULT '',
      created_at     INTEGER NOT NULL,
      last_active_at INTEGER NOT NULL,
      CHECK (NOT (space_kind = 'local' AND section = 'favorite')),
      FOREIGN KEY (space_id, space_kind) REFERENCES spaces (id, kind) ON DELETE CASCADE,
      UNIQUE (space_id, id)
    ) WITHOUT ROWID;
    CREATE INDEX tabs_space_section ON tabs (space_id, section, position, created_at);
    CREATE INDEX tabs_today_expiry ON tabs (last_active_at) WHERE section = 'today';

    CREATE TABLE space_active_tabs (
      space_id TEXT PRIMARY KEY REFERENCES spaces (id) ON DELETE CASCADE,
      tab_id   TEXT NOT NULL,
      FOREIGN KEY (space_id, tab_id) REFERENCES tabs (space_id, id) ON DELETE CASCADE
    ) WITHOUT ROWID;

    CREATE TABLE closed_tabs (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      url               TEXT    NOT NULL CHECK (length(trim(url)) > 0),
      title             TEXT    NOT NULL DEFAULT '',
      original_space_id TEXT    NOT NULL REFERENCES spaces (id) ON DELETE CASCADE,
      closed_at         INTEGER NOT NULL
    );
    CREATE INDEX closed_tabs_space ON closed_tabs (original_space_id);

    CREATE TABLE browser_meta (
      id                   INTEGER PRIMARY KEY CHECK (id = 1),
      active_space_kind    TEXT    NOT NULL CHECK (active_space_kind IN ('free', 'local')),
      active_free_space_id TEXT,
      sheet_ratio_bps      INTEGER NOT NULL DEFAULT 5200 CHECK (sheet_ratio_bps BETWEEN 2800 AND 8400),
      CHECK ((active_space_kind = 'free') = (active_free_space_id IS NOT NULL)),
      FOREIGN KEY (active_free_space_id, active_space_kind) REFERENCES spaces (id, kind)
    ) WITHOUT ROWID;

    CREATE TABLE pending_store_removals (
      store_id  TEXT    PRIMARY KEY,
      queued_at INTEGER NOT NULL
    ) WITHOUT ROWID;
    """
}
