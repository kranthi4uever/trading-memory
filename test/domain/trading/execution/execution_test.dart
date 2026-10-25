import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trading/execution/execution.dart';
import 'package:trading_memory/domain/trading/execution/execution_id.dart';
import 'package:trading_memory/domain/trading/execution/execution_source.dart';
import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/execution/option_contract.dart';

void main() {
  group('Execution', () {
    Execution createExecution({
      ExecutionSource source = ExecutionSource.manual,
      int quantity = 50,
      double price = 100.0,
      String? brokerTradeId,
      String? brokerOrderId,
    }) {
      return Execution(
        id: ExecutionId('execution-1'),
        executedAt: DateTime(2026, 10, 10, 9, 30),
        contract: OptionContract(
          underlying: 'NIFTY',
          expiry: ExpiryDate(2026, 10, 13),
          strike: 25000,
          optionType: OptionType.call,
        ),
        side: ExecutionSide.buy,
        source: source,
        quantity: quantity,
        price: price,
        brokerTradeId: brokerTradeId,
        brokerOrderId: brokerOrderId,
      );
    }

    test('creates a valid manually entered execution', () {
      final execution = createExecution();

      expect(execution.source, ExecutionSource.manual);
      expect(execution.quantity, 50);
      expect(execution.price, 100.0);
      expect(execution.brokerTradeId, isNull);
      expect(execution.brokerOrderId, isNull);
    });

    test('calculates notional', () {
      final execution = createExecution();

      expect(execution.notional, 5000.0);
    });

    test('rejects zero quantity', () {
      expect(() => createExecution(quantity: 0), throwsArgumentError);
    });

    test('rejects negative quantity', () {
      expect(() => createExecution(quantity: -1), throwsArgumentError);
    });

    test('rejects negative price', () {
      expect(() => createExecution(price: -1), throwsArgumentError);
    });

    test('rejects NaN price', () {
      expect(() => createExecution(price: double.nan), throwsArgumentError);
    });

    test('rejects infinite price', () {
      expect(
        () => createExecution(price: double.infinity),
        throwsArgumentError,
      );
    });

    test('allows zero price', () {
      final execution = createExecution(price: 0);

      expect(execution.price, 0);
      expect(execution.notional, 0);
    });

    test('rejects a blank broker trade ID', () {
      expect(() => createExecution(brokerTradeId: '   '), throwsArgumentError);
    });

    test('rejects a blank broker order ID', () {
      expect(() => createExecution(brokerOrderId: '   '), throwsArgumentError);
    });

    test('rejects broker source without broker identifiers', () {
      expect(
        () => createExecution(source: ExecutionSource.broker),
        throwsArgumentError,
      );
    });

    test('accepts broker source with a broker trade ID', () {
      final execution = createExecution(
        source: ExecutionSource.broker,
        brokerTradeId: 'broker-trade-123',
      );

      expect(execution.source, ExecutionSource.broker);
      expect(execution.brokerTradeId, 'broker-trade-123');
    });

    test('accepts broker source with a broker order ID', () {
      final execution = createExecution(
        source: ExecutionSource.broker,
        brokerOrderId: 'broker-order-123',
      );

      expect(execution.source, ExecutionSource.broker);
      expect(execution.brokerOrderId, 'broker-order-123');
    });
  });
}
