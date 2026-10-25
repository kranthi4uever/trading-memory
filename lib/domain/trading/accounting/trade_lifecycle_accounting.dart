import '../execution/execution.dart';
import '../execution/option_contract.dart';
import '../position_state/position_leg.dart';

/// Explicit quality labels prevent missing or estimated values being reported as actual.
enum AccountingStatus { actual, estimated, unavailable }

class LifecyclePnl {
  final double realizedGross;
  final double? unrealizedGross;
  final double? charges;
  final AccountingStatus realizedStatus;
  final AccountingStatus unrealizedStatus;
  final AccountingStatus chargesStatus;
  final double? grossTotal;
  final double? netTotal;
  final List<String> warnings;

  const LifecyclePnl({
    required this.realizedGross,
    required this.unrealizedGross,
    required this.charges,
    required this.realizedStatus,
    required this.unrealizedStatus,
    required this.chargesStatus,
    required this.grossTotal,
    required this.netTotal,
    required this.warnings,
  });
}

class _Key {
  const _Key(this.underlying, this.expiry, this.strike, this.type);
  final String underlying;
  final DateTime expiry;
  final int strike;
  final OptionType type;
  factory _Key.of(OptionContract c) => _Key(
    c.underlying.toUpperCase(),
    DateTime(c.expiry.value.year, c.expiry.value.month, c.expiry.value.day),
    c.strike,
    c.optionType,
  );
  @override
  bool operator ==(Object o) =>
      o is _Key &&
      underlying == o.underlying &&
      expiry == o.expiry &&
      strike == o.strike &&
      type == o.type;
  @override
  int get hashCode => Object.hash(underlying, expiry, strike, type);
}

class _Lot {
  _Lot(this.long, this.quantity, this.price);
  final bool long;
  int quantity;
  final double price;
}

/// Calculates realized P&L from the full execution ledger using FIFO matching.
/// Open-leg unrealized P&L is calculated from the snapshot's entry/market prices.
/// All quantities must be normalized to option units, not lots.
class TradeLifecycleAccounting {
  const TradeLifecycleAccounting();

  LifecyclePnl calculate({
    required List<Execution> executions,
    required List<PositionLeg> openLegs,
    double? charges,
    AccountingStatus chargesStatus = AccountingStatus.unavailable,
  }) {
    if (charges != null && (!charges.isFinite || charges < 0)) {
      throw ArgumentError.value(
        charges,
        'charges',
        'Must be finite and non-negative',
      );
    }
    final sorted = [...executions]
      ..sort((a, b) {
        final byTime = a.executedAt.compareTo(b.executedAt);
        return byTime != 0 ? byTime : a.id.value.compareTo(b.id.value);
      });
    final inventory = <_Key, List<_Lot>>{};
    var realized = 0.0;
    final warnings = <String>[];
    for (final fill in sorted) {
      final key = _Key.of(fill.contract);
      final lots = inventory.putIfAbsent(key, () => <_Lot>[]);
      var remaining = fill.quantity;
      final isLong = fill.side == ExecutionSide.buy;
      while (remaining > 0 && lots.isNotEmpty && lots.first.long != isLong) {
        final lot = lots.first;
        final matched = remaining < lot.quantity ? remaining : lot.quantity;
        realized += lot.long
            ? (fill.price - lot.price) * matched
            : (lot.price - fill.price) * matched;
        lot.quantity -= matched;
        remaining -= matched;
        if (lot.quantity == 0) lots.removeAt(0);
      }
      if (remaining > 0) lots.add(_Lot(isLong, remaining, fill.price));
    }

    // Mark-to-market uses the latest snapshot, not stale execution prices.
    final markByKey = <_Key, PositionLeg>{};
    for (final leg in openLegs) {
      markByKey[_Key.of(leg.contract)] = leg;
    }
    var unrealized = 0.0;
    var marksAvailable = true;
    for (final leg in openLegs) {
      final entry = leg.entryPremium;
      final mark = leg.marketPrice;
      if (entry == null ||
          mark == null ||
          !entry.isFinite ||
          !mark.isFinite ||
          entry < 0 ||
          mark < 0) {
        marksAvailable = false;
        warnings.add(
          'Unrealized P&L unavailable: an open leg has no valid entry premium or market price.',
        );
        continue;
      }
      unrealized +=
          (leg.side == PositionSide.buy ? mark - entry : entry - mark) *
          leg.quantity;
    }
    final unrealizedValue = marksAvailable ? unrealized : null;
    final gross = unrealizedValue == null ? null : realized + unrealizedValue;
    // When charges are not captured, retain gross P&L as the available net
    // figure rather than dropping the trade from portfolio performance. The
    // missing actualCharges value still tells the UI that this is unadjusted.
    final net = gross == null ? null : gross - (charges ?? 0);
    if (charges == null)
      warnings.add(
        'Charges were not recorded; net P&L uses gross P&L without a charges deduction.',
      );
    return LifecyclePnl(
      realizedGross: realized,
      unrealizedGross: unrealizedValue,
      charges: charges,
      realizedStatus: AccountingStatus.actual,
      unrealizedStatus: marksAvailable
          ? AccountingStatus.estimated
          : AccountingStatus.unavailable,
      chargesStatus: charges == null
          ? AccountingStatus.unavailable
          : chargesStatus,
      grossTotal: gross,
      netTotal: net,
      warnings: List.unmodifiable(warnings.toSet()),
    );
  }
}

class ClosedTradePerformanceInput {
  final String tradeId;
  final String strategy;
  final double? grossPnl;
  final double? netPnl;
  final double? actualCharges;
  const ClosedTradePerformanceInput({
    required this.tradeId,
    required this.strategy,
    required this.grossPnl,
    required this.netPnl,
    required this.actualCharges,
  });
}

class PortfolioLifecycleSummary {
  final int includedTrades;
  final int winners;
  final int losers;
  final int breakeven;
  final double grossPnl;
  final double netPnl;
  final double? averageWinner;
  final double? averageLoser;
  final double? winRatePercent;
  final double? actualCharges;
  final Map<String, double> netPnlByStrategy;
  final List<String> warnings;
  const PortfolioLifecycleSummary({
    required this.includedTrades,
    required this.winners,
    required this.losers,
    required this.breakeven,
    required this.grossPnl,
    required this.netPnl,
    required this.averageWinner,
    required this.averageLoser,
    required this.winRatePercent,
    required this.actualCharges,
    required this.netPnlByStrategy,
    required this.warnings,
  });

  factory PortfolioLifecycleSummary.fromClosedTrades(
    List<ClosedTradePerformanceInput> trades,
  ) {
    final valid = trades
        .where((t) => t.netPnl != null || t.grossPnl != null)
        .toList();
    double netOf(ClosedTradePerformanceInput t) => t.netPnl ?? t.grossPnl!;
    final values = valid.map(netOf).toList();
    final grossValues = valid.map((t) => t.grossPnl ?? netOf(t)).toList();
    final wins = values.where((v) => v > 0).toList();
    final losses = values.where((v) => v < 0).toList();
    final chargesKnown = trades.every((t) => t.actualCharges != null);
    final byStrategy = <String, double>{};
    for (final trade in valid) {
      byStrategy.update(
        trade.strategy,
        (v) => v + netOf(trade),
        ifAbsent: () => netOf(trade),
      );
    }
    return PortfolioLifecycleSummary(
      includedTrades: valid.length,
      winners: wins.length,
      losers: losses.length,
      breakeven: values.where((v) => v == 0).length,
      grossPnl: grossValues.fold<double>(0, (s, v) => s + v),
      netPnl: values.fold<double>(0, (s, v) => s + v),
      averageWinner: wins.isEmpty
          ? null
          : wins.reduce((a, b) => a + b) / wins.length,
      averageLoser: losses.isEmpty
          ? null
          : losses.reduce((a, b) => a + b) / losses.length,
      winRatePercent: values.isEmpty ? null : wins.length * 100 / values.length,
      actualCharges: chargesKnown
          ? trades.fold<double>(0, (s, t) => s + t.actualCharges!)
          : null,
      netPnlByStrategy: Map.unmodifiable(byStrategy),
      warnings: List.unmodifiable([
        if (valid.length != trades.length)
          '${trades.length - valid.length} closed trade(s) excluded because no realized P&L is available.',
        if (!chargesKnown) 'At least one closed trade has no recorded actual charges; its net P&L uses gross P&L without a charges deduction.',
      ]),
    );
  }
}
