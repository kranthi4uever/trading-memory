import 'execution.dart';
import '../../trade/trade_id.dart';
import 'execution_source.dart';

class ExecutionInboxEntry {
  final Execution execution;
  final TradeId? assignedTradeId;
  final DateTime receivedAt;

  ExecutionInboxEntry({
    required this.execution,
    required this.receivedAt,
    this.assignedTradeId,
  }) {
    if (execution.source != ExecutionSource.broker) {
      throw ArgumentError(
        'Only broker-sourced executions can enter the execution inbox.',
      );
    }
  }
  bool get isUnassigned => assignedTradeId == null;

  ExecutionInboxEntry assignTo({required TradeId tradeId}) {
    if (!isUnassigned) {
      throw StateError('Execution has already been assigned to a trade.');
    }

    return ExecutionInboxEntry(
      execution: execution,
      receivedAt: receivedAt,
      assignedTradeId: tradeId,
    );
  }
}
