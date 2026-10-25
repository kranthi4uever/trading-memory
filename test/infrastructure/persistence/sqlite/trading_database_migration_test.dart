import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:trading_memory/infrastructure/persistence/sqlite/trading_database.dart';

void main() {
  late Directory tempDirectory;
  late String databasePath;
  late Database version1Database;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'trading_memory_migration_',
    );
    databasePath = '${tempDirectory.path}/migration_test.db';

    version1Database = await openDatabase(
      databasePath,
      version: 1,
      onCreate: (db, version) async {
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
            expiry_month INTEGER NOT NULL,
            expiry_day INTEGER NOT NULL,
            strike REAL NOT NULL,
            option_type TEXT NOT NULL,
            side TEXT NOT NULL,
            source TEXT NOT NULL,
            quantity INTEGER NOT NULL,
            price REAL NOT NULL,
            broker_trade_id TEXT,
            broker_order_id TEXT,
            received_at TEXT
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
      },
    );

    await version1Database.insert('trades', {
      'id': 'trade-existing',
      'mode': 'real',
      'strategy': 'ironCondor',
      'status': 'draft',
      'confirmed_at': null,
      'closed_at': null,
    });

    await version1Database.insert('executions', {
      'id': 'execution-existing',
      'executed_at': '2026-10-10T09:30:00.000',
      'underlying': 'NIFTY',
      'expiry_year': 2026,
      'expiry_month': 10,
      'expiry_day': 13,
      'strike': 25000.0,
      'option_type': 'call',
      'side': 'buy',
      'source': 'broker',
      'quantity': 50,
      'price': 100.0,
      'broker_trade_id': 'broker-fill-existing',
      'broker_order_id': null,
      'received_at': '2026-10-10T09:31:00.000',
    });

    await version1Database.insert('execution_assignments', {
      'execution_id': 'execution-existing',
      'trade_id': 'trade-existing',
      'assigned_at': '2026-10-10T09:32:00.000',
    });

    await version1Database.close();
  });

  tearDown(() async {
    await tempDirectory.delete(recursive: true);
  });

  test('upgrades version 1 while preserving existing records', () async {
    final tradingDatabase = TradingDatabase(databasePath: databasePath);

    try {
      final db = await tradingDatabase.database;

      final trades = await db.query(
        'trades',
        where: 'id = ?',
        whereArgs: ['trade-existing'],
      );

      final executions = await db.query(
        'executions',
        where: 'id = ?',
        whereArgs: ['execution-existing'],
      );

      final assignments = await db.query(
        'execution_assignments',
        where: 'execution_id = ?',
        whereArgs: ['execution-existing'],
      );

      expect(trades, hasLength(1));
      expect(executions, hasLength(1));
      expect(assignments, hasLength(1));

      expect(trades.single['mode'], 'real');
      expect(executions.single['broker_trade_id'], 'broker-fill-existing');
      expect(assignments.single['trade_id'], 'trade-existing');

      final tableRows = await db.rawQuery('''
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
      ''');

      final tableNames = tableRows
          .map((row) => row['name'])
          .whereType<String>()
          .toSet();

      expect(tableNames, contains('position_states'));
      expect(tableNames, contains('position_legs'));
      expect(tableNames, contains('market_snapshots'));
      expect(tableNames, contains('geometry_snapshots'));
      expect(tableNames, contains('economic_snapshots'));
      expect(tableNames, contains('risk_snapshots'));
      expect(tableNames, contains('decision_records'));

      expect(await db.getVersion(), TradingDatabase.schemaVersion);
    } finally {
      await tradingDatabase.close();
    }
  });
}
