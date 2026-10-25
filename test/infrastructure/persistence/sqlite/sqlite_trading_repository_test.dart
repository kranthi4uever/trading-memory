import 'package:flutter_test/flutter_test.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:trading_memory/domain/trade/strategy_structure.dart';

import 'package:trading_memory/domain/trade/trade_id.dart';

import 'package:trading_memory/domain/trade/trade_mode.dart';

import 'package:trading_memory/domain/trade/trade_status.dart';

import 'package:trading_memory/domain/trading/decision/decision_record.dart';

import 'package:trading_memory/domain/trading/execution/execution.dart';

import 'package:trading_memory/domain/trading/execution/execution_id.dart';

import 'package:trading_memory/domain/trading/execution/execution_inbox_entry.dart';

import 'package:trading_memory/domain/trading/execution/execution_source.dart';

import 'package:trading_memory/domain/trading/execution/expiry_date.dart';

import 'package:trading_memory/domain/trading/execution/option_contract.dart';

import 'package:trading_memory/domain/trading/position_state/economic_snapshot.dart';

import 'package:trading_memory/domain/trading/position_state/geometry_snapshot.dart';

import 'package:trading_memory/domain/trading/position_state/market_snapshot.dart';

import 'package:trading_memory/domain/trading/position_state/position_leg.dart';

import 'package:trading_memory/domain/trading/position_state/position_snapshot.dart';

import 'package:trading_memory/domain/trading/position_state/position_state.dart';

import 'package:trading_memory/domain/trading/position_state/position_state_id.dart';

import 'package:trading_memory/domain/trading/position_state/risk_snapshot.dart';

import 'package:trading_memory/infrastructure/persistence/sqlite/sqlite_trading_repository.dart';

import 'package:trading_memory/infrastructure/persistence/sqlite/trading_database.dart';

void main() {
  late TradingDatabase tradingDatabase;

  late SqliteTradingRepository repository;

  late Database database;

  setUpAll(() {
    sqfliteFfiInit();

    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tradingDatabase = TradingDatabase(databasePath: inMemoryDatabasePath);

    database = await tradingDatabase.database;

    repository = SqliteTradingRepository(tradingDatabase);
  });

  tearDown(() async {
    await tradingDatabase.close();
  });

  Execution createExecution(String id) {
    return Execution(
      id: ExecutionId(id),

      executedAt: DateTime(2026, 10, 10, 9, 30),

      contract: OptionContract(
        underlying: 'NIFTY',

        expiry: ExpiryDate(2026, 10, 13),

        strike: 25000,

        optionType: OptionType.call,
      ),

      side: ExecutionSide.buy,

      source: ExecutionSource.broker,

      quantity: 50,

      price: 100,

      brokerTradeId: 'fill-$id',

      brokerOrderId: 'order-$id',
    );
  }

  Future<void> importExecution(Execution execution) {
    return repository.importBrokerExecution(
      entry: ExecutionInboxEntry(
        execution: execution,

        receivedAt: DateTime(2026, 10, 10, 9, 31),
      ),
    );
  }

  PositionState createPositionState({
    required TradeId tradeId,

    required String stateId,
  }) {
    final expiry = ExpiryDate(2026, 10, 13);

    return PositionState(
      id: PositionStateId(stateId),

      tradeId: tradeId.value,

      capturedAt: DateTime(2026, 10, 10, 10),

      position: PositionSnapshot(
        underlying: 'NIFTY',

        expiry: expiry,

        legs: [
          PositionLeg(
            contract: OptionContract(
              underlying: 'NIFTY',

              expiry: expiry,

              strike: 25000,

              optionType: OptionType.call,
            ),

            side: PositionSide.buy,

            quantity: 50,
          ),

          PositionLeg(
            contract: OptionContract(
              underlying: 'NIFTY',

              expiry: expiry,

              strike: 25100,

              optionType: OptionType.call,
            ),

            side: PositionSide.sell,

            quantity: 50,
          ),
        ],

        strategy: StrategyStructure.bearCallSpread,
      ),

      market: const MarketSnapshot(spot: 25050, vix: 14.5, atmStraddle: 300),

      geometry: const GeometrySnapshot(
        lowerBreakeven: 25080,

        upperBreakeven: 25080,

        wingWidth: 100,

        distanceToLowerBreakeven: 30,

        distanceToUpperBreakeven: 30,

        profitRange: 60,
      ),

      economics: const EconomicSnapshot(
        pnl: 1250,

        pnlPercentage: 12.5,

        capitalDeployed: 20000,

        margin: 15000,

        cost: 50,
      ),

      risk: const RiskSnapshot(
        maxProfit: 5000,

        maxLoss: 0,

        delta: -0.15,

        gamma: 0.02,

        theta: 120,

        vega: -80,

        iv: 14,
      ),
    );
  }

  Future<void> confirmTradeForTest(TradeId tradeId) async {
    await repository.confirmTrade(
      tradeId: tradeId,
      strategy: StrategyStructure.bearCallSpread,
      confirmedAt: DateTime(2026, 10, 10, 9, 45),
    );
  }

  Future<void> createConfirmedTradeWithState({
    required TradeId tradeId,

    required String executionId,

    required String stateId,
  }) async {
    final execution = createExecution(executionId);

    await importExecution(execution);

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [execution.id],
    );

    await confirmTradeForTest(tradeId);

    await repository.capturePositionState(
      tradeId: tradeId,

      state: createPositionState(tradeId: tradeId, stateId: stateId),
    );
  }

  test('imports broker execution into unassigned inbox', () async {
    await importExecution(createExecution('execution-1'));

    final entries = await repository.getUnassignedExecutions();

    expect(entries, hasLength(1));

    expect(entries.single.execution.id, ExecutionId('execution-1'));
  });

  test('reimporting the same execution does not create a duplicate', () async {
    final execution = createExecution('execution-1');

    await importExecution(execution);

    await importExecution(execution);

    final entries = await repository.getUnassignedExecutions();

    expect(entries, hasLength(1));
  });

  test('creating draft Real trade removes executions from inbox', () async {
    await importExecution(createExecution('execution-1'));

    await importExecution(createExecution('execution-2'));

    final trade = await repository.createDraftRealTrade(
      tradeId: TradeId('trade-1'),

      executionIds: [ExecutionId('execution-1'), ExecutionId('execution-2')],
    );

    expect(trade.id, TradeId('trade-1'));

    expect(trade.executions, hasLength(2));

    expect(await repository.getUnassignedExecutions(), isEmpty);

    final assignments = await database.query('execution_assignments');

    expect(assignments, hasLength(2));

    expect(assignments.map((row) => row['trade_id']).toSet(), {'trade-1'});
  });

  test('failed trade creation leaves no partial trade or assignment', () async {
    await importExecution(createExecution('execution-1'));

    await importExecution(createExecution('execution-2'));

    await repository.createDraftRealTrade(
      tradeId: TradeId('trade-1'),

      executionIds: [ExecutionId('execution-1')],
    );

    await expectLater(
      repository.createDraftRealTrade(
        tradeId: TradeId('trade-2'),

        executionIds: [ExecutionId('execution-2'), ExecutionId('execution-1')],
      ),

      throwsStateError,
    );

    final trades = await database.query('trades');

    final assignments = await database.query('execution_assignments');

    final inbox = await repository.getUnassignedExecutions();

    expect(trades, hasLength(1));

    expect(assignments, hasLength(1));

    expect(inbox, hasLength(1));

    expect(inbox.single.execution.id, ExecutionId('execution-2'));
  });

  test('rejects an empty execution selection', () async {
    await expectLater(
      repository.createDraftRealTrade(
        tradeId: TradeId('trade-empty'),

        executionIds: const [],
      ),

      throwsArgumentError,
    );

    expect(await database.query('trades'), isEmpty);
  });

  test('getTrade restores a draft real trade and its executions', () async {
    final first = createExecution('execution-1');

    final second = createExecution('execution-2');

    await importExecution(first);

    await importExecution(second);

    const tradeId = TradeId('trade-round-trip');

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [first.id, second.id],
    );

    final restored = await repository.getTrade(tradeId);

    expect(restored, isNotNull);

    expect(restored!.id, tradeId);

    expect(restored.mode, TradeMode.real);

    expect(restored.status, TradeStatus.draft);

    expect(restored.executions, hasLength(2));

    expect(restored.executions.map((execution) => execution.id).toSet(), {
      first.id,

      second.id,
    });

    expect(restored.positionStates, isEmpty);

    expect(restored.decisionRecords, isEmpty);
  });

  test('PositionState survives SQLite save and reload', () async {
    final execution = createExecution('execution-round-trip');

    await importExecution(execution);

    const tradeId = TradeId('trade-state-round-trip');

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [execution.id],
    );

    await confirmTradeForTest(tradeId);

    final state = createPositionState(
      tradeId: tradeId,

      stateId: 'state-round-trip',
    );

    await repository.capturePositionState(tradeId: tradeId, state: state);

    final restored = await repository.getTrade(tradeId);

    expect(restored, isNotNull);

    expect(restored!.positionStates, hasLength(1));

    final actual = restored.positionStates.single;

    expect(actual.id, state.id);

    expect(actual.tradeId, state.tradeId);

    expect(actual.capturedAt, state.capturedAt);

    expect(actual.position.underlying, state.position.underlying);

    expect(actual.position.expiry, state.position.expiry);

    expect(actual.position.strategy, state.position.strategy);

    expect(actual.position.legs, hasLength(2));

    for (var i = 0; i < state.position.legs.length; i++) {
      final expectedLeg = state.position.legs[i];

      final actualLeg = actual.position.legs[i];

      expect(actualLeg.contract.underlying, expectedLeg.contract.underlying);

      expect(actualLeg.contract.expiry, expectedLeg.contract.expiry);

      expect(actualLeg.contract.strike, expectedLeg.contract.strike);

      expect(actualLeg.contract.optionType, expectedLeg.contract.optionType);

      expect(actualLeg.side, expectedLeg.side);

      expect(actualLeg.quantity, expectedLeg.quantity);
    }

    expect(actual.market.spot, state.market.spot);

    expect(actual.market.vix, state.market.vix);

    expect(actual.market.atmStraddle, state.market.atmStraddle);

    expect(actual.geometry.lowerBreakeven, state.geometry.lowerBreakeven);

    expect(actual.geometry.upperBreakeven, state.geometry.upperBreakeven);

    expect(actual.geometry.wingWidth, state.geometry.wingWidth);

    expect(
      actual.geometry.distanceToLowerBreakeven,

      state.geometry.distanceToLowerBreakeven,
    );

    expect(
      actual.geometry.distanceToUpperBreakeven,

      state.geometry.distanceToUpperBreakeven,
    );

    expect(actual.geometry.profitRange, state.geometry.profitRange);

    expect(actual.economics.pnl, state.economics.pnl);

    expect(actual.economics.pnlPercentage, state.economics.pnlPercentage);

    expect(actual.economics.capitalDeployed, state.economics.capitalDeployed);

    expect(actual.economics.margin, state.economics.margin);

    expect(actual.economics.cost, state.economics.cost);

    expect(actual.risk.maxProfit, state.risk.maxProfit);

    expect(actual.risk.maxLoss, state.risk.maxLoss);

    expect(actual.risk.delta, state.risk.delta);

    expect(actual.risk.gamma, state.risk.gamma);

    expect(actual.risk.theta, state.risk.theta);

    expect(actual.risk.vega, state.risk.vega);

    expect(actual.risk.iv, state.risk.iv);
  });

  test('failed PositionState capture rolls back every insert', () async {
    final execution = createExecution('execution-rollback');

    await importExecution(execution);

    const tradeId = TradeId('trade-rollback');

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [execution.id],
    );

    await confirmTradeForTest(tradeId);

    await database.execute('''

      CREATE TRIGGER fail_risk_snapshot

      BEFORE INSERT ON risk_snapshots

      BEGIN

        SELECT RAISE(ABORT, 'forced risk snapshot failure');

      END

    ''');

    final state = createPositionState(
      tradeId: tradeId,

      stateId: 'state-rollback',
    );

    await expectLater(
      repository.capturePositionState(tradeId: tradeId, state: state),

      throwsA(anything),
    );

    expect(await database.query('position_states'), isEmpty);

    expect(await database.query('position_legs'), isEmpty);

    expect(await database.query('market_snapshots'), isEmpty);

    expect(await database.query('geometry_snapshots'), isEmpty);

    expect(await database.query('economic_snapshots'), isEmpty);

    expect(await database.query('risk_snapshots'), isEmpty);
  });

  test('decision survives SQLite save and reload', () async {
    const tradeId = TradeId('trade-decision');

    const stateId = 'state-decision';

    await createConfirmedTradeWithState(
      tradeId: tradeId,

      executionId: 'execution-decision',

      stateId: stateId,
    );

    final decision = DecisionRecord(
      recordedAt: DateTime(2026, 10, 10, 10, 5),

      positionStateId: PositionStateId(stateId),

      action: DecisionAction.adjust,

      observation: 'Spot moved toward the upper breakeven.',
    );

    await repository.recordDecision(tradeId: tradeId, decision: decision);

    final restored = await repository.getTrade(tradeId);

    expect(restored, isNotNull);

    expect(restored!.decisionRecords, hasLength(1));

    final actual = restored.decisionRecords.single;

    expect(actual.recordedAt, decision.recordedAt);

    expect(actual.positionStateId, decision.positionStateId);

    expect(actual.action, decision.action);

    expect(actual.observation, decision.observation);
  });

  test('rejects decision referencing another trade position state', () async {
    const firstTradeId = TradeId('trade-first');

    const secondTradeId = TradeId('trade-second');

    await createConfirmedTradeWithState(
      tradeId: firstTradeId,

      executionId: 'execution-first',

      stateId: 'state-first',
    );

    await createConfirmedTradeWithState(
      tradeId: secondTradeId,

      executionId: 'execution-second',

      stateId: 'state-second',
    );

    final decision = DecisionRecord(
      recordedAt: DateTime(2026, 10, 10, 10, 10),

      positionStateId: const PositionStateId('state-first'),

      action: DecisionAction.adjust,

      observation: 'This state belongs to the first trade.',
    );

    await expectLater(
      repository.recordDecision(tradeId: secondTradeId, decision: decision),

      throwsStateError,
    );

    expect(
      await database.query(
        'decision_records',

        where: 'trade_id = ?',

        whereArgs: [secondTradeId.value],
      ),

      isEmpty,
    );
  });

  test('rejects recording a decision against a draft trade', () async {
    final execution = createExecution('execution-draft-decision');

    await importExecution(execution);

    const tradeId = TradeId('trade-draft-decision');

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [execution.id],
    );

    final decision = DecisionRecord(
      recordedAt: DateTime(2026, 10, 10, 10, 15),

      positionStateId: const PositionStateId('state-not-present'),

      action: DecisionAction.hold,

      observation: 'Waiting for more information.',
    );

    await expectLater(
      repository.recordDecision(tradeId: tradeId, decision: decision),

      throwsStateError,
    );

    expect(await database.query('decision_records'), isEmpty);
  });

  test(
    'closed trade rejects new states and decisions without partial writes',

    () async {
      const tradeId = TradeId('trade-closed');

      await createConfirmedTradeWithState(
        tradeId: tradeId,

        executionId: 'execution-closed',

        stateId: 'state-closed-existing',
      );

      // Close through the repository lifecycle API.
      await repository.closeTrade(
        tradeId: tradeId,
        closedAt: DateTime(2026, 10, 10, 11),
      );

      final newState = createPositionState(
        tradeId: tradeId,

        stateId: 'state-closed-new',
      );

      await expectLater(
        repository.capturePositionState(tradeId: tradeId, state: newState),

        throwsStateError,
      );

      final decision = DecisionRecord(
        recordedAt: DateTime(2026, 10, 10, 11, 5),

        positionStateId: const PositionStateId('state-closed-existing'),

        action: DecisionAction.hold,

        observation: 'Test decision after closure.',
      );

      await expectLater(
        repository.recordDecision(tradeId: tradeId, decision: decision),

        throwsStateError,
      );

      // Only the original state should remain; neither operation

      // should have written a new state or decision.

      final states = await database.query(
        'position_states',

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      );

      final decisions = await database.query(
        'decision_records',

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      );

      expect(states, hasLength(1));

      expect(states.single['id'], 'state-closed-existing');

      expect(decisions, isEmpty);

      expect(
        await database.query(
          'position_legs',

          where: 'position_state_id = ?',

          whereArgs: ['state-closed-new'],
        ),

        isEmpty,
      );
    },
  );

  test('draft trade rejects PositionState without partial writes', () async {
    final execution = createExecution('execution-draft-state');

    await importExecution(execution);

    const tradeId = TradeId('trade-draft-state');

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [execution.id],
    );

    final state = createPositionState(
      tradeId: tradeId,

      stateId: 'state-draft-rejected',
    );

    await expectLater(
      repository.capturePositionState(tradeId: tradeId, state: state),

      throwsStateError,
    );

    expect(
      await database.query(
        'position_states',

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      ),

      isEmpty,
    );

    expect(await database.query('position_legs'), isEmpty);

    expect(await database.query('market_snapshots'), isEmpty);

    expect(await database.query('geometry_snapshots'), isEmpty);

    expect(await database.query('economic_snapshots'), isEmpty);

    expect(await database.query('risk_snapshots'), isEmpty);
  });

  test('closeTrade persists closure and preserves trade history', () async {
    const tradeId = TradeId('trade-close-success');

    await createConfirmedTradeWithState(
      tradeId: tradeId,

      executionId: 'execution-close-success',

      stateId: 'state-close-success',
    );

    final decision = DecisionRecord(
      recordedAt: DateTime(2026, 10, 10, 10, 5),

      positionStateId: const PositionStateId('state-close-success'),

      action: DecisionAction.hold,

      observation: 'Held the position.',
    );

    await repository.recordDecision(tradeId: tradeId, decision: decision);

    final closedAt = DateTime(2026, 10, 10, 11);

    await repository.closeTrade(tradeId: tradeId, closedAt: closedAt);

    final restored = await repository.getTrade(tradeId);

    expect(restored, isNotNull);

    expect(restored!.status, TradeStatus.closed);

    expect(restored.closedAt, closedAt);

    expect(restored.executions, hasLength(1));

    expect(restored.positionStates, hasLength(1));

    expect(restored.decisionRecords, hasLength(1));

    expect(restored.decisionRecords.single.observation, 'Held the position.');
  });

  test('closeTrade rejects a draft trade', () async {
    final execution = createExecution('execution-close-draft');

    await importExecution(execution);

    const tradeId = TradeId('trade-close-draft');

    await repository.createDraftRealTrade(
      tradeId: tradeId,

      executionIds: [execution.id],
    );

    await expectLater(
      repository.closeTrade(
        tradeId: tradeId,

        closedAt: DateTime(2026, 10, 10, 11),
      ),

      throwsStateError,
    );

    final restored = await repository.getTrade(tradeId);

    expect(restored, isNotNull);

    expect(restored!.status, TradeStatus.draft);

    expect(restored.closedAt, isNull);
  });

  test('closeTrade rejects an already-closed trade', () async {
    const tradeId = TradeId('trade-close-twice');

    await createConfirmedTradeWithState(
      tradeId: tradeId,

      executionId: 'execution-close-twice',

      stateId: 'state-close-twice',
    );

    final firstClosedAt = DateTime(2026, 10, 10, 11);

    await repository.closeTrade(tradeId: tradeId, closedAt: firstClosedAt);

    await expectLater(
      repository.closeTrade(
        tradeId: tradeId,

        closedAt: DateTime(2026, 10, 10, 12),
      ),

      throwsStateError,
    );

    final restored = await repository.getTrade(tradeId);

    expect(restored, isNotNull);

    expect(restored!.status, TradeStatus.closed);

    expect(restored.closedAt, firstClosedAt);
  });

  test('closeTrade rejects an unknown trade', () async {
    await expectLater(
      repository.closeTrade(
        tradeId: const TradeId('missing-trade'),

        closedAt: DateTime(2026, 10, 10, 11),
      ),

      throwsStateError,
    );

    expect(await database.query('trades'), isEmpty);
  });
}
