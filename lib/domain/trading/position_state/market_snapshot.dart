class MarketSnapshot {
  final double? spot;
  final double? vix;
  final double? atmStraddle;

  const MarketSnapshot({
    required this.spot,
    required this.vix,
    required this.atmStraddle,
  });
}
