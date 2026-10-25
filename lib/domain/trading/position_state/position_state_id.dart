class PositionStateId {
  final String value;

  const PositionStateId(this.value);

  @override
  bool operator ==(Object other) =>
      other is PositionStateId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
