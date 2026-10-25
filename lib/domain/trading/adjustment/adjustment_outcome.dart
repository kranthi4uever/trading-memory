enum AdjustmentOutcomeStatus { pending, open, closed, unavailable }

/// Outcome summary is derived from the existing position snapshots and
/// lifecycle accounting; it must not independently rewrite accounting.
class AdjustmentOutcome {
  final String episodeId;
  final AdjustmentOutcomeStatus status;
  final DateTime? observedThrough;
  final double? grossRealizedPnl;
  final double? actualCharges;
  final double? netRealizedPnl;
  final double? maxAdverseDrawdown;
  final int? subsequentDecisionCount;
  final String? dataQualityNote;

  const AdjustmentOutcome({
    required this.episodeId,
    required this.status,
    this.observedThrough,
    this.grossRealizedPnl,
    this.actualCharges,
    this.netRealizedPnl,
    this.maxAdverseDrawdown,
    this.subsequentDecisionCount,
    this.dataQualityNote,
  });
}
