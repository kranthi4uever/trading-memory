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
  }) {
    final legs = state.position.legs;
    if (legs.isEmpty) return const [];
    final relevant = history
        .where((episode) => episode.beforeView.confirmedView == perspective)
        .toList();
    final proposals = <AdjustmentProposal>[];

    // Candidate 1: reduce the existing position by closing one leg. User must
    // choose quantity/price on review; a null assumedPrice is intentional.
    final leg = legs.first;
    proposals.add(
      AdjustmentProposal(
        id: 'reduce-${state.id}-${perspective.name}',
        tradeId: tradeId,
        sourcePositionStateId: state.id.value,
        perspective: perspective,
        title: 'Reduce exposure by exiting a leg',
        explanation: 'Review a partial or full exit of an existing leg. This is a candidate, not a recommendation; check the resulting payoff and risk before confirming.',
        operations: [
          ProposedLegOperation(
            type: ProposedLegOperationType.exitLeg,
            contract: leg.contract,
            existingLegKey: _legKey(leg),
            side: leg.side == PositionSide.buy ? 'sell' : 'buy',
            quantity: leg.quantity,
            assumedPrice: leg.marketPrice,
          ),
        ],
        precedentEpisodeIds: relevant.map((e) => e.id).take(5).toList(),
        createdAt: now,
        assumptions: [
          if (leg.marketPrice == null)
            'Exit quote unavailable; enter/confirm price before applying.',
        ],
      ),
    );

    return proposals;
  }

  static String _legKey(PositionLeg leg) =>
      '${leg.contract.underlying}:${leg.contract.expiry}:${leg.contract.strike}:${leg.contract.optionType.name}:${leg.side.name}';
}
