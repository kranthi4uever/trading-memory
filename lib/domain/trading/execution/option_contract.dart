import 'expiry_date.dart';

enum OptionType { call, put }

class OptionContract {
  final String underlying; //NIFTY
  final ExpiryDate expiry; //2023-06-29
  final int strike; //15000
  final OptionType optionType;

  const OptionContract({
    required this.underlying,
    required this.expiry,
    required this.strike,
    required this.optionType,
  });
}
