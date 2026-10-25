import 'execution_id.dart';
import 'option_contract.dart';
import 'execution_source.dart';

enum ExecutionSide { buy, sell }

class Execution {
  final ExecutionId id;
  final DateTime executedAt;
  final OptionContract contract;
  final ExecutionSide side;
  final ExecutionSource source;
  final int quantity;
  final double price;
  final String? brokerTradeId;
  final String? brokerOrderId;

  Execution({
    required this.id,
    required this.executedAt,
    required this.contract,
    required this.side,
    required this.source,
    required this.quantity,
    required this.price,
    this.brokerTradeId,
    this.brokerOrderId,
  }) {
    if (quantity <= 0) {
      throw ArgumentError('Execution quantity must be greater than zero.');
    }

    if (!price.isFinite || price < 0) {
      throw ArgumentError('Execution price must be finite and non-negative.');
    }

    if (brokerTradeId != null && brokerTradeId!.trim().isEmpty) {
      throw ArgumentError('Broker trade ID cannot be blank.');
    }

    if (brokerOrderId != null && brokerOrderId!.trim().isEmpty) {
      throw ArgumentError('Broker order ID cannot be blank.');
    }

    if (source == ExecutionSource.broker &&
        brokerTradeId == null &&
        brokerOrderId == null) {
      throw ArgumentError(
        'Broker-sourced executions must have a broker trade ID or order ID.',
      );
    }
  }

  double get notional => quantity * price;
}
