import GRDB

public enum Schema {
  public static let migrationNames = ["v1", "v2"]

  public static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(sql: """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE setting (key TEXT PRIMARY KEY, position INTEGER NOT NULL, value TEXT NOT NULL);
        CREATE TABLE download (id TEXT NOT NULL, position INTEGER PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE document (name TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }
    migrator.registerMigration("v2") { db in
      try db.execute(sql: """
        CREATE TABLE profile (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE "window" (id TEXT PRIMARY KEY, seq INTEGER NOT NULL, profile_id TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE tab (id TEXT PRIMARY KEY, seq INTEGER NOT NULL,
          window_id TEXT NOT NULL REFERENCES "window"(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
          profile_id TEXT NOT NULL, position INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX tab_by_window ON tab (window_id, position);
        CREATE TABLE tab_group (id TEXT PRIMARY KEY, seq INTEGER NOT NULL,
          window_id TEXT NOT NULL REFERENCES "window"(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, payload TEXT NOT NULL);
        CREATE TABLE split (id TEXT PRIMARY KEY, seq INTEGER NOT NULL,
          window_id TEXT NOT NULL REFERENCES "window"(id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, payload TEXT NOT NULL);
        CREATE TABLE pin_table (kind TEXT NOT NULL, profile_id TEXT NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY (kind, profile_id));
        CREATE TABLE archive (kind TEXT NOT NULL, position INTEGER NOT NULL, id TEXT NOT NULL, closed_at REAL NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY (kind, position));
        CREATE TABLE workspace (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }
    return migrator
  }
}
