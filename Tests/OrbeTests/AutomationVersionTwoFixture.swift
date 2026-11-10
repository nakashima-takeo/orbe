/// 版 2 の自動化の DB の凍結フィクスチャ（`AutomationStoreTests+Frozen`）。この形で凍結しておく（足した列や欄に合わせて書き換えない）。
enum AutomationVersionTwoFixture {}

extension AutomationVersionTwoFixture {
  /// 版 2 の DDL のコピー。
  static let schema = """
    CREATE TABLE node_defs (
      id   INTEGER PRIMARY KEY AUTOINCREMENT,
      kind TEXT NOT NULL CHECK (kind IN ('action', 'composite')),
      UNIQUE (id, kind)
    );
    CREATE TABLE action_defs (
      id     INTEGER PRIMARY KEY,
      kind   TEXT NOT NULL DEFAULT 'action' CHECK (kind = 'action'),
      action TEXT NOT NULL CHECK (json_type(action) = 'object'),
      FOREIGN KEY (id, kind) REFERENCES node_defs (id, kind)
    );
    CREATE TABLE composite_defs (
      id   INTEGER PRIMARY KEY,
      kind TEXT NOT NULL DEFAULT 'composite' CHECK (kind = 'composite'),
      FOREIGN KEY (id, kind) REFERENCES node_defs (id, kind)
    );
    CREATE TABLE composite_slots (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      composite_def_id INTEGER NOT NULL REFERENCES composite_defs (id),
      child_def_id     INTEGER NOT NULL REFERENCES node_defs (id),
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
      workspace  TEXT,
      paused_at  INTEGER,
      version    INTEGER NOT NULL CHECK (version >= 1),
      created_at INTEGER NOT NULL
    );
    CREATE TABLE nodes (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      automation_id   INTEGER REFERENCES automations (id) ON DELETE SET NULL,
      position        INTEGER NOT NULL,
      key             TEXT    NOT NULL,
      name            TEXT    NOT NULL,
      trigger         TEXT    NOT NULL,
      max_items       INTEGER CHECK (max_items > 0),
      retention_days  INTEGER CHECK (retention_days > 0),
      def_id          INTEGER NOT NULL REFERENCES node_defs (id),
      added_at        INTEGER NOT NULL,
      paused_at       INTEGER,
      removed_at      INTEGER,
      breach_run_id   INTEGER REFERENCES runs (id),
      last_item_seq   INTEGER NOT NULL DEFAULT 0 CHECK (last_item_seq >= 0),
      last_event_seq  INTEGER NOT NULL DEFAULT 0 CHECK (last_event_seq >= 0),
      carried         TEXT    NOT NULL DEFAULT '{}' CHECK (json_type(carried) = 'object'),
      CHECK (removed_at IS NOT NULL OR automation_id IS NOT NULL),
      CHECK (removed_at IS NULL OR (breach_run_id IS NULL AND carried = '{}')),
      UNIQUE (automation_id, id)
    );
    CREATE UNIQUE INDEX nodes_key      ON nodes (automation_id, key)      WHERE removed_at IS NULL;
    CREATE UNIQUE INDEX nodes_position ON nodes (automation_id, position) WHERE removed_at IS NULL;
    CREATE INDEX nodes_def ON nodes (def_id);
    CREATE TABLE node_edges (
      automation_id INTEGER NOT NULL REFERENCES automations (id) ON DELETE CASCADE,
      from_node_id  INTEGER NOT NULL,
      to_node_id    INTEGER NOT NULL,
      position      INTEGER NOT NULL,
      take          TEXT    NOT NULL CHECK (take IN ('new', 'all')),
      max_age_hours INTEGER CHECK (max_age_hours > 0),
      read_item_seq  INTEGER NOT NULL DEFAULT 0 CHECK (read_item_seq >= 0),
      read_event_seq INTEGER NOT NULL DEFAULT 0 CHECK (read_event_seq >= 0),
      PRIMARY KEY (to_node_id, from_node_id),
      UNIQUE (to_node_id, position),
      CHECK (from_node_id <> to_node_id),
      FOREIGN KEY (automation_id, from_node_id) REFERENCES nodes (automation_id, id),
      FOREIGN KEY (automation_id, to_node_id)   REFERENCES nodes (automation_id, id)
    ) WITHOUT ROWID;
    CREATE INDEX node_edges_from ON node_edges (from_node_id);
    CREATE INDEX node_edges_automation ON node_edges (automation_id);
    CREATE TABLE items (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      node_id         INTEGER NOT NULL REFERENCES nodes (id),
      seq             INTEGER NOT NULL CHECK (seq > 0),
      written_id      TEXT    NOT NULL,
      source_item_id  INTEGER REFERENCES items (id),
      source_event_id INTEGER REFERENCES events (id),
      valid_from      INTEGER NOT NULL,
      valid_to        INTEGER,
      valid_to_seq    INTEGER,
      CHECK (source_item_id IS NULL OR source_event_id IS NULL),
      CHECK (valid_to IS NULL OR valid_to >= valid_from),
      CHECK ((valid_to IS NULL) = (valid_to_seq IS NULL)),
      CHECK (valid_to_seq IS NULL OR valid_to_seq > seq),
      UNIQUE (node_id, seq)
    );
    CREATE UNIQUE INDEX items_live ON items (node_id, written_id) WHERE valid_to IS NULL;
    CREATE INDEX items_node ON items (node_id, valid_to);
    CREATE INDEX items_source_item ON items (source_item_id);
    CREATE INDEX items_source_event ON items (source_event_id);
    CREATE TABLE item_versions (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      item_id    INTEGER NOT NULL REFERENCES items (id),
      seq        INTEGER NOT NULL CHECK (seq > 0),
      body       TEXT    NOT NULL CHECK (json_type(body) = 'object'),
      valid_from INTEGER NOT NULL,
      link       TEXT GENERATED ALWAYS AS (json_extract(body, '$.link')) VIRTUAL,
      UNIQUE (item_id, valid_from),
      UNIQUE (id, link)
    );
    CREATE TABLE events (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      node_id         INTEGER NOT NULL REFERENCES nodes (id),
      seq             INTEGER NOT NULL CHECK (seq > 0),
      created_at      INTEGER NOT NULL,
      written_id      TEXT    NOT NULL,
      body            TEXT    NOT NULL CHECK (json_type(body) = 'object'),
      link            TEXT GENERATED ALWAYS AS (json_extract(body, '$.link')) VIRTUAL,
      source_item_id  INTEGER REFERENCES items (id),
      source_event_id INTEGER REFERENCES events (id),
      CHECK (source_item_id IS NULL OR source_event_id IS NULL),
      UNIQUE (node_id, seq),
      UNIQUE (id, link)
    );
    CREATE INDEX events_seen ON events (node_id, written_id, created_at);
    CREATE INDEX events_node ON events (node_id, created_at);
    CREATE INDEX events_source_item ON events (source_item_id);
    CREATE INDEX events_source_event ON events (source_event_id);
    CREATE TABLE runs (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      node_id    INTEGER NOT NULL REFERENCES nodes (id),
      def_id     INTEGER NOT NULL REFERENCES action_defs (id),
      started_at INTEGER NOT NULL,
      ended_at   INTEGER NOT NULL,
      trigger    TEXT    NOT NULL CHECK (trigger IN ('schedule', 'now', 'arrival')),
      failure    TEXT,
      record     TEXT    NOT NULL,
      UNIQUE (id, node_id)
    );
    CREATE INDEX runs_node ON runs (node_id, id);
    CREATE INDEX runs_def ON runs (def_id);
    CREATE TABLE run_item_inputs (
      run_id     INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
      version_id INTEGER NOT NULL REFERENCES item_versions (id),
      how        TEXT    NOT NULL
        CHECK (how IN ('taken', 'expired', 'overflow', 'replaced', 'closed')),
      PRIMARY KEY (run_id, version_id)
    ) WITHOUT ROWID;
    CREATE INDEX run_item_inputs_version ON run_item_inputs (version_id);
    CREATE TABLE run_event_inputs (
      run_id   INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
      event_id INTEGER NOT NULL REFERENCES events (id),
      how      TEXT    NOT NULL
        CHECK (how IN ('taken', 'expired', 'overflow', 'replaced', 'closed')),
      PRIMARY KEY (run_id, event_id)
    ) WITHOUT ROWID;
    CREATE INDEX run_event_inputs_event ON run_event_inputs (event_id);
    CREATE TABLE proposals (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id     INTEGER NOT NULL,
      node_id    INTEGER NOT NULL,
      version_id INTEGER,
      event_id   INTEGER,
      link       TEXT    NOT NULL,
      title      TEXT    NOT NULL,
      due        TEXT,
      workspace  TEXT,
      reason     TEXT,
      CHECK ((version_id IS NULL) <> (event_id IS NULL)),
      FOREIGN KEY (run_id, node_id)  REFERENCES runs (id, node_id),
      FOREIGN KEY (version_id, link) REFERENCES item_versions (id, link),
      FOREIGN KEY (event_id, link)   REFERENCES events (id, link),
      UNIQUE (id, node_id, link)
    );
    CREATE INDEX proposals_run ON proposals (run_id, node_id);
    CREATE INDEX proposals_version ON proposals (version_id, link);
    CREATE INDEX proposals_event ON proposals (event_id, link);
    CREATE TABLE held_proposals (
      proposal_id INTEGER PRIMARY KEY,
      node_id     INTEGER NOT NULL,
      link        TEXT    NOT NULL,
      resolved_at INTEGER,
      FOREIGN KEY (proposal_id, node_id, link) REFERENCES proposals (id, node_id, link),
      UNIQUE (node_id, link)
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

extension AutomationVersionTwoFixture {
  /// フィクスチャの行。
  static let rows = #"""
    INSERT INTO node_defs VALUES(1,'action');
    INSERT INTO node_defs VALUES(2,'action');
    INSERT INTO node_defs VALUES(3,'action');
    INSERT INTO node_defs VALUES(4,'action');
    INSERT INTO node_defs VALUES(5,'action');
    INSERT INTO node_defs VALUES(6,'action');
    INSERT INTO node_defs VALUES(7,'action');
    INSERT INTO action_defs VALUES(1,'action','{"command":"gh issue list",\#
    "coverage":"currentSet","directory":"."}');
    INSERT INTO action_defs VALUES(2,'action','{"agent":"claude","coverage":"newArrivals",\#
    "instruction":"取る","model":"haiku","timeoutMinutes":5,"tools":["mcp__slack__search"]}');
    INSERT INTO action_defs VALUES(3,'action','{"command":"jq -c .","directory":"."}');
    INSERT INTO action_defs VALUES(4,'action','{"agent":"claude","deliver":"taskCandidates",\#
    "instruction":"決める","model":"sonnet"}');
    INSERT INTO action_defs VALUES(5,'action','{"agent":"claude","deliver":"report",\#
    "instruction":"要約する","model":"haiku"}');
    INSERT INTO action_defs VALUES(6,'action','{"agent":"claude","deliver":"report",\#
    "instruction":"投稿する","model":"sonnet","tools":["Bash(gh search prs:*)"]}');
    INSERT INTO action_defs VALUES(7,'action','{"command":"~\/bin\/send.sh","deliver":"none",\#
    "directory":"bin","timeoutMinutes":3}');
    INSERT INTO automations VALUES(1,'見本','menuBar','6F1C2D3E-4B5A-4C6D-8E7F-9A0B1C2D3E4F',NULL,\#
    1,1793000000000);
    INSERT INTO nodes VALUES(1,1,0,'issues','課題を取る','{"kind":"interval","minutes":30}',NULL,NULL,\#
    1,1793000000000,NULL,NULL,1,5,0,'{}');
    INSERT INTO nodes VALUES(2,1,1,'slack','Slack を取る','{"expression":"0 9 * * 1-5",\#
    "kind":"cron"}',NULL,14,2,1793000000000,NULL,NULL,NULL,0,2,'{}');
    INSERT INTO nodes VALUES(3,1,2,'filter','絞る','{"kind":"arrival"}',NULL,NULL,3,1793000000000,\#
    NULL,NULL,NULL,0,2,'{}');
    INSERT INTO nodes VALUES(4,1,3,'judge','判定','{"kind":"arrival"}',20,NULL,4,1793000000000,\#
    NULL,NULL,NULL,0,0,'{"dropped":{"expired":1},"withdrawn":1}');
    INSERT INTO nodes VALUES(5,1,4,'digest','要約','{"expression":"0 18 * * *","kind":"cron"}',\#
    NULL,NULL,5,1793000000000,NULL,NULL,NULL,0,0,'{}');
    INSERT INTO nodes VALUES(6,1,5,'post','投稿','{"kind":"manual"}',NULL,NULL,6,1793000000000,\#
    1793003720000,NULL,NULL,0,0,'{}');
    INSERT INTO nodes VALUES(7,1,6,'send','送る','{"kind":"arrival"}',NULL,NULL,7,1793000000000,\#
    NULL,NULL,NULL,0,0,'{}');
    INSERT INTO node_edges VALUES(1,2,3,0,'new',48,0,2);
    INSERT INTO node_edges VALUES(1,1,4,0,'new',NULL,5,0);
    INSERT INTO node_edges VALUES(1,3,4,1,'new',NULL,0,2);
    INSERT INTO node_edges VALUES(1,1,5,0,'all',24,5,0);
    INSERT INTO node_edges VALUES(1,3,7,0,'new',NULL,0,2);
    INSERT INTO items VALUES(1,1,1,'a',NULL,NULL,1793000120000,NULL,NULL);
    INSERT INTO items VALUES(2,1,2,'b',NULL,NULL,1793000120000,1793001860000,5);
    INSERT INTO items VALUES(3,1,4,'c',NULL,NULL,1793001860000,NULL,NULL);
    INSERT INTO item_versions VALUES(1,1,1,'{"body":"課題 a","id":"a",\#
    "link":"https://example.com/a","time":"2026-10-26T07:33:20.000Z"}',1793000120000);
    INSERT INTO item_versions VALUES(2,2,2,'{"body":"課題 b","id":"b",\#
    "link":"https://example.com/b","time":"2026-10-26T07:33:20.000Z"}',1793000120000);
    INSERT INTO item_versions VALUES(3,1,3,'{"body":"課題 a（更新）","id":"a",\#
    "link":"https://example.com/a","time":"2026-10-26T07:33:20.000Z"}',1793001860000);
    INSERT INTO item_versions VALUES(4,3,4,'{"body":"課題 c","id":"c",\#
    "link":"https://example.com/c","time":"2026-10-26T07:33:20.000Z"}',1793001860000);
    INSERT INTO events VALUES(1,2,1,1793000180000,'x','{"body":"#dev / 佐藤: レビューお願いします","id":"x",\#
    "link":"https://example.com/x","time":"2026-10-26T07:33:20.000Z"}',NULL,NULL);
    INSERT INTO events VALUES(2,2,2,1793000180000,'y','{"body":"#dev / 鈴木: ありがとう","id":"y",\#
    "link":"https://example.com/y","time":"2026-10-26T07:33:20.000Z"}',NULL,NULL);
    INSERT INTO events VALUES(3,3,1,1793000240000,'2:x','{"body":"#dev / 佐藤: レビューお願いします",\#
    "id":"2:x","link":"https://example.com/x","time":"2026-10-26T07:33:20.000Z"}',NULL,1);
    INSERT INTO events VALUES(4,3,2,1793000240000,'2:y','{"body":"#dev / 鈴木: ありがとう","id":"2:y",\#
    "link":"https://example.com/y","time":"2026-10-26T07:33:20.000Z"}',NULL,2);
    INSERT INTO runs VALUES(1,1,1,1793000060000,1793000120000,'schedule',NULL,\#
    '{"breach":{"count":1,"lines":[{"key":"link","kind":"missingKey","line":3}]},\#
    "execution":{"commandLine":"claude -p","count":2,"end":{"code":0,"kind":"exited"}},\#
    "result":{"fresh":2,"kind":"fetch"},"withdrawn":0}');
    INSERT INTO runs VALUES(2,2,2,1793000120000,1793000180000,'schedule',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":2,"end":{"code":0,"kind":"exited"}},\#
    "result":{"duplicates":1,"fresh":2,"kind":"fetch"},"withdrawn":0}');
    INSERT INTO runs VALUES(3,3,3,1793000180000,1793000240000,'arrival',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":2,"end":{"code":0,"kind":"exited"}},\#
    "reads":true,"result":{"fresh":2,"kind":"process"},"withdrawn":0}');
    INSERT INTO runs VALUES(4,4,4,1793000240000,1793000300000,'arrival',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":4,"end":{"code":0,"kind":"exited"}},\#
    "reads":true,"result":{"kind":"judge","proposed":3,"resolved":0}}');
    INSERT INTO runs VALUES(5,7,7,1793000300000,1793000360000,'arrival',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":2,"end":{"code":0,"kind":"exited"}},\#
    "reads":true,"result":{"count":2,"kind":"sideEffect"}}');
    INSERT INTO runs VALUES(6,5,5,1793000360000,1793000420000,'schedule',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":1,"end":{"code":0,"kind":"exited"}},\#
    "reads":true,"result":{"kind":"report","text":"課題は 2 件\n- a\n- b"}}');
    INSERT INTO runs VALUES(7,6,6,1793000420000,1793000480000,'now',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":1,"end":{"code":0,"kind":"exited"}},\#
    "result":{"kind":"work","text":"投稿した\n- #1"}}');
    INSERT INTO runs VALUES(8,6,6,1793000480000,1793000540000,'now',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":0,"end":{"code":0,"kind":"exited"}},\#
    "result":{"kind":"work","nothing":"投稿するものが無い"}}');
    INSERT INTO runs VALUES(9,1,1,1793001800000,1793001860000,'schedule',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":2,"end":{"code":0,"kind":"exited"}},\#
    "result":{"fresh":1,"kind":"fetch"},"withdrawn":0}');
    INSERT INTO runs VALUES(10,4,4,1793001860000,1793001920000,'arrival',NULL,\#
    '{"carried":{"lapsed":1},"execution":{"commandLine":"claude -p","count":2,"end":{"code":0,\#
    "kind":"exited"}},"reads":true,"result":{"dismissed":[{"link":"https://example.com/a",\#
    "why":"alreadyProposed"}],"kind":"judge","proposed":1,"resolved":1}}');
    INSERT INTO runs VALUES(11,1,1,1793003600000,1793003660000,'schedule','{"detail":"boom",\#
    "kind":"ended"}','{"execution":{"commandLine":"claude -p","count":0,\#
    "end":{"kind":"timeLimit"}}}');
    INSERT INTO runs VALUES(12,5,5,1793003660000,1793003720000,'schedule',NULL,\#
    '{"execution":{"commandLine":"claude -p","count":0,"end":{"code":0,"kind":"exited"}},\#
    "reads":true,"result":{"kind":"report"}}');
    INSERT INTO run_item_inputs VALUES(4,1,'taken');
    INSERT INTO run_item_inputs VALUES(4,2,'taken');
    INSERT INTO run_item_inputs VALUES(6,1,'taken');
    INSERT INTO run_item_inputs VALUES(6,2,'taken');
    INSERT INTO run_item_inputs VALUES(10,1,'closed');
    INSERT INTO run_item_inputs VALUES(10,2,'replaced');
    INSERT INTO run_item_inputs VALUES(10,3,'overflow');
    INSERT INTO run_item_inputs VALUES(10,4,'taken');
    INSERT INTO run_item_inputs VALUES(12,1,'expired');
    INSERT INTO run_item_inputs VALUES(12,3,'taken');
    INSERT INTO run_item_inputs VALUES(12,4,'taken');
    INSERT INTO run_event_inputs VALUES(3,1,'taken');
    INSERT INTO run_event_inputs VALUES(3,2,'taken');
    INSERT INTO run_event_inputs VALUES(4,3,'taken');
    INSERT INTO run_event_inputs VALUES(4,4,'taken');
    INSERT INTO run_event_inputs VALUES(5,3,'taken');
    INSERT INTO run_event_inputs VALUES(5,4,'taken');
    INSERT INTO proposals VALUES(1,4,4,1,NULL,'https://example.com/a','a を直す',NULL,NULL,'依頼されている');
    INSERT INTO proposals VALUES(2,4,4,2,NULL,'https://example.com/b','b を見る',NULL,NULL,NULL);
    INSERT INTO proposals VALUES(4,10,4,4,NULL,'https://example.com/c','c をする','2026-11-20',\#
    '6F1C2D3E-4B5A-4C6D-8E7F-9A0B1C2D3E4F',NULL);
    INSERT INTO held_proposals VALUES(1,4,'https://example.com/a',NULL);
    INSERT INTO held_proposals VALUES(4,4,'https://example.com/c',NULL);
    INSERT INTO settlements VALUES(1,1793000540000,'accepted',1);
    INSERT INTO settlements VALUES(2,1793000600000,'dismissed',NULL);
    """#
}
