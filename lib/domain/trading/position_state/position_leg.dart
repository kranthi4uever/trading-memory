import '../execution/option_contract.dart';

enum PositionSide { buy, sell }

class PositionLeg {
  final OptionContract contract;
  final PositionSide side;
  final int quantity;
  final double? entryPremium;
  final double? marketPrice;

  const PositionLeg({
    required this.contract,
    required this.side,
    required this.quantity,
    this.entryPremium,
    this.marketPrice,
  });
}
