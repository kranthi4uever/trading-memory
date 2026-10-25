import '../position_state/position_state_id.dart';

enum DecisionAction { hold, adjust, exit, add, reduce, partialExit }

class DecisionRecord {
  final DateTime recordedAt;
  final PositionStateId positionStateId;
  final DecisionAction action;
  final String? observation;

  const DecisionRecord({
    required this.recordedAt,
    required this.positionStateId,
    required this.action,
    this.observation,
  });
}
