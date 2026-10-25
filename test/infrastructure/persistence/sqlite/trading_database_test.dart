import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:trading_memory/infrastructure/persistence/sqlite/trading_database.dart';

void main() {
  late TradingDatabase tradingDatabase;
  late Database database;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tradingDatabase = TradingDatabase(databasePath: inMemoryDatabasePath);
    database = await tradingDatabase.database;
  });

  tearDown(() async {
    await tradingDatabase.close();
  });

  Future<void> insertTrade({
    required String id,
    String mode = 'real',
    String strategy = 'ironCondor',
  }) async {
    await database.insert('trades', {
      'id': id,
      'mode': mode,
      'strategy': strategy,
      'status': 'draft',
      'confirmed_at': null,
      'closed_at': null,
    });
  }

  Future<void> insertBrokerExecution({
    required String id,
    String brokerTradeId = 'broker-fill-1',
  }) async {
    await database.insert('executions', {
      'id': id,
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
      'broker_trade_id': brokerTradeId,
      'broker_order_id': null,
      'received_at': '2026-10-10T09:31:00.000',
    });
  }

  test('creates the expected tables', () async {
    final result = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );

    final names = result.map((row) => row['name']).toSet();

    expect(names, contains('trades'));
    expect(names, contains('executions'));
    expect(names, contains('execution_assignments'));
  });

  test('rejects an assignment to a nonexistent trade', () async {
    await insertBrokerExecution(id: 'execution-1');

    expect(
      () => database.insert('execution_assignments', {
        'execution_id': 'execution-1',
        'trade_id': 'missing-trade',
        'assigned_at': '2026-10-10T09:32:00.000',
      }),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('rejects assigning one execution to two trades', () async {
    await insertTrade(id: 'trade-1');
    await insertTrade(id: 'trade-2');
    await insertBrokerExecution(id: 'execution-1');

    await database.insert('execution_assignments', {
      'execution_id': 'execution-1',
      'trade_id': 'trade-1',
      'assigned_at': '2026-10-10T09:32:00.000',
    });

    expect(
      () => database.insert('execution_assignments', {
        'execution_id': 'execution-1',
        'trade_id': 'trade-2',
        'assigned_at': '2026-10-10T09:33:00.000',
      }),
      throwsA(isA<DatabaseException>()),
    );

    final assignments = await database.query(
      'execution_assignments',
      where: 'execution_id = ?',
      whereArgs: ['execution-1'],
    );

    expect(assignments, hasLength(1));
    expect(assignments.single['trade_id'], 'trade-1');
  });

  test('rejects duplicate broker fill IDs', () async {
    await insertBrokerExecution(id: 'execution-1');

    expect(
      () => insertBrokerExecution(id: 'execution-2'),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('rejects a broker execution without broker identifiers', () async {
    expect(
      () => database.insert('executions', {
        'id': 'execution-no-source-id',
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
        'broker_trade_id': null,
        'broker_order_id': null,
        'received_at': '2026-10-10T09:31:00.000',
      }),
      throwsA(isA<DatabaseException>()),
    );
  });
}
