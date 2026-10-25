import 'execution.dart';
import 'execution_id.dart';
import 'execution_inbox_entry.dart';
import '../../trade/trade_id.dart';
import 'execution_source.dart';

class ExecutionInbox {
  final Map<ExecutionId, ExecutionInboxEntry> _entries;

  ExecutionInbox() : _entries = {};

  List<ExecutionInboxEntry> get unassignedEntries =>
      List.unmodifiable(_entries.values.where((entry) => entry.isUnassigned));

  void add({required Execution execution, required DateTime receivedAt}) {
    if (execution.source != ExecutionSource.broker) {
      throw ArgumentError(
        'Only broker-sourced executions can enter the inbox.',
      );
    }

    if (_entries.containsKey(execution.id)) {
      throw StateError('Execution already exists in the inbox.');
    }

    _entries[execution.id] = ExecutionInboxEntry(
      execution: execution,
      receivedAt: receivedAt,
    );
  }

  void assignToTrade({
    required ExecutionId executionId,
    required TradeId tradeId,
  }) {
    final entry = _entries[executionId];

    if (entry == null) {
      throw StateError('Execution does not exist in the inbox.');
    }

    if (!entry.isUnassigned) {
      throw StateError('Execution has already been assigned to a trade.');
    }

    _entries[executionId] = entry.assignTo(tradeId: tradeId);
  }
}
