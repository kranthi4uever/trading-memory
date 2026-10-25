import 'economic_snapshot.dart';
import 'geometry_snapshot.dart';
import 'market_snapshot.dart';
import 'position_snapshot.dart';
import 'position_state_id.dart';
import 'risk_snapshot.dart';

class PositionState {
  final PositionStateId id;
  final String tradeId;
  final DateTime capturedAt;

  final PositionSnapshot position;
  final MarketSnapshot market;
  final GeometrySnapshot geometry;
  final EconomicSnapshot economics;
  final RiskSnapshot risk;

  const PositionState({
    required this.id,
    required this.tradeId,
    required this.capturedAt,
    required this.position,
    required this.market,
    required this.geometry,
    required this.economics,
    required this.risk,
  });
}
