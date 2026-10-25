import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trading/position_state/position_state_id.dart';

void main() {
  group('PositionStateId', () {
    test('holds its value', () {
      const id = PositionStateId('state-001');

      expect(id.value, 'state-001');
    });

    test('two ids with the same value are equal', () {
      const first = PositionStateId('state-001');
      const second = PositionStateId('state-001');

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });

    test('two ids with different values are not equal', () {
      const first = PositionStateId('state-001');
      const second = PositionStateId('state-002');

      expect(first, isNot(second));
    });

    test('toString returns the underlying value', () {
      const id = PositionStateId('state-001');

      expect(id.toString(), 'state-001');
    });
  });
}
