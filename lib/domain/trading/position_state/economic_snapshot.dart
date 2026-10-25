class EconomicSnapshot {
  final double? pnl;
  final double? pnlPercentage;
  final double? capitalDeployed;
  final double? margin;
  final double? cost;

  /// Final-trade values. Null means not recorded/available, never zero by assumption.
  final double? grossRealizedPnl;
  /// Mark-to-market P&L on legs still open at this snapshot. Null means unavailable.
  final double? grossUnrealizedPnl;
  final double? actualCharges;
  final double? netRealizedPnl;
  final double? returnOnMarginPercentage;
  final double? actualRiskCommitted;
  final double? grossRMultiple;
  final double? netRMultiple;
  final double? maxMarginBlocked;
  final double? actualProfitTarget;

  const EconomicSnapshot({
    required this.pnl,
    required this.pnlPercentage,
    required this.capitalDeployed,
    required this.margin,
    required this.cost,
    this.grossRealizedPnl,
    this.grossUnrealizedPnl,
    this.actualCharges,
    this.netRealizedPnl,
    this.returnOnMarginPercentage,
    this.actualRiskCommitted,
    this.grossRMultiple,
    this.netRMultiple,
    this.maxMarginBlocked,
    this.actualProfitTarget,
  });
}
