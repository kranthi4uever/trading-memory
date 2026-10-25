enum AdjustmentReason {
  marketDirectionChanged,
  reduceDirectionalRisk,
  reduceLossOrDrawdown,
  protectOpenProfit,
  takePartialProfit,
  takePartialLoss,
  increaseDirectionalExposure,
  reduceMarginOrCapital,
  volatilityChanged,
  timeDecayOrExpiry,
  thesisInvalidated,
  other,
}

extension AdjustmentReasonLabel on AdjustmentReason {
  String get label => switch (this) {
    AdjustmentReason.marketDirectionChanged => 'Market direction changed',
    AdjustmentReason.reduceDirectionalRisk => 'Reduce directional risk',
    AdjustmentReason.reduceLossOrDrawdown => 'Reduce loss or drawdown',
    AdjustmentReason.protectOpenProfit => 'Protect open profit',
    AdjustmentReason.takePartialProfit => 'Take partial profit',
    AdjustmentReason.takePartialLoss => 'Take partial loss',
    AdjustmentReason.increaseDirectionalExposure => 'Increase directional exposure',
    AdjustmentReason.reduceMarginOrCapital => 'Reduce margin or capital',
    AdjustmentReason.volatilityChanged => 'Volatility changed',
    AdjustmentReason.timeDecayOrExpiry => 'Time decay or expiry',
    AdjustmentReason.thesisInvalidated => 'Original thesis invalidated',
    AdjustmentReason.other => 'Other',
  };
}
