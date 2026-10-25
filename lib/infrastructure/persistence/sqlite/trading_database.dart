import 'package:sqflite/sqflite.dart';

class TradingDatabase {
  static const int schemaVersion = 9;
  static const String databaseName = 'trading_memory.db';

  final String? databasePath;

  Database? _database;

  TradingDatabase({this.databasePath});

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    final path = databasePath ?? '${await getDatabasesPath()}/$databaseName';

    _database = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
      // Repair databases that were already marked version 7 by an earlier
      // patch but missed the column due to an incomplete migration.
      onOpen: _ensureLifecycleAccountingSchema,
    );

    return _database!;
  }

  Future<void> _createSchema(Database db, int version) async {
    await _createBaseTables(db);
    await _createHistoryTables(db);
    await _createPositionSnapshotDetails(db);
    await _createAdjustmentTables(db);
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createHistoryTables(db);
    }
    if (oldVersion < 3) {
      await _makeSnapshotMetricsNullable(db);
    }
    if (oldVersion < 4) {
      await _createPositionSnapshotDetails(db);
    }
    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN gross_realized_pnl REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN actual_charges REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN net_realized_pnl REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN return_on_margin_percentage REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN actual_risk_committed REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN gross_r_multiple REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN net_r_multiple REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN max_margin_blocked REAL',
      );
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN actual_profit_target REAL',
      );
    }
    if (oldVersion < 8) {
      await _ensureEconomicSnapshotColumn(db, 'gross_unrealized_pnl');
    }
    if (oldVersion < 9) {
      await _createAdjustmentTables(db);
    }
    if (oldVersion >= 2 && oldVersion < 5) {
      await db.execute(
        'ALTER TABLE position_legs ADD COLUMN entry_premium REAL',
      );
      await db.execute(
        'ALTER TABLE position_legs ADD COLUMN market_price REAL',
      );
    }
    if (oldVersion < 7) {
      await _migrateDecisionActionConstraint(db);
    }
  }

  /// Ensures lifecycle accounting columns exist even if a previous build
  /// advanced user_version without completing the schema change.
  Future<void> _ensureLifecycleAccountingSchema(DatabaseExecutor db) async {
    await _ensureEconomicSnapshotColumn(db, 'gross_unrealized_pnl');
  }

  Future<void> _ensureEconomicSnapshotColumn(
    DatabaseExecutor db,
    String columnName,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info(economic_snapshots)');
    final exists = columns.any((column) => column['name'] == columnName);
    if (!exists) {
      await db.execute(
        'ALTER TABLE economic_snapshots ADD COLUMN $columnName REAL',
      );
    }
  }

  Future<void> _migrateDecisionActionConstraint(Database db) async {
    // SQLite cannot alter a CHECK constraint in place. Rebuild only this table,
    // preserving every existing decision id and row.
    await db.execute(
      'ALTER TABLE decision_records RENAME TO decision_records_v6',
    );
    await db.execute('''
      CREATE TABLE decision_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        trade_id TEXT NOT NULL,
        position_state_id TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        action TEXT NOT NULL
          CHECK (action IN ('hold', 'adjust', 'exit', 'add', 'reduce', 'partialExit')),
        observation TEXT,
        FOREIGN KEY (position_state_id, trade_id)
          REFERENCES position_states(id, trade_id)
          ON DELETE RESTRICT
      )
    ''');
    await db.execute('''
      INSERT INTO decision_records
        (id, trade_id, position_state_id, recorded_at, action, observation)
      SELECT id, trade_id, position_state_id, recorded_at, action, observation
      FROM decision_records_v6
    ''');
    await db.execute('DROP TABLE decision_records_v6');
    await db.execute('''
      CREATE INDEX index_decision_records_trade_id
      ON decision_records (trade_id, recorded_at)
    ''');
  }

  Future<void> _createBaseTables(Database db) async {
    await db.execute('''
      CREATE TABLE trades (
        id TEXT PRIMARY KEY,
        mode TEXT NOT NULL
          CHECK (mode IN ('real', 'paper')),
        strategy TEXT NOT NULL,
        status TEXT NOT NULL
          CHECK (status IN ('draft', 'confirmed', 'closed')),
        confirmed_at TEXT,
        closed_at TEXT,
        CHECK (
          (status = 'draft'
            AND confirmed_at IS NULL
            AND closed_at IS NULL)
          OR
          (status = 'confirmed'
            AND confirmed_at IS NOT NULL
            AND closed_at IS NULL)
          OR
          (status = 'closed'
            AND confirmed_at IS NOT NULL
            AND closed_at IS NOT NULL)
        )
      )
    ''');

    await db.execute('''
      CREATE TABLE executions (
        id TEXT PRIMARY KEY,
        executed_at TEXT NOT NULL,
        underlying TEXT NOT NULL,
        expiry_year INTEGER NOT NULL,
        expiry_month INTEGER NOT NULL
          CHECK (expiry_month BETWEEN 1 AND 12),
        expiry_day INTEGER NOT NULL
          CHECK (expiry_day BETWEEN 1 AND 31),
        strike REAL NOT NULL
          CHECK (strike > 0),
        option_type TEXT NOT NULL
          CHECK (option_type IN ('call', 'put')),
        side TEXT NOT NULL
          CHECK (side IN ('buy', 'sell')),
        source TEXT NOT NULL
          CHECK (source IN ('broker', 'manual')),
        quantity INTEGER NOT NULL
          CHECK (quantity > 0),
        price REAL NOT NULL
          CHECK (price >= 0),
        broker_trade_id TEXT,
        broker_order_id TEXT,
        received_at TEXT,
        CHECK (
          source != 'broker'
          OR broker_trade_id IS NOT NULL
          OR broker_order_id IS NOT NULL
        ),
        CHECK (
          broker_trade_id IS NULL
          OR length(trim(broker_trade_id)) > 0
        ),
        CHECK (
          broker_order_id IS NULL
          OR length(trim(broker_order_id)) > 0
        )
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX unique_broker_trade_id
      ON executions (broker_trade_id)
      WHERE broker_trade_id IS NOT NULL
    ''');

    await db.execute('''
      CREATE TABLE execution_assignments (
        execution_id TEXT PRIMARY KEY
          REFERENCES executions(id) ON DELETE RESTRICT,
        trade_id TEXT NOT NULL
          REFERENCES trades(id) ON DELETE RESTRICT,
        assigned_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX index_execution_assignments_trade_id
      ON execution_assignments (trade_id)
    ''');
  }

  Future<void> _createHistoryTables(Database db) async {
    await db.execute('''
      CREATE TABLE position_states (
        id TEXT PRIMARY KEY,
        trade_id TEXT NOT NULL
          REFERENCES trades(id) ON DELETE RESTRICT,
        captured_at TEXT NOT NULL,
        underlying TEXT NOT NULL,
        expiry_year INTEGER NOT NULL,
        expiry_month INTEGER NOT NULL,
        expiry_day INTEGER NOT NULL,
        strategy TEXT NOT NULL,
        UNIQUE (id, trade_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX index_position_states_trade_id
      ON position_states (trade_id, captured_at)
    ''');

    await db.execute('''
      CREATE TABLE position_legs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        position_state_id TEXT NOT NULL
          REFERENCES position_states(id) ON DELETE RESTRICT,
        underlying TEXT NOT NULL,
        expiry_year INTEGER NOT NULL,
        expiry_month INTEGER NOT NULL,
        expiry_day INTEGER NOT NULL,
        strike REAL NOT NULL CHECK (strike > 0),
        option_type TEXT NOT NULL
          CHECK (option_type IN ('call', 'put')),
        side TEXT NOT NULL
          CHECK (side IN ('buy', 'sell')),
        quantity INTEGER NOT NULL CHECK (quantity > 0),
        entry_premium REAL,
        market_price REAL
      )
    ''');

    await db.execute('''
      CREATE INDEX index_position_legs_state_id
      ON position_legs (position_state_id)
    ''');

    await db.execute('''
      CREATE TABLE market_snapshots (
        position_state_id TEXT PRIMARY KEY
          REFERENCES position_states(id) ON DELETE RESTRICT,
        spot REAL,
        vix REAL,
        atm_straddle REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE geometry_snapshots (
        position_state_id TEXT PRIMARY KEY
          REFERENCES position_states(id) ON DELETE RESTRICT,
        lower_breakeven REAL,
        upper_breakeven REAL,
        wing_width REAL,
        distance_to_lower_breakeven REAL,
        distance_to_upper_breakeven REAL,
        profit_range REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE economic_snapshots (
        position_state_id TEXT PRIMARY KEY
          REFERENCES position_states(id) ON DELETE RESTRICT,
        pnl REAL,
        pnl_percentage REAL,
        capital_deployed REAL,
        margin REAL,
        cost REAL,
        gross_realized_pnl REAL,
        gross_unrealized_pnl REAL,
        actual_charges REAL,
        net_realized_pnl REAL,
        return_on_margin_percentage REAL,
        actual_risk_committed REAL,
        gross_r_multiple REAL,
        net_r_multiple REAL,
        max_margin_blocked REAL,
        actual_profit_target REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE risk_snapshots (
        position_state_id TEXT PRIMARY KEY
          REFERENCES position_states(id) ON DELETE RESTRICT,
        max_profit REAL,
        max_loss REAL,
        delta REAL,
        gamma REAL,
        theta REAL,
        vega REAL,
        iv REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE decision_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        trade_id TEXT NOT NULL,
        position_state_id TEXT NOT NULL,
        recorded_at TEXT NOT NULL,
        action TEXT NOT NULL
          CHECK (action IN ('hold', 'adjust', 'exit', 'add', 'reduce', 'partialExit')),
        observation TEXT,
        FOREIGN KEY (position_state_id, trade_id)
          REFERENCES position_states(id, trade_id)
          ON DELETE RESTRICT
      )
    ''');

    await db.execute('''
      CREATE INDEX index_decision_records_trade_id
      ON decision_records (trade_id, recorded_at)
    ''');
  }

  Future<void> _createAdjustmentTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS adjustment_episodes (
        id TEXT PRIMARY KEY,
        trade_id TEXT NOT NULL REFERENCES trades(id) ON DELETE CASCADE,
        before_position_state_id TEXT NOT NULL,
        after_position_state_id TEXT,
        before_view_suggested TEXT NOT NULL,
        before_view_confirmed TEXT NOT NULL,
        before_view_assessed_at TEXT NOT NULL,
        before_view_confidence REAL,
        before_view_evidence TEXT NOT NULL DEFAULT '[]',
        before_view_correction_note TEXT,
        after_view_suggested TEXT,
        after_view_confirmed TEXT,
        after_view_assessed_at TEXT,
        after_view_confidence REAL,
        after_view_evidence TEXT,
        after_view_correction_note TEXT,
        reason TEXT NOT NULL,
        reason_note TEXT,
        selected_proposal_id TEXT,
        execution_ids TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        confirmed_at TEXT,
        status TEXT NOT NULL CHECK (status IN ('proposed','pendingConfirmation','pendingExecution','applied','partiallyApplied','failed','cancelled')),
        failure_message TEXT,
        FOREIGN KEY (before_position_state_id, trade_id)
          REFERENCES position_states(id, trade_id) ON DELETE RESTRICT,
        FOREIGN KEY (after_position_state_id, trade_id)
          REFERENCES position_states(id, trade_id) ON DELETE RESTRICT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS index_adjustment_episodes_trade_id
      ON adjustment_episodes (trade_id, created_at)
    ''');
  }

  Future<void> _createPositionSnapshotDetails(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE position_snapshot_details (
        position_state_id TEXT PRIMARY KEY
          REFERENCES position_states(id) ON DELETE RESTRICT,
        entry_debit_credit REAL,
        comments TEXT,
        planned_rules TEXT
      )
    ''');
  }

  Future<void> _makeSnapshotMetricsNullable(Database db) async {
    // Keep confirmed position structure even when market-derived metrics are unavailable.
    await db.execute(
      'ALTER TABLE market_snapshots RENAME TO market_snapshots_v2',
    );
    await db.execute(
      'CREATE TABLE market_snapshots (position_state_id TEXT PRIMARY KEY REFERENCES position_states(id) ON DELETE RESTRICT, spot REAL, vix REAL, atm_straddle REAL)',
    );
    await db.execute(
      'INSERT INTO market_snapshots SELECT position_state_id, spot, vix, atm_straddle FROM market_snapshots_v2',
    );
    await db.execute('DROP TABLE market_snapshots_v2');

    await db.execute(
      'ALTER TABLE geometry_snapshots RENAME TO geometry_snapshots_v2',
    );
    await db.execute(
      'CREATE TABLE geometry_snapshots (position_state_id TEXT PRIMARY KEY REFERENCES position_states(id) ON DELETE RESTRICT, lower_breakeven REAL, upper_breakeven REAL, wing_width REAL, distance_to_lower_breakeven REAL, distance_to_upper_breakeven REAL, profit_range REAL)',
    );
    await db.execute(
      'INSERT INTO geometry_snapshots SELECT position_state_id, lower_breakeven, upper_breakeven, wing_width, distance_to_lower_breakeven, distance_to_upper_breakeven, profit_range FROM geometry_snapshots_v2',
    );
    await db.execute('DROP TABLE geometry_snapshots_v2');

    await db.execute(
      'ALTER TABLE economic_snapshots RENAME TO economic_snapshots_v2',
    );
    await db.execute(
      'CREATE TABLE economic_snapshots (position_state_id TEXT PRIMARY KEY REFERENCES position_states(id) ON DELETE RESTRICT, pnl REAL, pnl_percentage REAL, capital_deployed REAL, margin REAL, cost REAL)',
    );
    await db.execute(
      'INSERT INTO economic_snapshots SELECT position_state_id, pnl, pnl_percentage, capital_deployed, margin, cost FROM economic_snapshots_v2',
    );
    await db.execute('DROP TABLE economic_snapshots_v2');

    await db.execute('ALTER TABLE risk_snapshots RENAME TO risk_snapshots_v2');
    await db.execute(
      'CREATE TABLE risk_snapshots (position_state_id TEXT PRIMARY KEY REFERENCES position_states(id) ON DELETE RESTRICT, max_profit REAL, max_loss REAL, delta REAL, gamma REAL, theta REAL, vega REAL, iv REAL)',
    );
    await db.execute(
      'INSERT INTO risk_snapshots SELECT position_state_id, max_profit, max_loss, delta, gamma, theta, vega, iv FROM risk_snapshots_v2',
    );
    await db.execute('DROP TABLE risk_snapshots_v2');
  }

  Future<void> close() async {
    final db = _database;
    if (db == null) {
      return;
    }

    await db.close();
    _database = null;
  }
}
