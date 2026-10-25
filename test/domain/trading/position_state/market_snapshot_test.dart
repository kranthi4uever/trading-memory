import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trading/position_state/market_snapshot.dart';

void main() {
  group('MarketSnapshot', () {
    test('stores market values', () {
      const snapshot = MarketSnapshot(spot: 23680, vix: 14.2, atmStraddle: 315);

      expect(snapshot.spot, 23680);
      expect(snapshot.vix, 14.2);
      expect(snapshot.atmStraddle, 315);
    });

    test('can be created as a const value', () {
      const snapshot = MarketSnapshot(spot: 23680, vix: 14.2, atmStraddle: 315);

      expect(snapshot, isA<MarketSnapshot>());
    });
  });
}
