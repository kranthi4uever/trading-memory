class RiskSnapshot {
  final double? maxProfit;
  final double? maxLoss;
  final double? delta;
  final double? gamma;
  final double? theta;
  final double? vega;
  final double? iv;

  const RiskSnapshot({
    required this.maxProfit,
    required this.maxLoss,
    required this.delta,
    required this.gamma,
    required this.theta,
    required this.vega,
    required this.iv,
  });
}
