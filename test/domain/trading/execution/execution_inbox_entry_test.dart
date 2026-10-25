import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trading/execution/execution.dart';
import 'package:trading_memory/domain/trading/execution/execution_id.dart';
import 'package:trading_memory/domain/trading/execution/execution_inbox_entry.dart';
import 'package:trading_memory/domain/trading/execution/execution_source.dart';
import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/execution/option_contract.dart';
import 'package:trading_memory/domain/trade/trade_id.dart';

void main() {
  group('ExecutionInboxEntry', () {
    Execution createBrokerExecution() {
      return Execution(
        id: ExecutionId('broker-execution-1'),
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
        brokerTradeId: 'broker-trade-1',
      );
    }

    test('starts unassigned', () {
      final entry = ExecutionInboxEntry(
        execution: createBrokerExecution(),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      expect(entry.isUnassigned, isTrue);
      expect(entry.assignedTradeId, isNull);
    });

    test('assigns an unassigned execution to a trade', () {
      final entry = ExecutionInboxEntry(
        execution: createBrokerExecution(),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      final assigned = entry.assignTo(tradeId: TradeId('trade-1'));

      expect(assigned.isUnassigned, isFalse);
      expect(assigned.assignedTradeId, TradeId('trade-1'));
      expect(assigned.execution.id, entry.execution.id);
      expect(assigned.receivedAt, entry.receivedAt);

      // The original entry remains unchanged.
      expect(entry.isUnassigned, isTrue);
    });

    test('rejects assigning an already assigned execution again', () {
      final entry = ExecutionInboxEntry(
        execution: createBrokerExecution(),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      ).assignTo(tradeId: TradeId('trade-1'));

      expect(
        () => entry.assignTo(tradeId: TradeId('trade-2')),
        throwsStateError,
      );
    });

    test('rejects a manually entered execution', () {
      final manualExecution = Execution(
        id: ExecutionId('manual-execution-1'),
        executedAt: DateTime(2026, 10, 10, 9, 30),
        contract: OptionContract(
          underlying: 'NIFTY',
          expiry: ExpiryDate(2026, 10, 13),
          strike: 25000,
          optionType: OptionType.call,
        ),
        side: ExecutionSide.buy,
        source: ExecutionSource.manual,
        quantity: 50,
        price: 100,
      );

      expect(
        () => ExecutionInboxEntry(
          execution: manualExecution,
          receivedAt: DateTime(2026, 10, 10, 9, 31),
        ),
        throwsArgumentError,
      );
    });
  });
}
