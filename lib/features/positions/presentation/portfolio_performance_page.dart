import 'package:flutter/material.dart';

import '../../../domain/trade/trade.dart';
import '../../../domain/trade/trade_status.dart';
import '../../../domain/trading/accounting/trade_lifecycle_accounting.dart';
import '../../../domain/trading/trading_repository.dart';

class PortfolioPerformancePage extends StatefulWidget {
  const PortfolioPerformancePage({super.key, required this.repository});
  final TradingRepository repository;

  @override
  State<PortfolioPerformancePage> createState() =>
      _PortfolioPerformancePageState();
}

class _PortfolioPerformancePageState extends State<PortfolioPerformancePage> {
  late Future<List<Trade>> _trades;
  @override
  void initState() {
    super.initState();
    _trades = widget.repository.getTrades();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async =>
        setState(() => _trades = widget.repository.getTrades()),
    child: FutureBuilder<List<Trade>>(
      future: _trades,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load portfolio performance: ${snapshot.error}',
                ),
              ),
            ],
          );
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());
        final closed = snapshot.data!
            .where((t) => t.status == TradeStatus.closed)
            .toList();
        final inputs = closed.map((trade) {
          final states = [...trade.positionStates]
            ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
          final finalState = states.isEmpty ? null : states.last;
          final executionsGross = trade.executions.isEmpty
              ? null
              : trade.executions.fold<double>(
                  0,
                  (total, execution) =>
                      total +
                      execution.price *
                          execution.quantity *
                          (execution.side.name == 'sell' ? 1 : -1),
                );
          final grossPnl =
              finalState?.economics.grossRealizedPnl ?? executionsGross;
          // If no actual charges/net figure was recorded, use the available
          // gross realized P&L as the net fallback, while leaving charges null.
          final netPnl = finalState?.economics.netRealizedPnl ?? grossPnl;
          return ClosedTradePerformanceInput(
            tradeId: trade.id.value,
            strategy: finalState?.position.strategy.name ?? trade.strategy.name,
            grossPnl: grossPnl,
            netPnl: netPnl,
            actualCharges: finalState?.economics.actualCharges,
          );
        }).toList();
        final summary = PortfolioLifecycleSummary.fromClosedTrades(inputs);
        final fmt = (double? v) => v == null
            ? 'Unavailable'
            : '${v < 0 ? '-' : ''}₹${v.abs().toStringAsFixed(2)}';
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Portfolio performance',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'Closed trades only. Each trade is counted once, regardless of how many adjustments or snapshots it contains.',
            ),
            const SizedBox(height: 16),
            _metric(
              context,
              'Gross realized P&L',
              fmt(summary.grossPnl),
              'Before charges, from closed trades counted once',
            ),
            _metric(
              context,
              'Net realized P&L',
              fmt(summary.netPnl),
              'Uses recorded net P&L, or gross P&L when charges were not captured',
            ),
            _metric(
              context,
              'Closed trades counted',
              '${summary.includedTrades} / ${closed.length}',
              'Closed trades with available realized P&L are counted; missing charges are not assumed to be actual zero charges',
            ),
            _metric(
              context,
              'Win rate',
              summary.winRatePercent == null
                  ? 'Unavailable'
                  : '${summary.winRatePercent!.toStringAsFixed(1)}%',
              '${summary.winners} winners · ${summary.losers} losers · ${summary.breakeven} breakeven',
            ),
            _metric(
              context,
              'Average winner',
              fmt(summary.averageWinner),
              'Net P&L per winning trade (gross fallback when charges are missing)',
            ),
            _metric(
              context,
              'Average loser',
              fmt(summary.averageLoser),
              'Negative net P&L per losing trade (gross fallback when charges are missing)',
            ),
            _metric(
              context,
              'Actual charges',
              fmt(summary.actualCharges),
              'Only available when every closed trade has broker-confirmed actual charges',
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Net P&L by strategy',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (summary.netPnlByStrategy.isEmpty)
                      const Text(
                        'No closed trades have available realized P&L yet.',
                      ),
                    for (final e in summary.netPnlByStrategy.entries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(e.key),
                        trailing: Text(
                          fmt(e.value),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: e.value >= 0
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (summary.warnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Data quality',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      for (final warning in summary.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text('• $warning'),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'When actual charges are missing, net P&L falls back to gross realized P&L. Actual charges remain unavailable and are never reported as confirmed zero.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        );
      },
    ),
  );

  Widget _metric(
    BuildContext context,
    String title,
    String value,
    String subtitle,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}
