import '../trading/execution/execution.dart';
import '../trading/position_state/position_state.dart';
import '../trading/decision/decision_record.dart';
import 'strategy_structure.dart';
import 'trade_id.dart';
import 'trade_status.dart';
import 'trade_mode.dart';

class Trade {
  final TradeId id;
  final List<Execution> executions;
  final List<PositionState> positionStates;
  final StrategyStructure strategy;
  final TradeStatus status;
  final DateTime? confirmedAt;
  final DateTime? closedAt;
  final List<DecisionRecord> decisionRecords;
  final TradeMode mode;

  Trade({
    required this.id,
    required this.mode,
    required List<Execution> executions,
    List<PositionState> positionStates = const [],
    this.strategy = StrategyStructure.unknown,
    this.status = TradeStatus.draft,
    this.confirmedAt,
    this.closedAt,
    List<DecisionRecord> decisionRecords = const [],
  }) : executions = List.unmodifiable(executions),
       positionStates = List.unmodifiable(positionStates),
       decisionRecords = List.unmodifiable(decisionRecords) {
    if (this.executions.isEmpty) {
      throw ArgumentError('A trade must contain at least one execution.');
    }

    if (status == TradeStatus.draft &&
        (this.positionStates.isNotEmpty || this.decisionRecords.isNotEmpty)) {
      throw ArgumentError(
        'A draft trade cannot contain position states or decision records.',
      );
    }

    if (status == TradeStatus.confirmed && confirmedAt == null) {
      throw ArgumentError(
        'A confirmed trade must have a confirmation timestamp.',
      );
    }

    if (status == TradeStatus.closed && closedAt == null) {
      throw ArgumentError('A closed trade must have a closing timestamp.');
    }

    for (final state in this.positionStates) {
      if (state.tradeId != id.value) {
        throw ArgumentError('Every position state must belong to this trade.');
      }
    }

    for (final decision in this.decisionRecords) {
      final hasReferencedState = this.positionStates.any(
        (state) => state.id == decision.positionStateId,
      );

      if (!hasReferencedState) {
        throw ArgumentError(
          'Every decision must reference a position state belonging to this trade.',
        );
      }
    }
  }

  double get netPremium {
    var value = 0.0;

    for (final execution in executions) {
      final signedValue = execution.notional;

      value += execution.side == ExecutionSide.sell
          ? signedValue
          : -signedValue;
    }

    return value;
  }

  Trade confirm({
    required StrategyStructure strategy,
    required DateTime confirmedAt,
  }) {
    if (status != TradeStatus.draft) {
      throw StateError('Only a draft trade can be confirmed.');
    }

    if (strategy == StrategyStructure.unknown) {
      throw ArgumentError(
        'A trade cannot be confirmed with an unknown strategy.',
      );
    }

    return Trade(
      id: id,
      executions: executions,
      positionStates: const [],
      decisionRecords: const [],
      strategy: strategy,
      status: TradeStatus.confirmed,
      confirmedAt: confirmedAt,
      mode: mode,
    );
  }

  Trade capturePositionState(PositionState state) {
    if (status != TradeStatus.confirmed) {
      throw StateError('Only a confirmed trade can capture a position state.');
    }

    if (state.tradeId != id.value) {
      throw StateError('Position state belongs to a different trade.');
    }

    if (positionStates.any((existing) => existing.id == state.id)) {
      throw StateError(
        'A position state with this ID already exists in the trade.',
      );
    }

    return Trade(
      id: id,
      executions: executions,
      positionStates: [...positionStates, state],
      decisionRecords: decisionRecords,
      strategy: strategy,
      status: status,
      confirmedAt: confirmedAt,
      closedAt: closedAt,
      mode: mode,
    );
  }

  Trade recordDecision(DecisionRecord decision) {
    if (status != TradeStatus.confirmed) {
      throw StateError('Only a confirmed trade can record a decision.');
    }

    final hasReferencedState = positionStates.any(
      (state) => state.id == decision.positionStateId,
    );

    if (!hasReferencedState) {
      throw StateError(
        'Decision must reference a position state belonging to this trade.',
      );
    }

    return Trade(
      id: id,
      executions: executions,
      positionStates: positionStates,
      decisionRecords: [...decisionRecords, decision],
      strategy: strategy,
      status: status,
      confirmedAt: confirmedAt,
      closedAt: closedAt,
      mode: mode,
    );
  }

  Trade close({required DateTime closedAt}) {
    if (status != TradeStatus.confirmed) {
      throw StateError('Only a confirmed trade can be closed.');
    }

    return Trade(
      id: id,
      executions: executions,
      positionStates: positionStates,
      decisionRecords: decisionRecords,
      strategy: strategy,
      status: TradeStatus.closed,
      confirmedAt: confirmedAt,
      closedAt: closedAt,
      mode: mode,
    );
  }
}
