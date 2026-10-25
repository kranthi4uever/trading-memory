import '../execution/option_contract.dart';
import '../position_state/position_state.dart';
import 'position_view_assessment.dart';

enum ProposedLegOperationType { addLeg, exitLeg, reduceLegQuantity, increaseLegQuantity, replaceLeg, rollLeg }

/// An operation proposed for review. This is not an execution and must not
/// mutate a position until the user confirms it through the application flow.
class ProposedLegOperation {
  final ProposedLegOperationType type;
  final OptionContract contract;
  final String? existingLegKey;
  final String side; // 'buy' or 'sell'; kept independent of UI labels.
  final int quantity;
  final double? assumedPrice;
  final String? replacesLegKey;

  const ProposedLegOperation({
    required this.type,
    required this.contract,
    this.existingLegKey,
    required this.side,
    required this.quantity,
    this.assumedPrice,
    this.replacesLegKey,
  }) : assert(side == 'buy' || side == 'sell'),
       assert(quantity > 0),
       assert(assumedPrice == null || assumedPrice >= 0);
}

class AdjustmentProposal {
  final String id;
  final String tradeId;
  final String sourcePositionStateId;
  final MarketView perspective;
  final String title;
  final String explanation;
  final List<ProposedLegOperation> operations;
  final List<String> precedentEpisodeIds;
  final DateTime createdAt;
  final DateTime? validUntil;
  final List<String> assumptions;

  AdjustmentProposal({
    required this.id,
    required this.tradeId,
    required this.sourcePositionStateId,
    required this.perspective,
    required this.title,
    required this.explanation,
    required List<ProposedLegOperation> operations,
    List<String> precedentEpisodeIds = const [],
    required this.createdAt,
    this.validUntil,
    List<String> assumptions = const [],
  }) : operations = List.unmodifiable(operations),
       precedentEpisodeIds = List.unmodifiable(precedentEpisodeIds),
       assumptions = List.unmodifiable(assumptions) {
    if (operations.isEmpty) throw ArgumentError('A proposal must contain at least one leg operation.');
    if (id.trim().isEmpty || tradeId.trim().isEmpty || sourcePositionStateId.trim().isEmpty) {
      throw ArgumentError('Proposal, trade and source-state IDs are required.');
    }
  }

  bool isValidAt(DateTime now) => validUntil == null || !now.isAfter(validUntil!);
}

/// Read-only input for comparing the current position with past episodes.
class AdjustmentContext {
  final PositionState state;
  final MarketView confirmedView;
  final DateTime evaluatedAt;
  final Map<String, double?> metrics;

  AdjustmentContext({
    required this.state,
    required this.confirmedView,
    required this.evaluatedAt,
    Map<String, double?> metrics = const {},
  }) : metrics = Map.unmodifiable(metrics);
}
