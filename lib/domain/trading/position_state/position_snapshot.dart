import 'position_leg.dart';
import '../../trade/strategy_structure.dart';
import '../execution/expiry_date.dart';

class PositionSnapshot {
  final String underlying;
  final ExpiryDate expiry;
  final List<PositionLeg> legs;
  final StrategyStructure strategy;
  final double? entryDebitCredit;
  final String? comments;
  final String? plannedRules;

  PositionSnapshot({
    required this.underlying,
    required this.expiry,
    required List<PositionLeg> legs,
    required this.strategy,
    this.entryDebitCredit,
    this.comments,
    this.plannedRules,
  }) : legs = List.unmodifiable(legs);
}
