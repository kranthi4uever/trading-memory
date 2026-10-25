class TradeId {
  final String value;
  const TradeId(this.value);

  @override
  bool operator ==(Object other) => other is TradeId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
