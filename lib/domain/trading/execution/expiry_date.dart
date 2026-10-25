class ExpiryDate {
  final DateTime value;

  ExpiryDate(int year, int month, int day) : value = DateTime(year, month, day);

  const ExpiryDate.fromDateTime(this.value);

  @override
  bool operator ==(Object other) => other is ExpiryDate && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value.toIso8601String().split('T').first;
}
