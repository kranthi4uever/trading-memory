import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:trading_memory/domain/trade/trade_id.dart';
import 'package:trading_memory/domain/trade/trade_mode.dart';
import 'package:trading_memory/domain/trade/trade_status.dart';
import 'package:trading_memory/domain/trading/execution/execution.dart';
import 'package:trading_memory/domain/trading/execution/execution_id.dart';
import 'package:trading_memory/domain/trading/execution/execution_source.dart';
import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/execution/option_contract.dart';
import 'package:trading_memory/infrastructure/persistence/sqlite/sqlite_trading_repository.dart';
import 'package:trading_memory/infrastructure/persistence/sqlite/trading_database.dart';

void main() {
  late TradingDatabase database;
  late SqliteTradingRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = TradingDatabase(databasePath: inMemoryDatabasePath);
    await database.database;
    repository = SqliteTradingRepository(database);
  });

  tearDown(() async => database.close());

  test('creates a persisted Paper draft with individually preserved manual executions', () async {
    final expiry = ExpiryDate(2026, 10, 29);
    final executions = [
      Execution(
        id: const ExecutionId('paper-test-1'),
        executedAt: DateTime(2026, 10, 10, 10),
        contract: OptionContract(underlying: 'NIFTY', expiry: expiry, strike: 25000, optionType: OptionType.call),
        side: ExecutionSide.sell, source: ExecutionSource.manual, quantity: 65, price: 120,
      ),
      Execution(
        id: const ExecutionId('paper-test-2'),
        executedAt: DateTime(2026, 10, 10, 10),
        contract: OptionContract(underlying: 'NIFTY', expiry: expiry, strike: 25200, optionType: OptionType.call),
        side: ExecutionSide.buy, source: ExecutionSource.manual, quantity: 65, price: 60,
      ),
    ];

    final created = await repository.createDraftPaperTrade(
      tradeId: const TradeId('paper-test-trade'),
      executions: executions,
    );
    final loaded = await repository.getTrade(const TradeId('paper-test-trade'));

    expect(created.mode, TradeMode.paper);
    expect(created.status, TradeStatus.draft);
    expect(loaded, isNotNull);
    expect(loaded!.mode, TradeMode.paper);
    expect(loaded.status, TradeStatus.draft);
    expect(loaded.executions, hasLength(2));
    expect(loaded.executions.map((e) => e.source), everyElement(ExecutionSource.manual));
    expect(loaded.executions.map((e) => e.id.value), ['paper-test-1', 'paper-test-2']);
    expect(loaded.netPremium, 3900);
  });

  test('edits a saved Paper draft by changing and adding legs', () async {
    final expiry = ExpiryDate(2026, 10, 29);
    await repository.createDraftPaperTrade(
      tradeId: const TradeId('editable-paper-trade'),
      executions: [
        Execution(
          id: const ExecutionId('editable-leg-1'),
          executedAt: DateTime(2026, 10, 10, 10),
          contract: OptionContract(underlying: 'NIFTY', expiry: expiry, strike: 25000, optionType: OptionType.call),
          side: ExecutionSide.sell, source: ExecutionSource.manual, quantity: 65, price: 120,
        ),
        Execution(
          id: const ExecutionId('editable-leg-2'),
          executedAt: DateTime(2026, 10, 10, 10),
          contract: OptionContract(underlying: 'NIFTY', expiry: expiry, strike: 25200, optionType: OptionType.call),
          side: ExecutionSide.buy, source: ExecutionSource.manual, quantity: 65, price: 60,
        ),
      ],
    );

    await repository.updateDraftPaperTrade(
      tradeId: const TradeId('editable-paper-trade'),
      executions: [
        Execution(
          id: const ExecutionId('editable-leg-1'),
          executedAt: DateTime(2026, 10, 10, 10),
          contract: OptionContract(underlying: 'NIFTY', expiry: expiry, strike: 25050, optionType: OptionType.call),
          side: ExecutionSide.sell, source: ExecutionSource.manual, quantity: 65, price: 125,
        ),
        Execution(
          id: const ExecutionId('editable-leg-3'),
          executedAt: DateTime(2026, 10, 10, 10),
          contract: OptionContract(underlying: 'NIFTY', expiry: expiry, strike: 24800, optionType: OptionType.put),
          side: ExecutionSide.buy, source: ExecutionSource.manual, quantity: 65, price: 70,
        ),
      ],
    );

    final updated = await repository.getTrade(const TradeId('editable-paper-trade'));
    expect(updated, isNotNull);
    expect(updated!.status, TradeStatus.draft);
    expect(updated.executions, hasLength(2));
    expect(updated.executions.map((e) => e.id.value), ['editable-leg-1', 'editable-leg-3']);
    expect(updated.executions.first.contract.strike, 25050);
    expect(updated.executions.first.price, 125);
    expect(updated.executions.last.contract.optionType, OptionType.put);
    expect(updated.positionStates, isEmpty);
  });

  test('rejects a Paper draft with broker-sourced executions', () async {
    final execution = Execution(
      id: const ExecutionId('broker-in-paper'),
      executedAt: DateTime(2026, 10, 10, 10),
      contract: OptionContract(underlying: 'NIFTY', expiry: ExpiryDate(2026, 10, 29), strike: 25000, optionType: OptionType.call),
      side: ExecutionSide.buy, source: ExecutionSource.broker, quantity: 65, price: 100,
      brokerOrderId: 'broker-order-123',
    );

    await expectLater(
      repository.createDraftPaperTrade(tradeId: const TradeId('bad-paper'), executions: [execution]),
      throwsArgumentError,
    );
  });
}
