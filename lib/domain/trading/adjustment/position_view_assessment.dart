/// The user's directional interpretation of the market at a specific point.
enum MarketView { bullish, bearish, neutral, uncertain }

/// Keeps the app's classification separate from the user's confirmed view.
class PositionViewAssessment {
  final String id;
  final String tradeId;
  final String positionStateId;
  final DateTime assessedAt;
  final MarketView suggestedView;
  final MarketView confirmedView;
  final double? confidence;
  final List<String> evidence;
  final String? correctionNote;

  PositionViewAssessment({
    required this.id,
    required this.tradeId,
    required this.positionStateId,
    required this.assessedAt,
    required this.suggestedView,
    required this.confirmedView,
    this.confidence,
    List<String> evidence = const [],
    this.correctionNote,
  }) : evidence = List.unmodifiable(evidence) {
    if (id.trim().isEmpty || tradeId.trim().isEmpty || positionStateId.trim().isEmpty) {
      throw ArgumentError('Assessment, trade and position-state IDs are required.');
    }
    if (confidence != null && (confidence! < 0 || confidence! > 1)) {
      throw ArgumentError.value(confidence, 'confidence', 'Must be between 0 and 1.');
    }
  }
}
