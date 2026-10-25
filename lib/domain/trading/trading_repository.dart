import '../trade/strategy_structure.dart';
import '../trade/trade.dart';
import '../trade/trade_id.dart';
import 'decision/decision_record.dart';
import 'execution/execution.dart';
import 'execution/execution_id.dart';
import 'execution/execution_inbox_entry.dart';
import 'position_state/position_state.dart';
import 'adjustment/adjustment_episode.dart';

abstract interface class TradingRepository {
  Future<void> importBrokerExecution({required ExecutionInboxEntry entry});

  Future<List<ExecutionInboxEntry>> getUnassignedExecutions();

  Future<Trade> createDraftPaperTrade({
    required TradeId tradeId,
    required List<Execution> executions,
  });

  Future<Trade> updateDraftPaperTrade({
    required TradeId tradeId,
    required List<Execution> executions,
  });

  Future<Trade> createDraftRealTrade({
    required TradeId tradeId,
    required List<ExecutionId> executionIds,
  });

  Future<void> confirmTrade({
    required TradeId tradeId,
    required StrategyStructure strategy,
    required DateTime confirmedAt,
  });

  Future<Trade?> getTrade(TradeId tradeId);

  Future<List<Trade>> getTrades();

  /// Permanently deletes a draft, open, or closed trade and its position history.
  Future<void> deleteTrade(TradeId tradeId);

  Future<void> capturePositionState({
    required TradeId tradeId,
    required PositionState state,
  });

  Future<void> recordDecision({
    required TradeId tradeId,
    required DecisionRecord decision,
  });

  Future<void> appendPaperExecutions({
    required TradeId tradeId,
    required List<Execution> executions,
  });

  Future<void> closeTrade({
    required TradeId tradeId,
    required DateTime closedAt,
  });

  /// Persists adjustment learning history without duplicating position snapshots
  /// or executions. Saving an episode does not execute its proposed operations.
  Future<void> saveAdjustmentEpisode(AdjustmentEpisode episode);

  Future<List<AdjustmentEpisode>> getAdjustmentEpisodes(String tradeId);
}
