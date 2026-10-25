import 'package:flutter_test/flutter_test.dart';

import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/position_state/economic_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/geometry_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/market_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/position_leg.dart';
import 'package:trading_memory/domain/trading/position_state/position_snapshot.dart';
import 'package:trading_memory/domain/trading/position_state/position_state.dart';
import 'package:trading_memory/domain/trading/position_state/position_state_id.dart';
import 'package:trading_memory/domain/trading/position_state/risk_snapshot.dart';
import 'package:trading_memory/domain/trade/strategy_structure.dart';

void main() {
  group('PositionState', () {
    test('stores complete position state information', () {
      final capturedAt = DateTime(2026, 10, 7, 12, 18);

      final position = PositionSnapshot(
        underlying: 'NIFTY',
        expiry: ExpiryDate(2026, 10, 29),
        legs: const <PositionLeg>[],
        strategy: StrategyStructure.neutralButterfly,
      );

      const market = MarketSnapshot(spot: 23680, vix: 14.2, atmStraddle: 315);

      const geometry = GeometrySnapshot(
        lowerBreakeven: 23050,
        upperBreakeven: 23650,
        wingWidth: 200,
        distanceToLowerBreakeven: 630,
        distanceToUpperBreakeven: -30,
        profitRange: 600,
      );

      const economics = EconomicSnapshot(
        pnl: -1420,
        pnlPercentage: -1.2,
        capitalDeployed: 118000,
        margin: 118000,
        cost: 0,
      );

      const risk = RiskSnapshot(
        maxProfit: 8500,
        maxLoss: -11500,
        delta: -4.2,
        gamma: 0.01,
        theta: 820,
        vega: -120,
        iv: 14.2,
      );

      final state = PositionState(
        id: const PositionStateId('state-1'),
        tradeId: 'trade-1',
        capturedAt: capturedAt,
        position: position,
        market: market,
        geometry: geometry,
        economics: economics,
        risk: risk,
      );

      expect(state.id, const PositionStateId('state-1'));
      expect(state.tradeId, 'trade-1');
      expect(state.capturedAt, capturedAt);

      expect(state.position, same(position));
      expect(state.market, same(market));
      expect(state.geometry, same(geometry));
      expect(state.economics, same(economics));
      expect(state.risk, same(risk));
    });
  });
}
