import 'adjustment_proposal.dart';
import 'position_view_assessment.dart';
import 'adjustment_episode.dart';
import 'adjustment_similarity_service.dart';
import '../position_state/position_state.dart';
import '../position_state/position_leg.dart';

/// Builds explainable candidates from the current position. These are proposals
/// only: this service never creates executions or mutates a PositionState.
class AdjustmentSuggestionService {
  final AdjustmentSimilarityService similarityService;
  const AdjustmentSuggestionService({
    this.similarityService = const AdjustmentSimilarityService(),
  });

  List<AdjustmentProposal> buildCandidates({
    required String tradeId,
    required PositionState state,
    required MarketView perspective,
    required DateTime now,
    List<AdjustmentEpisode> history = const [],
    Map<String, PositionState> historicalStates = const {},
  }) {
    if (state.position.legs.isEmpty) return const [];

    // Adjustment options must be grounded in an adjustment that was actually
    // applied in the user's history. Proposed/failed/cancelled episodes are
    // not candidate sources. Until an operation can be reconstructed from a
    // linked before/after state, it is evidence only, not an actionable option.
    final candidates = <AdjustmentProposal>[];
    for (final episode in history) {
      if (episode.tradeId == tradeId ||
          episode.beforeView.confirmedView != perspective ||
          (episode.status != AdjustmentEpisodeStatus.applied &&
              episode.status != AdjustmentEpisodeStatus.partiallyApplied) ||
          episode.afterPositionStateId == null) {
        continue;
      }
      final before = historicalStates[episode.beforePositionStateId];
      final after = historicalStates[episode.afterPositionStateId!];
      if (before == null || after == null ||
          !_samePositionStructure(state, before)) {
        continue;
      }
      final operations = _diff(before, after);
      if (operations.isEmpty) continue;
      final actionLabel = episode.decision?.action.name ?? 'adjustment';
      candidates.add(AdjustmentProposal(
        id: 'history-${episode.id}-${state.id.value}',
        tradeId: tradeId,
        sourcePositionStateId: state.id.value,
        perspective: perspective,
        title: 'Previously applied: ${_titleCase(actionLabel)}',
        explanation: 'Reconstructed from your applied historical adjustment. Open the source trade timeline to review the decision and what happened afterward. The operation is offered only because its recorded starting position matches this position structure.',
        operations: operations,
        precedentEpisodeIds: [episode.id],
        createdAt: now,
        assumptions: [
          if (operations.any((operation) => operation.assumedPrice == null))
            'Historical execution price is not carried forward as a current quote; confirm current prices in the existing review workflow.',
          'This is a historical precedent, not a claim that the outcome will repeat.',
        ],
      ));
    }
    candidates.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(candidates);
  }

  bool _samePositionStructure(PositionState current, PositionState historical) {
    final a = current.position.legs;
    final b = historical.position.legs;
    if (a.length != b.length ||
        current.position.underlying != historical.position.underlying ||
        current.position.expiry.toString() != historical.position.expiry.toString()) return false;
    final aKeys = a.map((leg) => '${_legKey(leg)}:${leg.quantity}').toList()..sort();
    final bKeys = b.map((leg) => '${_legKey(leg)}:${leg.quantity}').toList()..sort();
    return aKeys.join('|') == bKeys.join('|');
  }

  List<ProposedLegOperation> _diff(PositionState before, PositionState after) {
    final oldLegs = before.position.legs;
    final newLegs = after.position.legs;
    final operations = <ProposedLegOperation>[];
    final oldByKey = <String, PositionLeg>{for (final leg in oldLegs) _legKey(leg): leg};
    final newByKey = <String, PositionLeg>{for (final leg in newLegs) _legKey(leg): leg};

    for (final entry in oldByKey.entries) {
      final old = entry.value;
      final next = newByKey[entry.key];
      final nextQuantity = next?.quantity ?? 0;
      if (nextQuantity >= old.quantity) continue;
      final reduction = old.quantity - nextQuantity;
      operations.add(ProposedLegOperation(
        type: nextQuantity == 0
            ? ProposedLegOperationType.exitLeg
            : ProposedLegOperationType.reduceLegQuantity,
        contract: old.contract,
        existingLegKey: entry.key,
        side: old.side == PositionSide.buy ? 'sell' : 'buy',
        quantity: reduction,
        // Never reuse a historical premium as a live execution quote.
        assumedPrice: null,
      ));
    }

    for (final entry in newByKey.entries) {
      final next = entry.value;
      final old = oldByKey[entry.key];
      final oldQuantity = old?.quantity ?? 0;
      if (next.quantity <= oldQuantity) continue;
      final increase = next.quantity - oldQuantity;
      operations.add(ProposedLegOperation(
        type: old == null
            ? ProposedLegOperationType.addLeg
            : ProposedLegOperationType.increaseLegQuantity,
        contract: next.contract,
        existingLegKey: old == null ? null : entry.key,
        side: next.side.name,
        quantity: increase,
        assumedPrice: null,
      ));
    }
    return operations;
  }

  String _titleCase(String value) => value.isEmpty
      ? value
      : '${value[0].toUpperCase()}${value.substring(1)}';

  static String _legKey(PositionLeg leg) =>
      '${leg.contract.underlying}:${leg.contract.expiry}:${leg.contract.strike}:${leg.contract.optionType.name}:${leg.side.name}';
}
