import 'execution_id.dart';
import '../../trade/trade_id.dart';

class ExecutionAssignment {
  final ExecutionId executionId;
  final TradeId tradeId;
  final DateTime assignedAt;

  const ExecutionAssignment({
    required this.executionId,
    required this.tradeId,
    required this.assignedAt,
  });
}
