import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trading/execution/option_contract.dart';
import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/position_state/position_leg.dart';
import 'package:trading_memory/domain/trading/position_state/position_snapshot.dart';
import 'package:trading_memory/domain/trade/strategy_structure.dart';

void main() {
  group('PositionSnapshot', () {
    test('captures the current position at a point in time', () {
      final expiry = ExpiryDate(2026, 10, 8);

      final call23500 = OptionContract(
        underlying: 'NIFTY',
        expiry: expiry,
        strike: 23500,
        optionType: OptionType.call,
      );

      final call23700 = OptionContract(
        underlying: 'NIFTY',
        expiry: expiry,
        strike: 23700,
        optionType: OptionType.call,
      );

      final snapshot = PositionSnapshot(
        underlying: 'NIFTY',
        expiry: expiry,
        legs: [
          PositionLeg(
            contract: call23500,
            side: PositionSide.sell,
            quantity: 50,
          ),
          PositionLeg(
            contract: call23700,
            side: PositionSide.buy,
            quantity: 50,
          ),
        ],
        strategy: StrategyStructure.bullPutSpread,
      );

      expect(snapshot.underlying, 'NIFTY');
      expect(snapshot.expiry, expiry);
      expect(snapshot.legs, hasLength(2));
      expect(snapshot.legs[0].quantity, 50);
      expect(snapshot.legs[1].quantity, 50);
      expect(snapshot.strategy, StrategyStructure.bullPutSpread);
      expect(snapshot.legs[0].side, PositionSide.sell);
      expect(snapshot.legs[1].side, PositionSide.buy);
    });

    test('keeps its own immutable leg list', () {
      final expiry = ExpiryDate(2026, 10, 8);

      final legs = <PositionLeg>[];

      final snapshot = PositionSnapshot(
        underlying: 'NIFTY',
        expiry: expiry,
        legs: legs,
        strategy: StrategyStructure.bullPutSpread,
      );

      legs.add(
        PositionLeg(
          contract: OptionContract(
            underlying: 'NIFTY',
            expiry: expiry,
            strike: 23500,
            optionType: OptionType.put,
          ),
          side: PositionSide.sell,
          quantity: 50,
        ),
      );

      expect(snapshot.legs, isEmpty);
    });
  });
}
