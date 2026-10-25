import 'package:flutter_test/flutter_test.dart';

import 'package:trading_memory/domain/trading/execution/execution.dart';
import 'package:trading_memory/domain/trading/execution/execution_id.dart';
import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/execution/option_contract.dart';

import 'package:trading_memory/domain/trade/strategy_structure.dart';
import 'package:trading_memory/domain/trade/trade.dart';
import 'package:trading_memory/domain/trade/trade_id.dart';
import 'package:trading_memory/domain/trade/trade_status.dart';
import 'package:trading_memory/domain/trading/decision/decision_record.dart';

import 'package:trading_memory/domain/trading/position_state/economic_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/geometry_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/market_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/position_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/position_state.dart';
import 'package:trading_memory/domain/trading/position_state/position_state_id.dart';
import 'package:trading_memory/domain/trading/position_state/risk_snapshot.dart';
import 'package:trading_memory/domain/trading/execution/execution_source.dart';
import 'package:trading_memory/domain/trade/trade_mode.dart';

void main() {
  group('Trade', () {
    test('groups executions without losing individual executions', () {
      final expiry = ExpiryDate(2026, 10, 25);

      final executions = [
        Execution(
          id: const ExecutionId('e1'),
          executedAt: DateTime(2026, 10, 1, 9, 42),
          contract: OptionContract(
            underlying: 'NIFTY',
            expiry: expiry,
            strike: 23500,
            optionType: OptionType.call,
          ),
          side: ExecutionSide.sell,
          source: ExecutionSource.manual,
          quantity: 50,
          price: 120,
        ),
        Execution(
          id: const ExecutionId('e2'),
          executedAt: DateTime(2026, 10, 1, 9, 43),
          contract: OptionContract(
            underlying: 'NIFTY',
            expiry: expiry,
            strike: 23700,
            optionType: OptionType.call,
          ),
          side: ExecutionSide.buy,
          source: ExecutionSource.manual,
          quantity: 50,
          price: 60,
        ),
        Execution(
          id: const ExecutionId('e3'),
          executedAt: DateTime(2026, 10, 1, 9, 45),
          contract: OptionContract(
            underlying: 'NIFTY',
            expiry: expiry,
            strike: 23500,
            optionType: OptionType.put,
          ),
          side: ExecutionSide.sell,
          source: ExecutionSource.manual,
          quantity: 50,
          price: 110,
        ),
        Execution(
          id: const ExecutionId('e4'),
          executedAt: DateTime(2026, 10, 1, 9, 46),
          contract: OptionContract(
            underlying: 'NIFTY',
            expiry: expiry,
            strike: 23300,
            optionType: OptionType.put,
          ),
          side: ExecutionSide.buy,
          source: ExecutionSource.manual,
          quantity: 50,
          price: 55,
        ),
      ];

      final trade = Trade(
        id: const TradeId('trade-1'),
        mode: TradeMode.real,
        executions: executions,
      );

      expect(trade.executions, hasLength(4));
      expect(trade.strategy, StrategyStructure.unknown);
      expect(trade.netPremium, 5750);
    });

    test('user can confirm the suggested strategy', () {
      final execution = Execution(
        id: const ExecutionId('e1'),
        executedAt: DateTime(2026, 10, 1, 9, 42),
        contract: OptionContract(
          underlying: 'NIFTY',
          expiry: ExpiryDate(2026, 10, 25),
          strike: 23500,
          optionType: OptionType.call,
        ),
        side: ExecutionSide.sell,
        source: ExecutionSource.manual,
        quantity: 50,
        price: 120,
      );

      final trade = Trade(
        id: const TradeId('trade-1'),
        mode: TradeMode.real,
        executions: [execution],
      );

      final confirmed = trade.confirm(
        strategy: StrategyStructure.neutralButterfly,
        confirmedAt: DateTime(2026, 10, 1, 9, 42),
      );

      expect(confirmed.strategy, StrategyStructure.neutralButterfly);

      // Original aggregate remains unchanged.
      expect(trade.strategy, StrategyStructure.unknown);
    });

    test('trade cannot be created without executions', () {
      expect(
        () => Trade(
          id: const TradeId('trade-1'),
          executions: [],
          mode: TradeMode.real,
        ),
        throwsArgumentError,
      );
    });

    test('new grouped trade starts as draft', () {
      final expiry = ExpiryDate(2026, 10, 25);

      final trade = Trade(
        id: const TradeId('trade-1'),
        mode: TradeMode.real,
        executions: [
          Execution(
            id: const ExecutionId('e1'),
            executedAt: DateTime(2026, 10, 1, 9, 42),
            contract: OptionContract(
              underlying: 'NIFTY',
              expiry: expiry,
              strike: 23500,
              optionType: OptionType.call,
            ),
            side: ExecutionSide.sell,
            source: ExecutionSource.manual,
            quantity: 50,
            price: 120,
          ),
        ],
      );

      expect(trade.status, TradeStatus.draft);
      expect(trade.confirmedAt, isNull);
    });

    test('user can confirm a draft trade', () {
      final expiry = ExpiryDate(2026, 10, 25);

      final trade = Trade(
        id: const TradeId('trade-1'),
        mode: TradeMode.real,
        executions: [
          Execution(
            id: const ExecutionId('e1'),
            executedAt: DateTime(2026, 10, 1, 9, 42),
            contract: OptionContract(
              underlying: 'NIFTY',
              expiry: expiry,
              strike: 23500,
              optionType: OptionType.call,
            ),
            side: ExecutionSide.sell,
            source: ExecutionSource.manual,
            quantity: 50,
            price: 120,
          ),
        ],
      );

      final confirmed = trade.confirm(
        strategy: StrategyStructure.neutralButterfly,
        confirmedAt: DateTime(2026, 10, 1, 9, 47),
      );

      expect(confirmed.status, TradeStatus.confirmed);
      expect(confirmed.strategy, StrategyStructure.neutralButterfly);
      expect(confirmed.confirmedAt, DateTime(2026, 10, 1, 9, 47));
    });
  });

  group('Position state capture', () {
    test('draft trade cannot capture a position state', () {
      final execution = Execution(
        id: const ExecutionId('e1'),
        executedAt: DateTime(2026, 10, 1, 9, 42),
        contract: OptionContract(
          underlying: 'NIFTY',
          expiry: ExpiryDate(2026, 10, 25),
          strike: 23500,
          optionType: OptionType.call,
        ),
        side: ExecutionSide.sell,
        source: ExecutionSource.manual,
        quantity: 50,
        price: 120,
      );

      final trade = Trade(
        id: const TradeId('trade-1'),
        mode: TradeMode.real,
        executions: [execution],
      );

      final state = _createPositionState(tradeId: 'trade-1');

      expect(() => trade.capturePositionState(state), throwsStateError);
    });

    test('confirmed trade can capture a position state', () {
      final execution = Execution(
        id: const ExecutionId('e1'),
        executedAt: DateTime(2026, 10, 1, 9, 42),
        contract: OptionContract(
          underlying: 'NIFTY',
          expiry: ExpiryDate(2026, 10, 25),
          strike: 23500,
          optionType: OptionType.call,
        ),
        side: ExecutionSide.sell,
        source: ExecutionSource.manual,
        quantity: 50,
        price: 120,
      );

      final trade = Trade(
        id: const TradeId('trade-1'),
        executions: [execution],
        mode: TradeMode.real,
      );

      final confirmed = trade.confirm(
        strategy: StrategyStructure.neutralButterfly,
        confirmedAt: DateTime(2026, 10, 1, 9, 47),
      );

      final state = _createPositionState(tradeId: 'trade-1');

      final updated = confirmed.capturePositionState(state);

      expect(updated.positionStates, hasLength(1));
      expect(updated.positionStates.first, same(state));

      // Original confirmed trade remains unchanged.
      expect(confirmed.positionStates, isEmpty);
    });
  });

  group('Decision history preservation', () {
    test('capturing another position state preserves existing decisions', () {
      // Arrange: create and confirm a trade.
      final execution = Execution(
        id: const ExecutionId('e-decision-test'),
        executedAt: DateTime(2026, 10, 1, 9, 42),
        contract: OptionContract(
          underlying: 'NIFTY',
          expiry: ExpiryDate(2026, 10, 25),
          strike: 23500,
          optionType: OptionType.call,
        ),
        side: ExecutionSide.sell,
        source: ExecutionSource.manual,
        quantity: 50,
        price: 120,
      );

      final trade = Trade(
        id: const TradeId('trade-1'),
        mode: TradeMode.real,
        executions: [execution],
      );

      final confirmed = trade.confirm(
        strategy: StrategyStructure.neutralButterfly,
        confirmedAt: DateTime(2026, 10, 1, 9, 47),
      );

      // Capture the first position state.
      final state1 = _createPositionState(tradeId: 'trade-1', id: 'state-1');

      final tradeWithState1 = confirmed.capturePositionState(state1);

      // Record a decision against the first state.
      final decision = DecisionRecord(
        recordedAt: DateTime(2026, 10, 1, 10, 15),
        positionStateId: state1.id,
        action: DecisionAction.hold,
        observation: 'Waiting for a possible reversal.',
      );

      final tradeWithDecision = tradeWithState1.recordDecision(decision);

      // Act: capture a second position state.
      final state2 = _createPositionState(tradeId: 'trade-1', id: 'state-2');

      final updated = tradeWithDecision.capturePositionState(state2);

      // Assert: both states and the original decision survive.
      expect(updated.positionStates, hasLength(2));
      expect(updated.positionStates[0], same(state1));
      expect(updated.positionStates[1], same(state2));

      expect(updated.decisionRecords, hasLength(1));
      expect(updated.decisionRecords.first, same(decision));

      // Immutable transitions leave previous Trade instances unchanged.
      expect(tradeWithState1.positionStates, hasLength(1));
      expect(tradeWithState1.decisionRecords, isEmpty);

      expect(tradeWithDecision.positionStates, hasLength(1));
      expect(tradeWithDecision.decisionRecords, hasLength(1));
    });
  });
}

PositionState _createPositionState({
  required String tradeId,
  String id = 'state-1',
}) {
  return PositionState(
    id: PositionStateId(id),
    tradeId: tradeId,
    capturedAt: DateTime(2026, 10, 1, 10, 15),
    position: PositionSnapshot(
      underlying: 'NIFTY',
      expiry: ExpiryDate(2026, 10, 25),
      legs: const [],
      strategy: StrategyStructure.neutralButterfly,
    ),
    market: const MarketSnapshot(spot: 23680, vix: 14.2, atmStraddle: 315),
    geometry: const GeometrySnapshot(
      lowerBreakeven: 23050,
      upperBreakeven: 23650,
      wingWidth: 200,
      distanceToLowerBreakeven: 630,
      distanceToUpperBreakeven: -30,
      profitRange: 600,
    ),
    economics: const EconomicSnapshot(
      pnl: -1420,
      pnlPercentage: -1.2,
      capitalDeployed: 118000,
      margin: 118000,
      cost: 0,
    ),
    risk: const RiskSnapshot(
      maxProfit: 8500,
      maxLoss: -11500,
      delta: -4.2,
      gamma: 0.01,
      theta: 820,
      vega: -120,
      iv: 14.2,
    ),
  );
}
