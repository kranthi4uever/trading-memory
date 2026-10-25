class ExecutionId {
  final String value;
  const ExecutionId(this.value);

  @override
  bool operator ==(Object other) =>
      other is ExecutionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
