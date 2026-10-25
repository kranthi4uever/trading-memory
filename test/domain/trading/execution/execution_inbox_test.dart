import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trading/execution/execution.dart';
import 'package:trading_memory/domain/trading/execution/execution_id.dart';
import 'package:trading_memory/domain/trading/execution/execution_inbox.dart';
import 'package:trading_memory/domain/trading/execution/execution_source.dart';
import 'package:trading_memory/domain/trading/execution/expiry_date.dart';
import 'package:trading_memory/domain/trading/execution/option_contract.dart';
import 'package:trading_memory/domain/trade/trade_id.dart';

void main() {
  group('ExecutionInbox', () {
    late ExecutionInbox inbox;

    setUp(() {
      inbox = ExecutionInbox();
    });

    Execution createBrokerExecution(String id) {
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
        brokerTradeId: 'broker-$id',
      );
    }

    test('new broker execution appears in the unassigned inbox', () {
      inbox.add(
        execution: createBrokerExecution('execution-1'),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      expect(inbox.unassignedEntries, hasLength(1));
      expect(
        inbox.unassignedEntries.single.execution.id,
        ExecutionId('execution-1'),
      );
    });

    test('assigned execution disappears from the unassigned inbox', () {
      inbox.add(
        execution: createBrokerExecution('execution-1'),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      inbox.assignToTrade(
        executionId: ExecutionId('execution-1'),
        tradeId: TradeId('trade-1'),
      );

      expect(inbox.unassignedEntries, isEmpty);
    });

    test('assigning one execution twice is rejected', () {
      inbox.add(
        execution: createBrokerExecution('execution-1'),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      inbox.assignToTrade(
        executionId: ExecutionId('execution-1'),
        tradeId: TradeId('trade-1'),
      );

      expect(
        () => inbox.assignToTrade(
          executionId: ExecutionId('execution-1'),
          tradeId: TradeId('trade-2'),
        ),
        throwsStateError,
      );

      expect(inbox.unassignedEntries, isEmpty);
    });

    test('importing the same execution ID twice is rejected', () {
      final execution = createBrokerExecution('execution-1');

      inbox.add(
        execution: execution,
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      expect(
        () => inbox.add(
          execution: execution,
          receivedAt: DateTime(2026, 10, 10, 9, 32),
        ),
        throwsStateError,
      );

      expect(inbox.unassignedEntries, hasLength(1));
    });

    test('assigning an unknown execution is rejected', () {
      expect(
        () => inbox.assignToTrade(
          executionId: ExecutionId('unknown-execution'),
          tradeId: TradeId('trade-1'),
        ),
        throwsStateError,
      );
    });

    test('manually entered executions cannot enter the broker inbox', () {
      final execution = Execution(
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
        () => inbox.add(
          execution: execution,
          receivedAt: DateTime(2026, 10, 10, 9, 31),
        ),
        throwsArgumentError,
      );

      expect(inbox.unassignedEntries, isEmpty);
    });

    test('unassigned entries are exposed as an unmodifiable list', () {
      inbox.add(
        execution: createBrokerExecution('execution-1'),
        receivedAt: DateTime(2026, 10, 10, 9, 31),
      );

      expect(() => inbox.unassignedEntries.clear(), throwsUnsupportedError);

      expect(inbox.unassignedEntries, hasLength(1));
    });
  });
}
