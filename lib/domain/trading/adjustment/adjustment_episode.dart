import '../decision/decision_record.dart';
import 'adjustment_reason.dart';
import 'position_view_assessment.dart';

enum AdjustmentEpisodeStatus { proposed, pendingConfirmation, pendingExecution, applied, partiallyApplied, failed, cancelled }

/// Durable link between the position before an adjustment, the user's action,
/// the resulting state, and executions. IDs reference the existing ledger.
class AdjustmentEpisode {
  final String id;
  final String tradeId;
  final String beforePositionStateId;
  final String? afterPositionStateId;
  final PositionViewAssessment beforeView;
  final PositionViewAssessment? afterView;
  final AdjustmentReason reason;
  final String? reasonNote;
  final String? selectedProposalId;
  final DecisionRecord? decision;
  final List<String> executionIds;
  final DateTime createdAt;
  final DateTime? confirmedAt;
  final AdjustmentEpisodeStatus status;
  final String? failureMessage;

  AdjustmentEpisode({
    required this.id,
    required this.tradeId,
    required this.beforePositionStateId,
    this.afterPositionStateId,
    required this.beforeView,
    this.afterView,
    required this.reason,
    this.reasonNote,
    this.selectedProposalId,
    this.decision,
    List<String> executionIds = const [],
    required this.createdAt,
    this.confirmedAt,
    this.status = AdjustmentEpisodeStatus.proposed,
    this.failureMessage,
  }) : executionIds = List.unmodifiable(executionIds) {
    if (id.trim().isEmpty || tradeId.trim().isEmpty || beforePositionStateId.trim().isEmpty) {
      throw ArgumentError('Episode, trade and before-state IDs are required.');
    }
    if (status == AdjustmentEpisodeStatus.applied && afterPositionStateId == null) {
      throw ArgumentError('An applied episode must link to its resulting position state.');
    }
  }

  AdjustmentEpisode copyWith({
    String? afterPositionStateId,
    PositionViewAssessment? afterView,
    DecisionRecord? decision,
    List<String>? executionIds,
    DateTime? confirmedAt,
    AdjustmentEpisodeStatus? status,
    String? failureMessage,
  }) => AdjustmentEpisode(
    id: id,
    tradeId: tradeId,
    beforePositionStateId: beforePositionStateId,
    afterPositionStateId: afterPositionStateId ?? this.afterPositionStateId,
    beforeView: beforeView,
    afterView: afterView ?? this.afterView,
    reason: reason,
    reasonNote: reasonNote,
    selectedProposalId: selectedProposalId,
    decision: decision ?? this.decision,
    executionIds: executionIds ?? this.executionIds,
    createdAt: createdAt,
    confirmedAt: confirmedAt ?? this.confirmedAt,
    status: status ?? this.status,
    failureMessage: failureMessage ?? this.failureMessage,
  );
}
