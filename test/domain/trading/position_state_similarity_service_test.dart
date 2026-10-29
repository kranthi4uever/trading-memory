import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trade/strategy_structure.dart';
import 'package:trading_memory/domain/trade/trade.dart';
import 'package:trading_memory/domain/trade/trade_id.dart';
import 'package:trading_memory/domain/trade/trade_mode.dart';
import 'package:trading_memory/domain/trading/execution/execution.dart';
import 'package:trading_memory/domain/trading/execution/execution_id.dart';
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
import 'package:trading_memory/domain/trading/position_state_similarity_service.dart';

void main() {
  group('PositionStateSimilarityService', () {
    test('matches an adjusted bull put snapshot inside a closed iron condor trade', () {
      final current = _state(
        tradeId: 'open-current',
        stateId: 'current',
        strategy: StrategyStructure.bullPutSpread,
        legs: [
          _leg(22500, OptionType.put, PositionSide.buy),
          _leg(22600, OptionType.put, PositionSide.sell),
        ],
      );
      final historicalBefore = _state(
        tradeId: 'closed-history',
        stateId: 'before',
        strategy: StrategyStructure.ironCondor,
        legs: [
          _leg(22500, OptionType.put, PositionSide.buy),
          _leg(22600, OptionType.put, PositionSide.sell),
          _leg(22700, OptionType.call, PositionSide.sell),
          _leg(22800, OptionType.call, PositionSide.buy),
        ],
      );
      final historicalAfter = _state(
        tradeId: 'closed-history',
        stateId: 'after',
        strategy: StrategyStructure.bullPutSpread,
        legs: [
          _leg(22500, OptionType.put, PositionSide.buy),
          _leg(22600, OptionType.put, PositionSide.sell),
        ],
      );
      final history = _closedTrade(
        id: 'closed-history',
        states: [historicalBefore, historicalAfter],
        originalStrategy: StrategyStructure.ironCondor,
      );

      final matches = const PositionStateSimilarityService().findMatches(
        current: current,
        trades: [history],
      );

      expect(matches, hasLength(2));
      expect(matches.first.state.id.value, 'after');
      expect(matches.first.trade.strategy, StrategyStructure.ironCondor);
      expect(matches.first.score, greaterThan(matches.last.score));
      expect(matches.first.factors.any((factor) => factor.name == 'DTE'), isTrue);
    });

    test('does not match same trade, open history, or another underlying', () {
      final current = _state(
        tradeId: 'current',
        stateId: 'current-state',
        strategy: StrategyStructure.bullPutSpread,
        legs: [_leg(22500, OptionType.put, PositionSide.buy)],
      );
      final sameTrade = _closedTrade(
        id: 'current',
        states: [_state(tradeId: 'current', stateId: 'same', strategy: StrategyStructure.bullPutSpread, legs: [_leg(22500, OptionType.put, PositionSide.buy)])],
      );
      final matches = const PositionStateSimilarityService().findMatches(
        current: current,
        trades: [sameTrade],
      );
      expect(matches, isEmpty);
    });
  });
}

PositionLeg _leg(int strike, OptionType type, PositionSide side) => PositionLeg(
  contract: OptionContract(
    underlying: 'NIFTY',
    expiry: ExpiryDate(2026, 11, 5),
    strike: strike,
    optionType: type,
  ),
  side: side,
  quantity: 50,
  entryPremium: 50,
  marketPrice: 40,
);

PositionState _state({
  required String tradeId,
  required String stateId,
  required StrategyStructure strategy,
  required List<PositionLeg> legs,
}) => PositionState(
  id: PositionStateId(stateId),
  tradeId: tradeId,
  capturedAt: DateTime(2026, 10, 27, 10),
  position: PositionSnapshot(
    underlying: 'NIFTY',
    expiry: ExpiryDate(2026, 11, 5),
    legs: legs,
    strategy: strategy,
  ),
  market: const MarketSnapshot(spot: 22600, vix: 16, atmStraddle: 250),
  geometry: const GeometrySnapshot(
    lowerBreakeven: 0,
    upperBreakeven: 0,
    wingWidth: 100,
    distanceToLowerBreakeven: 100,
    distanceToUpperBreakeven: 100,
    profitRange: 200,
  ),
  economics: const EconomicSnapshot(
    pnl: -500,
    pnlPercentage: -1,
    capitalDeployed: 10000,
    margin: 10000,
    cost: 50,
  ),
  risk: const RiskSnapshot(
    maxProfit: 2000,
    maxLoss: -3000,
    delta: 0,
    gamma: 0,
    theta: 0,
    vega: 0,
    iv: 16,
  ),
);

Trade _closedTrade({
  required String id,
  required List<PositionState> states,
  StrategyStructure originalStrategy = StrategyStructure.bullPutSpread,
}) {
  final expiry = ExpiryDate(2026, 11, 5);
  final execution = Execution(
    id: ExecutionId('exec-$id'),
    executedAt: DateTime(2026, 10, 20, 10),
    contract: OptionContract(
      underlying: 'NIFTY',
      expiry: expiry,
      strike: 22600,
      optionType: OptionType.put,
    ),
    side: ExecutionSide.sell,
    source: ExecutionSource.manual,
    quantity: 50,
    price: 50,
  );
  var trade = Trade(
    id: TradeId(id),
    mode: TradeMode.paper,
    executions: [execution],
  ).confirm(strategy: originalStrategy, confirmedAt: DateTime(2026, 10, 20, 10));
  for (final state in states) {
    trade = trade.capturePositionState(state);
  }
  return trade.close(closedAt: DateTime(2026, 10, 28));
}
