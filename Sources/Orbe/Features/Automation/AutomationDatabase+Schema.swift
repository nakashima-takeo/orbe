import Foundation

extension AutomationDatabase {
  /// 版 2 の表。ID はどれも使い回さない（AUTOINCREMENT）。外部キーは接続ごとに `PRAGMA foreign_keys = ON` で守る。
  static let schema = """
    CREATE TABLE part_defs (
      id   INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL CHECK (kind IN ('action', 'composite')),
      UNIQUE (id, kind)
    );
    CREATE TABLE action_defs (
      id     INTEGER PRIMARY KEY,
      kind   TEXT NOT NULL DEFAULT 'action' CHECK (kind = 'action'),
      action TEXT NOT NULL CHECK (json_type(action) = 'object'),
      FOREIGN KEY (id, kind) REFERENCES part_defs (id, kind)
    );
    CREATE TABLE composite_defs (
      id   INTEGER PRIMARY KEY,
      kind TEXT NOT NULL DEFAULT 'composite' CHECK (kind = 'composite'),
      FOREIGN KEY (id, kind) REFERENCES part_defs (id, kind)
    );
    CREATE TABLE composite_slots (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      composite_def_id INTEGER NOT NULL REFERENCES composite_defs (id),
      child_def_id     INTEGER NOT NULL REFERENCES part_defs (id),
      CHECK (child_def_id < composite_def_id),
      UNIQUE (composite_def_id, id)
    );
    CREATE INDEX composite_slots_child ON composite_slots (child_def_id);
    CREATE TABLE composite_edges (
      composite_def_id INTEGER NOT NULL,
      from_slot_id     INTEGER NOT NULL,
      to_slot_id       INTEGER NOT NULL,
      PRIMARY KEY (to_slot_id, from_slot_id),
      CHECK (from_slot_id <> to_slot_id),
      FOREIGN KEY (composite_def_id, from_slot_id) REFERENCES composite_slots (composite_def_id, id),
      FOREIGN KEY (composite_def_id, to_slot_id)   REFERENCES composite_slots (composite_def_id, id)
    ) WITHOUT ROWID;
    CREATE INDEX composite_edges_def ON composite_edges (composite_def_id);
    CREATE TABLE automations (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      name       TEXT    NOT NULL,
      notify     TEXT CHECK (notify IN ('menuBar', 'notificationCenter')),
      paused_at  INTEGER,
      version    INTEGER NOT NULL CHECK (version >= 1),
      created_at INTEGER NOT NULL
    );
    CREATE TABLE parts (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      automation_id   INTEGER REFERENCES automations (id) ON DELETE SET NULL,
      position        INTEGER NOT NULL,
      key             TEXT    NOT NULL,
      name            TEXT    NOT NULL,
      trigger         TEXT    NOT NULL,
      max_items       INTEGER CHECK (max_items > 0),
      def_id          INTEGER NOT NULL REFERENCES part_defs (id),
      added_at        INTEGER NOT NULL,
      removed_at      INTEGER,
      breach_run_id   INTEGER REFERENCES runs (id),
      last_item_seq   INTEGER NOT NULL DEFAULT 0 CHECK (last_item_seq >= 0),
      last_event_seq  INTEGER NOT NULL DEFAULT 0 CHECK (last_event_seq >= 0),
      pending_drops   TEXT    NOT NULL DEFAULT '{}' CHECK (json_type(pending_drops) = 'object'),
      CHECK (removed_at IS NOT NULL OR automation_id IS NOT NULL),
      CHECK (removed_at IS NULL OR (breach_run_id IS NULL AND pending_drops = '{}')),
      UNIQUE (automation_id, id)
    );
    CREATE UNIQUE INDEX parts_key      ON parts (automation_id, key)      WHERE removed_at IS NULL;
    CREATE UNIQUE INDEX parts_position ON parts (automation_id, position) WHERE removed_at IS NULL;
    CREATE INDEX parts_def ON parts (def_id);
    CREATE TABLE part_edges (
      automation_id INTEGER NOT NULL REFERENCES automations (id) ON DELETE CASCADE,
      from_part_id  INTEGER NOT NULL,
      to_part_id    INTEGER NOT NULL,
      position      INTEGER NOT NULL,
      take          TEXT    NOT NULL CHECK (take IN ('new', 'all')),
      max_age_hours INTEGER CHECK (max_age_hours > 0),
      read_item_seq  INTEGER NOT NULL DEFAULT 0 CHECK (read_item_seq >= 0),
      read_event_seq INTEGER NOT NULL DEFAULT 0 CHECK (read_event_seq >= 0),
      PRIMARY KEY (to_part_id, from_part_id),
      UNIQUE (to_part_id, position),
      CHECK (from_part_id <> to_part_id),
      FOREIGN KEY (automation_id, from_part_id) REFERENCES parts (automation_id, id),
      FOREIGN KEY (automation_id, to_part_id)   REFERENCES parts (automation_id, id)
    ) WITHOUT ROWID;
    CREATE INDEX part_edges_from ON part_edges (from_part_id);
    CREATE INDEX part_edges_automation ON part_edges (automation_id);
    CREATE TABLE items (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      part_id         INTEGER NOT NULL REFERENCES parts (id),
      seq             INTEGER NOT NULL CHECK (seq > 0),
      written_id      TEXT    NOT NULL,
      source_item_id  INTEGER REFERENCES items (id),
      source_event_id INTEGER REFERENCES events (id),
      valid_from      INTEGER NOT NULL,
      valid_to        INTEGER,
      CHECK (source_item_id IS NULL OR source_event_id IS NULL),
      CHECK (valid_to IS NULL OR valid_to >= valid_from),
      UNIQUE (part_id, seq)
    );
    CREATE UNIQUE INDEX items_live ON items (part_id, written_id) WHERE valid_to IS NULL;
    CREATE INDEX items_part ON items (part_id, valid_to);
    CREATE INDEX items_source_item ON items (source_item_id);
    CREATE INDEX items_source_event ON items (source_event_id);
    CREATE TABLE item_versions (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      item_id    INTEGER NOT NULL REFERENCES items (id),
      body       TEXT    NOT NULL CHECK (json_type(body) = 'object'),
      valid_from INTEGER NOT NULL,
      link       TEXT GENERATED ALWAYS AS (json_extract(body, '$.link')) VIRTUAL,
      UNIQUE (item_id, valid_from),
      UNIQUE (id, link)
    );
    CREATE TABLE events (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      part_id         INTEGER NOT NULL REFERENCES parts (id),
      seq             INTEGER NOT NULL CHECK (seq > 0),
      created_at      INTEGER NOT NULL,
      written_id      TEXT    NOT NULL,
      body            TEXT    NOT NULL CHECK (json_type(body) = 'object'),
      link            TEXT GENERATED ALWAYS AS (json_extract(body, '$.link')) VIRTUAL,
      source_item_id  INTEGER REFERENCES items (id),
      source_event_id INTEGER REFERENCES events (id),
      CHECK (source_item_id IS NULL OR source_event_id IS NULL),
      UNIQUE (part_id, seq),
      UNIQUE (id, link)
    );
    CREATE INDEX events_seen ON events (part_id, written_id, created_at);
    CREATE INDEX events_part ON events (part_id, created_at);
    CREATE INDEX events_source_item ON events (source_item_id);
    CREATE INDEX events_source_event ON events (source_event_id);
    CREATE TABLE runs (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      part_id    INTEGER NOT NULL REFERENCES parts (id),
      def_id     INTEGER NOT NULL REFERENCES action_defs (id),
      started_at INTEGER NOT NULL,
      ended_at   INTEGER NOT NULL,
      trigger    TEXT    NOT NULL CHECK (trigger IN ('schedule', 'now', 'arrival')),
      failure    TEXT,
      record     TEXT    NOT NULL
    );
    CREATE INDEX runs_part ON runs (part_id, id);
    CREATE INDEX runs_def ON runs (def_id);
    CREATE TABLE run_item_inputs (
      run_id     INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
      version_id INTEGER NOT NULL REFERENCES item_versions (id),
      how        TEXT    NOT NULL
        CHECK (how IN ('taken', 'expired', 'overflow', 'replaced', 'unsourced', 'proposed', 'sameLink')),
      PRIMARY KEY (run_id, version_id)
    ) WITHOUT ROWID;
    CREATE INDEX run_item_inputs_version ON run_item_inputs (version_id);
    CREATE TABLE run_event_inputs (
      run_id   INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
      event_id INTEGER NOT NULL REFERENCES events (id),
      how      TEXT    NOT NULL
        CHECK (how IN ('taken', 'expired', 'overflow', 'replaced', 'unsourced', 'proposed', 'sameLink')),
      PRIMARY KEY (run_id, event_id)
    ) WITHOUT ROWID;
    CREATE INDEX run_event_inputs_event ON run_event_inputs (event_id);
    CREATE TABLE proposals (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id            INTEGER NOT NULL REFERENCES runs (id),
      origin_version_id INTEGER,
      origin_event_id   INTEGER,
      link              TEXT    NOT NULL,
      title             TEXT    NOT NULL,
      due               TEXT,
      workspace         TEXT,
      reason            TEXT,
      CHECK ((origin_version_id IS NULL) <> (origin_event_id IS NULL)),
      FOREIGN KEY (origin_version_id, link) REFERENCES item_versions (id, link),
      FOREIGN KEY (origin_event_id, link)   REFERENCES events (id, link),
      UNIQUE (id, link)
    );
    CREATE INDEX proposals_run ON proposals (run_id);
    CREATE INDEX proposals_origin_version ON proposals (origin_version_id, link);
    CREATE INDEX proposals_origin_event ON proposals (origin_event_id, link);
    CREATE TABLE held_proposals (
      proposal_id INTEGER PRIMARY KEY,
      link        TEXT    NOT NULL UNIQUE,
      resolved_at INTEGER,
      FOREIGN KEY (proposal_id, link) REFERENCES proposals (id, link)
    );
    CREATE TABLE settlements (
      proposal_id INTEGER PRIMARY KEY REFERENCES proposals (id),
      decided_at  INTEGER NOT NULL,
      outcome     TEXT    NOT NULL CHECK (outcome IN ('accepted', 'dismissed')),
      task_id     INTEGER,
      CHECK ((outcome = 'accepted') = (task_id IS NOT NULL))
    );
    """
}
