import GRDB

public enum Schema {
  public static let migrationNames = ["v1"]

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
    return migrator
  }
}
