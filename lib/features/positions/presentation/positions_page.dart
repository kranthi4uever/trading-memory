import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/trade/trade.dart';
import '../../../domain/trading/execution/execution.dart';
import '../../../domain/trading/execution/option_contract.dart';
import '../../../domain/trading/decision/decision_record.dart';
import '../../../domain/trading/position_state/position_state.dart';
import '../../../domain/trading/position_state/position_snapshot.dart';
import '../../../domain/trading/position_state/position_leg.dart';
import '../../../domain/trading/position_state/position_state_id.dart';
import '../../../domain/trading/position_state/market_snapshot.dart';
import '../../../domain/trading/position_state/geometry_snapshot.dart';
import '../../../domain/trading/position_state/economic_snapshot.dart';
import '../../../domain/trading/position_state/risk_snapshot.dart';
import '../../../domain/trading/position_state_similarity_service.dart';
import '../../../domain/trading/execution/execution_id.dart';
import '../../../domain/trading/execution/execution_source.dart';
import '../../../domain/trading/execution/expiry_date.dart';
import '../../../domain/trade/trade_status.dart';
import '../../../domain/trade/trade_mode.dart';
import '../../../domain/trading/accounting/trade_lifecycle_accounting.dart';
import '../../../domain/trading/trading_repository.dart';
import '../../../domain/trading/adjustment/adjustment_proposal.dart';
import 'adjustment_assistant_page.dart';
import '../../market_data/presentation/nifty_option_chain_page.dart';

const _positionBrand = Color(0xFF176B87);
const _positionPageBackground = Color(0xFFF7F9FA);

String _dateLabel(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _dateTimeLabel(DateTime value) {
  final local = value.toLocal();
  return '${_dateLabel(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
}

class PositionsPage extends StatelessWidget {
  const PositionsPage({
    super.key,
    required this.trade,
    this.selectedState,
    this.selectedDecision,
    this.forceStaticPayoff = false,
    this.similarMatches = const [],
    this.repository,
  });
  final Trade trade;
  final TradingRepository? repository;
  final PositionState? selectedState;

  /// When opened from a decision event, show its rationale above the linked snapshot.
  final DecisionRecord? selectedDecision;

  /// Decision details are read-only even when they reference the latest state.
  final bool forceStaticPayoff;
  final List<SimilarPositionMatch> similarMatches;

  Future<void> _deleteTrade(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete position?'),
        content: Text(
          'Permanently delete this ${trade.status.name} position and its snapshots, decisions, and execution links? Broker execution records will be preserved. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || repository == null || !context.mounted) return;
    try {
      await repository!.deleteTrade(trade.id);
      if (context.mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete position: $error')),
      );
    }
  }

  String _money(double? value) =>
      value == null ? 'Unavailable' : '₹${value.toStringAsFixed(2)}';
  String _number(double? value, {String suffix = ''}) =>
      value == null ? 'Unavailable' : '${value.toStringAsFixed(2)}$suffix';

  @override
  Widget build(BuildContext context) {
    final history = [...trade.positionStates]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final latestState = history.isEmpty ? null : history.last;
    final state = selectedState ?? latestState;
    final isLatestState =
        state != null && latestState != null && state.id == latestState.id;
    // Payoff behavior is determined by the position state, not by how the
    // user navigated to it. The latest state of an open position is always
    // interactive, including when opened from a decision-linked timeline
    // event. Older states and all closed positions remain historical/static.
    // Keep forceStaticPayoff for constructor compatibility, but never let a
    // navigation flag override the latest-open-state rule.
    final canInteractWithPayoff =
        isLatestState &&
        trade.status != TradeStatus.closed &&
        state != null &&
        state.position.legs.isNotEmpty;
    final expiry =
        state?.position.expiry.value ??
        trade.executions.first.contract.expiry.value;
    final now =
        state?.capturedAt ??
        trade.confirmedAt ??
        trade.executions.first.executedAt;
    final dte = expiry
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final spot = state?.market.spot;
    double? distancePct(double? distance) =>
        distance == null || spot == null || spot == 0
        ? null
        : distance.abs() / spot.abs() * 100;
    // Root position screen is deliberately timeline-only. Snapshot taps open
    // a detail screen; that detail screen never renders another timeline.
    if (selectedState == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Position timeline'),
          backgroundColor: _positionPageBackground,
          actions: [
            if (repository != null)
              IconButton(
                tooltip: 'Delete position',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _deleteTrade(context),
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '${trade.executions.first.contract.underlying} · ${trade.mode.name.toUpperCase()}',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text(
              '${trade.status.name} · ${trade.strategy.name} · ${history.length} snapshots',
              style: const TextStyle(color: Colors.black54),
            ),
            if (trade.mode == TradeMode.paper &&
                trade.status == TradeStatus.confirmed &&
                latestState != null &&
                repository != null) ...[
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Position actions',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () => _addLegs(context, latestState),
                            icon: const Icon(Icons.add),
                            label: const Text('Add legs'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _editLegs(context, latestState),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Edit legs'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _exitLegs(context, latestState),
                            icon: const Icon(Icons.logout),
                            label: const Text('Exit legs'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                _holdPosition(context, latestState),
                            icon: const Icon(Icons.pause_circle_outline),
                            label: const Text('Hold'),
                          ),
                        ],
                      ),
                      const Divider(height: 22),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => AdjustmentAssistantPage(
                                trade: trade,
                                state: latestState,
                                repository: repository!,
                                onApplyProposal:
                                    (AdjustmentProposal proposal) async {
                                      Navigator.of(context).pop();
                                      // Keep the established confirmation workflow; do not
                                      // silently apply proposal legs as broker executions.
                                      await _exitLegs(context, latestState);
                                    },
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.psychology_alt_outlined),
                          label: const Text('Open Adjustment Assistant'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _SnapshotExpansion(
              title:
                  'Timeline:\n${history.length} ${history.length == 1 ? 'Snapshot' : 'Snapshots'}  ·  ${trade.decisionRecords.length} ${trade.decisionRecords.length == 1 ? 'Decision' : 'Decisions'}',
              initiallyExpanded: true,
              child: _PositionTimeline(
                trade: trade,
                selectedState: null,
                latestState: latestState,
              ),
            ),
            if (trade.status.name != 'closed') ...[
              const SizedBox(height: 4),
              _SnapshotExpansion(
                title: 'Similar trades · ${similarMatches.length}',
                child: similarMatches.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No comparable closed positions found yet.',
                        ),
                      )
                    : Column(
                        children: [
                          for (final item in similarMatches)
                            _SimilarTradeCard(match: item),
                        ],
                      ),
              ),
            ],
            const SizedBox(height: 4),
            _SnapshotExpansion(
              title: 'Executed trades · ${trade.executions.length}',
              child: _GroupedExecutions(trade: trade),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isLatestState
              ? 'Latest position snapshot'
              : 'Historical position snapshot',
        ),
        backgroundColor: _positionPageBackground,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${state?.position.underlying ?? trade.executions.first.contract.underlying} · ${trade.mode.name.toUpperCase()}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            '${isLatestState ? 'Latest saved state' : 'Read-only historical state'} · Status: ${trade.status.name} · Strategy: ${state?.position.strategy.name ?? trade.strategy.name}',
            style: const TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          if (selectedDecision != null) ...[
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.psychology_alt_outlined),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Decision · ${selectedDecision!.action.name.toUpperCase()}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const Icon(Icons.lock_outline, size: 18),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Recorded at ${_dateTimeLabel(selectedDecision!.recordedAt)}',
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Your observation',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      selectedDecision!.observation?.trim().isNotEmpty == true
                          ? selectedDecision!.observation!.trim()
                          : 'No note recorded.',
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Linked position snapshot below is the immutable state recorded for this decision.',
                      style: TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (state == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Snapshot unavailable',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'No saved position state exists yet. Confirm the draft to capture the initial state.',
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _SnapshotExpansion(
              title: 'Position details',
              initiallyExpanded: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SnapshotValue(
                    'Captured at',
                    _dateTimeLabel(state.capturedAt),
                  ),
                  _SnapshotValue('Expiry', _dateLabel(expiry)),
                  _SnapshotValue('DTE at capture', '$dte days'),
                  _SnapshotValue(
                    'Lower break-even',
                    _number(state.geometry.lowerBreakeven),
                  ),
                  _SnapshotValue(
                    'Upper break-even',
                    _number(state.geometry.upperBreakeven),
                  ),
                  _SnapshotValue(
                    'Distance to lower break-even',
                    _number(
                      state.geometry.distanceToLowerBreakeven,
                      suffix: ' pts',
                    ),
                  ),
                  _SnapshotValue(
                    'Distance to lower break-even (%)',
                    _number(
                      distancePct(state.geometry.distanceToLowerBreakeven),
                      suffix: '%',
                    ),
                  ),
                  _SnapshotValue(
                    'Distance to upper break-even',
                    _number(
                      state.geometry.distanceToUpperBreakeven,
                      suffix: ' pts',
                    ),
                  ),
                  _SnapshotValue(
                    'Distance to upper break-even (%)',
                    _number(
                      distancePct(state.geometry.distanceToUpperBreakeven),
                      suffix: '%',
                    ),
                  ),
                  const Divider(),
                  for (final leg in state.position.legs)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${leg.side.name.toUpperCase()} ${leg.contract.strike} ${leg.contract.optionType == OptionType.call ? 'CE' : 'PE'}',
                      ),
                      subtitle: Text(
                        '${leg.contract.underlying} · Expiry ${_dateLabel(leg.contract.expiry.value)} · Qty ${leg.quantity} · Entry ${leg.entryPremium == null ? 'Unavailable' : '₹${leg.entryPremium!.toStringAsFixed(2)}'} · LTP at capture ${leg.marketPrice == null ? 'Unavailable' : '₹${leg.marketPrice!.toStringAsFixed(2)}'}',
                      ),
                    ),
                ],
              ),
            ),
            _SnapshotExpansion(
              title: 'Charges and margin',
              child: Column(
                children: [
                  _SnapshotValue(
                    'Charges / costs',
                    _money(state.economics.cost),
                  ),
                  _SnapshotValue(
                    'Margin blocked',
                    _money(state.economics.margin),
                  ),
                  _SnapshotValue(
                    'Capital deployed',
                    _money(state.economics.capitalDeployed),
                  ),
                  const Text(
                    'Unknown values remain unavailable; they are not treated as zero.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
            _SnapshotExpansion(
              title: 'Trade economics and rules',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SnapshotValue(
                    'Entry straddle price',
                    _money(state.market.atmStraddle),
                  ),
                  _SnapshotValue(
                    'Entry debit / credit',
                    _money(state.position.entryDebitCredit),
                  ),
                  _SnapshotValue(
                    'Total gross P&L at capture',
                    _money(state.economics.pnl),
                  ),
                  _SnapshotValue(
                    'Realized gross P&L',
                    _money(state.economics.grossRealizedPnl),
                  ),
                  _SnapshotValue(
                    'Unrealized gross P&L',
                    _money(state.economics.grossUnrealizedPnl),
                  ),
                  _SnapshotValue(
                    'Actual charges to date',
                    _money(state.economics.actualCharges),
                  ),
                  _SnapshotValue(
                    'Final net realized P&L',
                    _money(state.economics.netRealizedPnl),
                  ),
                  _SnapshotValue(
                    'P&L percentage',
                    _number(state.economics.pnlPercentage, suffix: '%'),
                  ),
                  _SnapshotValue(
                    'Maximum profit',
                    _money(state.risk.maxProfit),
                  ),
                  _SnapshotValue('Maximum loss', _money(state.risk.maxLoss)),
                  _SnapshotValue(
                    'Committed risk',
                    'Unavailable — no configured percentage captured',
                  ),
                  _SnapshotValue(
                    'Committed profit',
                    'Unavailable — no configured percentage captured',
                  ),
                  _SnapshotValue('Spot at capture', _money(state.market.spot)),
                  _SnapshotValue('VIX at capture', _number(state.market.vix)),
                  const SizedBox(height: 8),
                  const Text(
                    'Comments',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    (state.position.comments?.trim().isNotEmpty ?? false)
                        ? state.position.comments!
                        : 'No comments recorded.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Planned rules',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    (state.position.plannedRules?.trim().isNotEmpty ?? false)
                        ? state.position.plannedRules!
                        : 'No planned rules recorded.',
                  ),
                  const Divider(),
                  const Text(
                    'Greeks captured with this state',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  _SnapshotValue('Delta', _number(state.risk.delta)),
                  _SnapshotValue('Gamma', _number(state.risk.gamma)),
                  _SnapshotValue('Theta', _number(state.risk.theta)),
                  _SnapshotValue('Vega', _number(state.risk.vega)),
                  _SnapshotValue(
                    'Implied volatility',
                    _number(state.risk.iv, suffix: '%'),
                  ),
                ],
              ),
            ),
            _SnapshotExpansion(
              title: canInteractWithPayoff
                  ? 'Interactive payoff & Greeks'
                  : 'Historical payoff',
              child: canInteractWithPayoff
                  ? _InteractivePositionPayoff(trade: trade, state: state)
                  : _StaticHistoricalPayoff(trade: trade, state: state),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _addLegs(BuildContext context, PositionState latest) async {
    final repo = repository;
    if (repo == null) return;
    final result = await Navigator.of(context)
        .push<List<NiftyOptionContractSelection>>(
          MaterialPageRoute(
            builder: (_) => NiftyOptionChainPage(
              initialExpiry: latest.position.expiry.value,
              existingLegs: latest.position.legs.map((leg) {
                return NiftyOptionContractSelection(
                  expiry: leg.contract.expiry.value,
                  strike: leg.contract.strike,
                  optionType: leg.contract.optionType,
                  tradingSymbol: '',
                  lotSize: 1,
                  side: leg.side == PositionSide.buy
                      ? ExecutionSide.buy
                      : ExecutionSide.sell,
                  quantity: leg.quantity,
                  entryPremium: leg.entryPremium,
                  lastPrice: leg.marketPrice,
                );
              }).toList(),
            ),
          ),
        );
    if (result == null || result.isEmpty || !context.mounted) return;
    final now = DateTime.now();
    final executions = <Execution>[];
    final addedLegs = <PositionLeg>[];
    for (var i = 0; i < result.length; i++) {
      final selection = result[i];
      final premium = selection.entryPremium;
      if (premium == null) {
        _message(
          context,
          'A quote is unavailable for ${selection.strike}. Enter a valid premium in the option chain and try again.',
          error: true,
        );
        return;
      }
      final contract = OptionContract(
        underlying: latest.position.underlying,
        expiry: ExpiryDate.fromDateTime(selection.expiry),
        strike: selection.strike,
        optionType: selection.optionType,
      );
      final side = selection.side == ExecutionSide.buy
          ? PositionSide.buy
          : PositionSide.sell;
      executions.add(
        Execution(
          id: ExecutionId('pm-${now.microsecondsSinceEpoch}-$i'),
          executedAt: now,
          contract: contract,
          side: selection.side,
          source: ExecutionSource.manual,
          quantity: selection.quantity,
          price: premium,
        ),
      );
      addedLegs.add(
        PositionLeg(
          contract: contract,
          side: side,
          quantity: selection.quantity,
          entryPremium: premium,
          marketPrice: selection.lastPrice,
        ),
      );
    }
    try {
      await repo.appendPaperExecutions(
        tradeId: trade.id,
        executions: executions,
      );
      await _captureUpdatedState(
        context,
        latest,
        [...latest.position.legs, ...addedLegs],
        DecisionAction.add,
        'Added ${addedLegs.length} leg(s).',
      );
    } catch (e) {
      if (context.mounted)
        _message(context, 'Could not add legs: $e', error: true);
    }
  }

  Future<void> _editLegs(BuildContext context, PositionState latest) async {
    final repo = repository;
    if (repo == null || latest.position.legs.isEmpty) return;
    final legs = latest.position.legs;
    final premiums = legs
        .map(
          (l) => TextEditingController(
            text: l.entryPremium?.toStringAsFixed(2) ?? '',
          ),
        )
        .toList();
    try {
      final save = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => _EditLegsForm(legs: legs, premiums: premiums),
        ),
      );
      if (save != true || !context.mounted) return;

      final updatedLegs = <PositionLeg>[];
      var changed = false;
      for (var i = 0; i < legs.length; i++) {
        final price = double.tryParse(premiums[i].text.trim());
        if (price == null || !price.isFinite || price < 0) {
          _message(
            context,
            'Enter a valid non-negative entry price for every leg.',
            error: true,
          );
          return;
        }
        final old = legs[i];
        if (price != old.entryPremium) changed = true;
        updatedLegs.add(
          PositionLeg(
            contract: old.contract,
            side: old.side,
            quantity: old.quantity,
            entryPremium: price,
            marketPrice: old.marketPrice,
          ),
        );
      }
      if (!changed) {
        _message(context, 'No price changes to save.');
        return;
      }

      // Editing a recorded price corrects the position snapshot only. It is not
      // a broker transaction, so do not fabricate closing/opening executions
      // and do not record an ADJUST decision.
      await _captureUpdatedState(
        context,
        latest,
        updatedLegs,
        DecisionAction.adjust,
        'Corrected recorded entry price(s).',
        recordDecision: false,
      );
    } catch (e) {
      if (context.mounted)
        _message(context, 'Could not edit leg prices: $e', error: true);
    } finally {
      for (final c in premiums) {
        c.dispose();
      }
    }
  }

  Future<void> _exitLegs(BuildContext context, PositionState latest) async {
    final repo = repository;
    if (repo == null || latest.position.legs.isEmpty) return;
    final legs = latest.position.legs;
    //    final selected = List<bool>.filled(legs.length, false);
    final quantities = legs
        .map((l) => TextEditingController(text: '${l.quantity}'))
        .toList();
    final prices = legs
        .map(
          (l) => TextEditingController(
            text: l.marketPrice?.toStringAsFixed(2) ?? '',
          ),
        )
        .toList();
    try {
      final result = await Navigator.of(context).push<List<_ExitLine>>(
        MaterialPageRoute(
          builder: (_) =>
              _ExitLegsForm(legs: legs, quantities: quantities, prices: prices),
        ),
      );
      if (result == null || result.isEmpty || !context.mounted) return;
      final now = DateTime.now();
      final executions = <Execution>[];
      final updated = [...legs];
      for (var i = 0; i < result.length; i++) {
        final line = result[i];
        final leg = legs[line.index];
        executions.add(
          Execution(
            id: ExecutionId('pm-${now.microsecondsSinceEpoch}-exit-$i'),
            executedAt: now,
            contract: leg.contract,
            side: leg.side == PositionSide.buy
                ? ExecutionSide.sell
                : ExecutionSide.buy,
            source: ExecutionSource.manual,
            quantity: line.quantity,
            price: line.price,
          ),
        );
        final remaining = leg.quantity - line.quantity;
        if (remaining == 0) {
          updated.removeWhere((x) => identical(x, leg));
        } else {
          final idx = updated.indexWhere((x) => identical(x, leg));
          updated[idx] = PositionLeg(
            contract: leg.contract,
            side: leg.side,
            quantity: remaining,
            entryPremium: leg.entryPremium,
            marketPrice: leg.marketPrice,
          );
        }
      }
      await repo.appendPaperExecutions(
        tradeId: trade.id,
        executions: executions,
      );
      await _captureUpdatedState(
        context,
        latest,
        updated,
        updated.isEmpty ? DecisionAction.exit : DecisionAction.partialExit,
        'Exited ${result.length} leg selection(s).',
        closeWhenEmpty: updated.isEmpty,
      );
    } catch (e) {
      if (context.mounted)
        _message(context, 'Could not record exit: $e', error: true);
    } finally {
      for (final c in quantities) {
        c.dispose();
      }
      for (final c in prices) {
        c.dispose();
      }
    }
  }

  Future<void> _holdPosition(BuildContext context, PositionState latest) async {
    // The required HOLD rationale is entered inline on the snapshot form.
    // Capture the same legs; HOLD must not create executions or alter the position.
    await _captureUpdatedState(
      context,
      latest,
      List<PositionLeg>.of(latest.position.legs),
      DecisionAction.hold,
      '',
    );
  }

  Future<void> _captureUpdatedState(
    BuildContext context,
    PositionState previous,
    List<PositionLeg> legs,
    DecisionAction action,
    String observation, {
    bool closeWhenEmpty = false,
    bool recordDecision = true,
  }) async {
    final repo = repository!;
    // Review point-in-time metrics before committing a new position state.
    // Blank fields stay unavailable; metrics from the prior state are never
    // copied forward because they may no longer describe the changed position.
    final metrics = await Navigator.of(context).push<_SnapshotMetricValues>(
      MaterialPageRoute(
        builder: (_) =>
            _SnapshotMetricsForm(action: action, legCount: legs.length),
      ),
    );
    if (metrics == null || !context.mounted) return;
    if (action == DecisionAction.hold &&
        (metrics.observation?.trim().isEmpty ?? true)) {
      _message(
        context,
        'A comment is required to record a HOLD decision.',
        error: true,
      );
      return;
    }
    if (action == DecisionAction.hold) {
      observation = metrics.observation!.trim();
    }

    // Calculate lifecycle economics from the complete execution ledger, not
    // only the currently visible legs. Refresh from persistence because the
    // page's Trade object may predate executions just appended by this action.
    final latestTrade = await repo.getTrade(trade.id) ?? trade;
    final lifecycle = const TradeLifecycleAccounting().calculate(
      executions: latestTrade.executions,
      openLegs: legs,
    );
    // Actual charges are cumulative for the whole trade. Preserve a previously
    // recorded cumulative total when this snapshot leaves the field blank.
    final cumulativeActualCharges =
        metrics.actualCharges ?? previous.economics.actualCharges;

    // EDIT LEGS is a snapshot annotation, not a permanent position comment.
    // Remove a prior edit marker when creating any subsequent snapshot so a
    // later HOLD/ADJUST/EXIT cannot inherit the previous action's label.
    final previousComments = previous.position.comments
        ?.split('\n')
        .where((line) => !line.trim().startsWith('[Snapshot action: EDIT LEGS'))
        .join('\n')
        .trim();
    final snapshotComments = recordDecision
        ? (previousComments == null || previousComments.isEmpty
              ? null
              : previousComments)
        : [
            '[Snapshot action: EDIT LEGS — corrected recorded entry price(s)]',
            if (previousComments != null && previousComments.isNotEmpty)
              previousComments,
          ].join('\n');

    if (legs.isEmpty) {
      // A closed trade still needs a final snapshot before its status changes.
      final emptyState = PositionState(
        id: PositionStateId('state-${DateTime.now().microsecondsSinceEpoch}'),
        tradeId: trade.id.value,
        capturedAt: DateTime.now(),
        position: PositionSnapshot(
          underlying: previous.position.underlying,
          expiry: previous.position.expiry,
          legs: const [],
          strategy: previous.position.strategy,
          entryDebitCredit: previous.position.entryDebitCredit,
          comments: snapshotComments,
          plannedRules: previous.position.plannedRules,
        ),
        market: MarketSnapshot(
          spot: metrics.spot,
          vix: metrics.vix,
          atmStraddle: metrics.atmStraddle,
        ),
        geometry: GeometrySnapshot(
          lowerBreakeven: metrics.lowerBreakeven,
          upperBreakeven: metrics.upperBreakeven,
          wingWidth: metrics.wingWidth,
          distanceToLowerBreakeven: metrics.distanceToLowerBreakeven,
          distanceToUpperBreakeven: metrics.distanceToUpperBreakeven,
          profitRange: metrics.profitRange,
        ),
        economics: EconomicSnapshot(
          // P&L is calculated from the full execution lifecycle. If an open
          // leg has no valid mark, total P&L remains unavailable, not zero.
          pnl: lifecycle.grossTotal,
          pnlPercentage: metrics.pnlPercentage,
          capitalDeployed: metrics.capitalDeployed,
          margin: metrics.margin,
          cost: metrics.cost,
          grossRealizedPnl: lifecycle.realizedGross,
          grossUnrealizedPnl: lifecycle.unrealizedGross,
          actualCharges: cumulativeActualCharges,
          netRealizedPnl: legs.isEmpty && cumulativeActualCharges != null
              ? lifecycle.realizedGross - cumulativeActualCharges!
              : null,
        ),
        risk: RiskSnapshot(
          maxProfit: metrics.maxProfit,
          maxLoss: metrics.maxLoss,
          delta: metrics.delta,
          gamma: metrics.gamma,
          theta: metrics.theta,
          vega: metrics.vega,
          iv: metrics.iv,
        ),
      );
      await repo.capturePositionState(tradeId: trade.id, state: emptyState);
      if (recordDecision) {
        await repo.recordDecision(
          tradeId: trade.id,
          decision: DecisionRecord(
            recordedAt: DateTime.now(),
            positionStateId: emptyState.id,
            action: action,
            observation: observation,
          ),
        );
      }
      await repo.closeTrade(tradeId: trade.id, closedAt: DateTime.now());
    } else {
      final first = legs.first;
      final debitCredit = legs.fold<double>(
        0,
        (sum, leg) =>
            sum +
            (leg.entryPremium ?? 0) *
                leg.quantity *
                (leg.side == PositionSide.sell ? 1 : -1),
      );
      final state = PositionState(
        id: PositionStateId('state-${DateTime.now().microsecondsSinceEpoch}'),
        tradeId: trade.id.value,
        capturedAt: DateTime.now(),
        position: PositionSnapshot(
          underlying: previous.position.underlying,
          expiry: first.contract.expiry,
          legs: legs,
          strategy: previous.position.strategy,
          entryDebitCredit: debitCredit,
          comments: snapshotComments,
          plannedRules: previous.position.plannedRules,
        ),
        market: MarketSnapshot(
          spot: metrics.spot,
          vix: metrics.vix,
          atmStraddle: metrics.atmStraddle,
        ),
        geometry: GeometrySnapshot(
          lowerBreakeven: metrics.lowerBreakeven,
          upperBreakeven: metrics.upperBreakeven,
          wingWidth: metrics.wingWidth,
          distanceToLowerBreakeven: metrics.distanceToLowerBreakeven,
          distanceToUpperBreakeven: metrics.distanceToUpperBreakeven,
          profitRange: metrics.profitRange,
        ),
        economics: EconomicSnapshot(
          // P&L is calculated from the full execution lifecycle. If an open
          // leg has no valid mark, total P&L remains unavailable, not zero.
          pnl: lifecycle.grossTotal,
          pnlPercentage: metrics.pnlPercentage,
          capitalDeployed: metrics.capitalDeployed,
          margin: metrics.margin,
          cost: metrics.cost,
          grossRealizedPnl: lifecycle.realizedGross,
          grossUnrealizedPnl: lifecycle.unrealizedGross,
          actualCharges: cumulativeActualCharges,
          netRealizedPnl: legs.isEmpty && cumulativeActualCharges != null
              ? lifecycle.realizedGross - cumulativeActualCharges!
              : null,
        ),
        risk: RiskSnapshot(
          maxProfit: metrics.maxProfit,
          maxLoss: metrics.maxLoss,
          delta: metrics.delta,
          gamma: metrics.gamma,
          theta: metrics.theta,
          vega: metrics.vega,
          iv: metrics.iv,
        ),
      );
      await repo.capturePositionState(tradeId: trade.id, state: state);
      if (recordDecision) {
        await repo.recordDecision(
          tradeId: trade.id,
          decision: DecisionRecord(
            recordedAt: DateTime.now(),
            positionStateId: state.id,
            action: action,
            observation: observation,
          ),
        );
      }
    }
    if (context.mounted) {
      _message(
        context,
        closeWhenEmpty ? 'Position fully exited and closed.' : 'Position updated. The new snapshot records unavailable market metrics as unavailable rather than reusing stale values.',
      );
      Navigator.of(context).pop();
    }
  }

  void _message(BuildContext context, String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Colors.red.shade800 : null,
      ),
    );
  }
}

class _ExitLine {
  const _ExitLine(this.index, this.quantity, this.price);
  final int index;
  final int quantity;
  final double price;
}

class _SnapshotMetricValues {
  const _SnapshotMetricValues({
    this.spot,
    this.vix,
    this.atmStraddle,
    this.lowerBreakeven,
    this.upperBreakeven,
    this.wingWidth,
    this.distanceToLowerBreakeven,
    this.distanceToUpperBreakeven,
    this.profitRange,
    this.pnl,
    this.pnlPercentage,
    this.capitalDeployed,
    this.margin,
    this.cost,
    this.actualCharges,
    this.maxProfit,
    this.maxLoss,
    this.delta,
    this.gamma,
    this.theta,
    this.vega,
    this.iv,
    this.observation,
  });
  final String? observation;
  final double? spot, vix, atmStraddle, lowerBreakeven, upperBreakeven;
  final double? wingWidth,
      distanceToLowerBreakeven,
      distanceToUpperBreakeven,
      profitRange;
  final double? pnl,
      pnlPercentage,
      capitalDeployed,
      margin,
      cost,
      actualCharges;
  final double? maxProfit, maxLoss, delta, gamma, theta, vega, iv;
}

class _SnapshotMetricsForm extends StatefulWidget {
  const _SnapshotMetricsForm({required this.action, required this.legCount});
  final DecisionAction action;
  final int legCount;
  @override
  State<_SnapshotMetricsForm> createState() => _SnapshotMetricsFormState();
}

class _SnapshotMetricsFormState extends State<_SnapshotMetricsForm> {
  final Map<String, TextEditingController> _fields = {};
  final TextEditingController _observationController = TextEditingController();
  final Map<String, String> _labels = const {
    'spot': 'Underlying spot',
    'vix': 'India VIX',
    'atmStraddle': 'ATM straddle price',
    'lowerBreakeven': 'Lower breakeven',
    'upperBreakeven': 'Upper breakeven',
    'wingWidth': 'Wing width',
    'distanceToLowerBreakeven': 'Distance to lower breakeven',
    'distanceToUpperBreakeven': 'Distance to upper breakeven',
    'profitRange': 'Profit range',
    'pnlPercentage': 'P&L %',
    'capitalDeployed': 'Capital deployed',
    'margin': 'Margin',
    'cost': 'Other costs / estimates',
    'actualCharges': 'Cumulative actual charges (broker-confirmed)',
    'maxProfit': 'Maximum profit',
    'maxLoss': 'Maximum loss',
    'delta': 'Delta',
    'gamma': 'Gamma',
    'theta': 'Theta',
    'vega': 'Vega',
    'iv': 'Implied volatility (IV)',
  };

  @override
  void initState() {
    super.initState();
    for (final key in _labels.keys) {
      // Do not prefill from the previous state: those values may be stale for
      // this newly changed position. Leave unavailable metrics blank.
      _fields[key] = TextEditingController();
    }
  }

  double? _value(String key) {
    final text = _fields[key]!.text.trim();
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    return value != null && value.isFinite ? value : null;
  }

  void _save() {
    for (final entry in _fields.entries) {
      final text = entry.value.text.trim();
      if (text.isNotEmpty && _value(entry.key) == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Enter a valid number for ${_labels[entry.key]}.'),
          ),
        );
        return;
      }
    }
    final observation = _observationController.text.trim();
    if (widget.action == DecisionAction.hold && observation.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a comment to record the HOLD decision.'),
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      _SnapshotMetricValues(
        observation: observation,
        spot: _value('spot'),
        vix: _value('vix'),
        atmStraddle: _value('atmStraddle'),
        lowerBreakeven: _value('lowerBreakeven'),
        upperBreakeven: _value('upperBreakeven'),
        wingWidth: _value('wingWidth'),
        distanceToLowerBreakeven: _value('distanceToLowerBreakeven'),
        distanceToUpperBreakeven: _value('distanceToUpperBreakeven'),
        profitRange: _value('profitRange'),
        pnl: null,
        pnlPercentage: _value('pnlPercentage'),
        capitalDeployed: _value('capitalDeployed'),
        margin: _value('margin'),
        cost: _value('cost'),
        actualCharges: _value('actualCharges'),
        maxProfit: _value('maxProfit'),
        maxLoss: _value('maxLoss'),
        delta: _value('delta'),
        gamma: _value('gamma'),
        theta: _value('theta'),
        vega: _value('vega'),
        iv: _value('iv'),
      ),
    );
  }

  Widget _section(String title, List<String> keys) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720
                  ? 3
                  : constraints.maxWidth >= 440
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final key in keys)
                    SizedBox(
                      width: width,
                      child: TextField(
                        controller: _fields[key],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: InputDecoration(
                          labelText: _labels[key],
                          helperText: key == 'actualCharges'
                              ? 'Cumulative total; enter only broker-confirmed charges'
                              : 'Optional',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _observationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Review snapshot metrics'),
      backgroundColor: _positionPageBackground,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton(onPressed: _save, child: const Text('Save snapshot')),
        const SizedBox(width: 12),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${widget.action.name.toUpperCase()} · ${widget.legCount} ${widget.legCount == 1 ? 'leg' : 'legs'}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Review the metrics for this exact position state before saving. Enter values you know; leave anything unavailable blank. Metrics from an earlier snapshot are not copied forward.',
          ),
          if (widget.action == DecisionAction.hold) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _observationController,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Why are you holding? *',
                hintText: 'Record your reasoning, what you are watching, and your exit/adjustment trigger.',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
          ],
          const SizedBox(height: 12),
          _section('Market at capture', ['spot', 'vix', 'atmStraddle']),
          _section('Breakevens and payoff geometry', [
            'lowerBreakeven',
            'upperBreakeven',
            'wingWidth',
            'distanceToLowerBreakeven',
            'distanceToUpperBreakeven',
            'profitRange',
          ]),
          _section('Economics', [
            'pnlPercentage',
            'capitalDeployed',
            'margin',
            'cost',
            'actualCharges',
          ]),
          _section('Risk and Greeks', [
            'maxProfit',
            'maxLoss',
            'delta',
            'gamma',
            'theta',
            'vega',
            'iv',
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save position snapshot'),
          ),
        ],
      ),
    ),
  );
}

class _EditLegsForm extends StatefulWidget {
  const _EditLegsForm({required this.legs, required this.premiums});

  final List<PositionLeg> legs;
  final List<TextEditingController> premiums;

  @override
  State<_EditLegsForm> createState() => _EditLegsFormState();
}

class _EditLegsFormState extends State<_EditLegsForm> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit leg prices'),
        backgroundColor: _positionPageBackground,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save prices'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Correct the recorded entry price only. Side and quantity remain unchanged; no exit/re-entry executions or adjustment decision will be created.',
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < widget.legs.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${widget.legs[i].contract.strike} ${widget.legs[i].contract.optionType == OptionType.call ? 'CE' : 'PE'} · ${_dateLabel(widget.legs[i].contract.expiry.value)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${widget.legs[i].side == PositionSide.buy ? 'BUY' : 'SELL'} · Quantity ${widget.legs[i].quantity}',
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: widget.premiums[i],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Correct entry price',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExitLegsForm extends StatefulWidget {
  const _ExitLegsForm({
    required this.legs,
    required this.quantities,
    required this.prices,
  });

  final List<PositionLeg> legs;
  final List<TextEditingController> quantities;
  final List<TextEditingController> prices;

  @override
  State<_ExitLegsForm> createState() => _ExitLegsFormState();
}

class _ExitLegsFormState extends State<_ExitLegsForm> {
  late final List<bool> _selected = List<bool>.filled(
    widget.legs.length,
    false,
  );

  void _submit() {
    final lines = <_ExitLine>[];
    for (var i = 0; i < widget.legs.length; i++) {
      if (!_selected[i]) continue;
      final quantity = int.tryParse(widget.quantities[i].text.trim());
      final price = double.tryParse(widget.prices[i].text.trim());
      if (quantity == null ||
          quantity <= 0 ||
          quantity > widget.legs[i].quantity ||
          price == null ||
          !price.isFinite ||
          price < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enter a valid exit quantity and non-negative exit price for each selected leg.',
            ),
          ),
        );
        return;
      }
      lines.add(_ExitLine(i, quantity, price));
    }
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one leg to exit.')),
      );
      return;
    }
    Navigator.of(context).pop(lines);
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Exit selected legs', softWrap: true, maxLines: 2),
        toolbarHeight: isNarrow ? 80 : kToolbarHeight,
        backgroundColor: _positionPageBackground,
        actions: isNarrow
            ? null
            : [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('Record exit'),
                ),
                const SizedBox(width: 12),
              ],
        bottom: isNarrow
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _submit,
                        child: const Text('Record exit'),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),

      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Select one or more legs. Enter the quantity to close and the actual/assumed exit price. Remaining quantities stay open.',
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < widget.legs.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        value: _selected[i],
                        onChanged: (value) =>
                            setState(() => _selected[i] = value ?? false),
                        title: Text(
                          '${widget.legs[i].side == PositionSide.buy ? 'SELL TO EXIT' : 'BUY TO EXIT'} '
                          '${widget.legs[i].contract.strike} '
                          '${widget.legs[i].contract.optionType == OptionType.call ? 'CE' : 'PE'}',
                          softWrap: true,
                        ),
                        subtitle: Text(
                          'Original position: ${widget.legs[i].side.name.toUpperCase()} · '
                          'Open quantity ${widget.legs[i].quantity}',
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                      if (_selected[i])
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth >= 440;
                            final fieldWidth = wide
                                ? (constraints.maxWidth - 8) / 2
                                : constraints.maxWidth;
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                SizedBox(
                                  width: fieldWidth,
                                  child: TextField(
                                    controller: widget.quantities[i],
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Qty to exit',
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: fieldWidth,
                                  child: TextField(
                                    controller: widget.prices[i],
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: 'Exit price',
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SimilarTradeCard extends StatelessWidget {
  const _SimilarTradeCard({required this.match});
  final SimilarPositionMatch match;

  @override
  Widget build(BuildContext context) {
    final trade = match.trade;
    final state = match.state;
    final pnl = state.economics.pnl;
    final expiry = state.position.expiry.value;
    final percent = (match.score * 100).round();
    final topFactors = [...match.factors]
      ..sort((a, b) => (b.similarity ?? -1).compareTo(a.similarity ?? -1));
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        title: Text(
          '${state.position.underlying} · ${state.position.strategy.name}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '$percent% contextual similarity · ${state.position.legs.length} legs · ${_dateLabel(state.capturedAt.toLocal())}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              pnl == null
                  ? 'Snapshot P&L n/a'
                  : 'Snapshot ${pnl < 0 ? '−' : ''}₹${pnl.abs().toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              state.economics.netRealizedPnl == null
                  ? 'Outcome unavailable'
                  : 'Net realized ₹${state.economics.netRealizedPnl!.toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Original trade: ${trade.strategy.name} · Closed ${trade.closedAt == null ? 'date unavailable' : _dateLabel(trade.closedAt!.toLocal())} · Expiry ${_dateLabel(expiry)}',
            ),
          ),
          const SizedBox(height: 6),
          for (final factor in topFactors)
            if (factor.similarity != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(factor.name)),
                    Text('${(factor.similarity! * 100).round()}%'),
                  ],
                ),
              ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PositionsPage(
                    trade: trade,
                    selectedState: state,
                    forceStaticPayoff: true,
                  ),
                ),
              ),
              icon: const Icon(Icons.history),
              label: const Text('Open matched historical state'),
            ),
          ),
          const Text(
            'Similarity describes recorded context, not the probability of a profitable outcome.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

class _GroupedExecutions extends StatelessWidget {
  const _GroupedExecutions({required this.trade});
  final Trade trade;
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Execution>>{};
    final sorted = [...trade.executions]
      ..sort((a, b) => b.executedAt.compareTo(a.executedAt));
    for (final e in sorted) {
      final key =
          '${_dateLabel(e.executedAt.toLocal())}|${_dateLabel(e.contract.expiry.value)}';
      groups.putIfAbsent(key, () => []).add(e);
    }
    return Column(
      children: [
        for (final key in groups.keys)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              'Execution date ${key.split('|')[0]} · Expiry ${key.split('|')[1]}',
            ),
            subtitle: Text('${groups[key]!.length} execution(s)'),
            children: [
              for (final e in groups[key]!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${e.side.name.toUpperCase()} ${e.contract.strike} ${e.contract.optionType == OptionType.call ? 'CE' : 'PE'}',
                  ),
                  subtitle: Text(
                    'Qty ${e.quantity} · Price ₹${e.price.toStringAsFixed(2)}\nExecuted ${_dateTimeLabel(e.executedAt)}',
                  ),
                  isThreeLine: true,
                ),
            ],
          ),
      ],
    );
  }
}

class _PositionTimeline extends StatelessWidget {
  const _PositionTimeline({
    required this.trade,
    required this.selectedState,
    required this.latestState,
  });
  final Trade trade;
  final PositionState? selectedState;
  final PositionState? latestState;

  @override
  Widget build(BuildContext context) {
    final entries = <_TimelineEntry>[];
    final representedStateIds = <PositionStateId>{};

    // Present a decision and its linked immutable snapshot as one timeline
    // event. The decision and snapshot remain separate persisted records.
    for (final decision in trade.decisionRecords) {
      PositionState? linkedState;
      final stateId = decision.positionStateId;
      if (stateId != null) {
        for (final state in trade.positionStates) {
          if (state.id == stateId) {
            linkedState = state;
            representedStateIds.add(state.id);
            break;
          }
        }
      }
      entries.add(
        _TimelineEntry(
          time: decision.recordedAt,
          state: linkedState,
          decision: decision,
        ),
      );
    }

    // Keep snapshots that have no linked decision as their own timeline event.
    for (final state in trade.positionStates) {
      if (representedStateIds.contains(state.id)) continue;
      entries.add(_TimelineEntry(time: state.capturedAt, state: state));
    }

    entries.sort((a, b) => b.time.compareTo(a.time));
    final newestFirst = entries;
    return Column(
      children: [
        for (var i = 0; i < newestFirst.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _timelineTile(context, newestFirst[i]),
        ],
      ],
    );
  }

  Widget _timelineTile(BuildContext context, _TimelineEntry entry) {
    final hasDecision = entry.decision != null;
    final isLatest = entry.state?.id == latestState?.id;
    final rawAction = entry.decision?.action;
    final action = rawAction == DecisionAction.partialExit
        ? 'PARTIAL_EXIT'
        : rawAction?.name.toUpperCase();
    final snapshotComment = entry.state?.position.comments?.trim();
    final isLegPriceEdit =
        snapshotComment?.contains('[Snapshot action: EDIT LEGS') == true;
    final title = hasDecision
        ? 'Decision · $action${entry.state == null ? '' : ' + position snapshot'}'
        : '${isLegPriceEdit ? 'Edit legs snapshot' : (isLatest ? 'Latest position snapshot' : 'Position snapshot')} · ${entry.state!.position.strategy.name}';
    final note = entry.decision?.observation?.trim();
    final pnl = entry.state?.economics.pnl;
    final details = <String>[
      if (entry.state != null)
        'Snapshot · Spot ${entry.state!.market.spot == null ? 'Unavailable' : entry.state!.market.spot!.toStringAsFixed(2)} · Total gross P&L ${pnl == null ? 'Unavailable' : '₹${pnl.toStringAsFixed(2)}'}',
      if (entry.state?.economics.grossRealizedPnl != null)
        'Realized gross P&L · ₹${entry.state!.economics.grossRealizedPnl!.toStringAsFixed(2)}',
      if (entry.state?.economics.grossUnrealizedPnl != null)
        'Unrealized gross P&L · ₹${entry.state!.economics.grossUnrealizedPnl!.toStringAsFixed(2)}',
      if (entry.state?.economics.actualCharges != null)
        'Actual charges to date · ₹${entry.state!.economics.actualCharges!.toStringAsFixed(2)}',
      if (entry.state?.economics.grossRealizedPnl != null &&
          entry.state?.economics.actualCharges != null)
        'Realized net P&L to date · ₹${(entry.state!.economics.grossRealizedPnl! - entry.state!.economics.actualCharges!).toStringAsFixed(2)}',
      if (isLegPriceEdit)
        'Action · EDIT LEGS — corrected recorded entry price(s)',
      if (hasDecision)
        note?.isNotEmpty == true ? note! : 'No decision note recorded',
      if (hasDecision && entry.state == null) 'Linked snapshot unavailable',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        hasDecision
            ? Icons.psychology_alt_outlined
            : (isLatest ? Icons.radio_button_checked : Icons.history),
        color: isLatest ? _positionBrand : Colors.grey,
      ),
      title: Text(title),
      subtitle: Text('${_dateTimeLabel(entry.time)}\n${details.join('\n')}'),
      isThreeLine: true,
      trailing: entry.state != null ? const Icon(Icons.chevron_right) : null,
      onTap: entry.state == null ? null : () => _openEntry(context, entry),
    );
  }

  void _openEntry(BuildContext context, _TimelineEntry entry) {
    final target = entry.state;
    if (target == null || target.id == selectedState?.id) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PositionsPage(
          trade: trade,
          selectedState: target,
          selectedDecision: entry.decision,
          // A decision is read-only, but its linked latest open snapshot must
          // still expose interactive payoff scenarios. Snapshot age/status,
          // not the presence of a decision, controls payoff interactivity.
          forceStaticPayoff: false,
        ),
      ),
    );
  }
}

class _TimelineEntry {
  const _TimelineEntry({required this.time, this.state, this.decision});
  final DateTime time;
  final PositionState? state;
  final DecisionRecord? decision;
}

class _SnapshotExpansion extends StatelessWidget {
  const _SnapshotExpansion({
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });
  final String title;
  final Widget child;
  final bool initiallyExpanded;

  static final ValueNotifier<String?> _activeSection = ValueNotifier<String?>(
    null,
  );
  static bool _initialExpansionConsumed = false;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: _activeSection,
    builder: (context, active, _) {
      final expanded =
          active == title ||
          (active == null && initiallyExpanded && !_initialExpansionConsumed);
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          key: ValueKey<String>('snapshot-section-$title-$expanded'),
          initiallyExpanded: expanded,
          onExpansionChanged: (isExpanded) {
            _initialExpansionConsumed = true;
            if (isExpanded) {
              _activeSection.value = title;
            } else if (_activeSection.value == title) {
              _activeSection.value = null;
            }
          },
          title: Text(title, style: Theme.of(context).textTheme.titleMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [Align(alignment: Alignment.centerLeft, child: child)],
        ),
      );
    },
  );
}

class _SnapshotValue extends StatelessWidget {
  const _SnapshotValue(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 5,
          child: Text(label, style: const TextStyle(color: Colors.black54)),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 4,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _InteractivePositionPayoff extends StatefulWidget {
  const _InteractivePositionPayoff({required this.trade, required this.state});
  final Trade trade;
  final PositionState state;

  @override
  State<_InteractivePositionPayoff> createState() =>
      _InteractivePositionPayoffState();
}

class _InteractivePositionPayoffState
    extends State<_InteractivePositionPayoff> {
  late double _spot;
  late double _vix;
  late double _dte;
  late double _initialSpot;
  late double _initialVix;
  // Start at a tight, useful view; zooming out expands the spot range.
  double _payoffZoom = 0.25;
  late double _initialDte;
  late bool _spotWasCaptured;
  late bool _vixWasCaptured;

  @override
  void initState() {
    super.initState();
    final state = widget.state;
    final strikes = state.position.legs
        .map((l) => l.contract.strike.toDouble())
        .toList();
    final center = strikes.isEmpty
        ? 1.0
        : strikes.reduce((a, b) => a + b) / strikes.length;
    _spotWasCaptured = state.market.spot != null && state.market.spot! > 0;
    _vixWasCaptured = state.market.vix != null && state.market.vix! > 0;
    _initialSpot = (_spotWasCaptured ? state.market.spot! : center)
        .clamp(1.0, double.infinity)
        .toDouble();
    _initialVix =
        (_vixWasCaptured
                ? state.market.vix!
                : (state.risk.iv != null && state.risk.iv! > 0
                      ? state.risk.iv!
                      : 15.0))
            .clamp(5.0, 80.0)
            .toDouble();
    final expiry = state.position.expiry.value;
    final captureDate = DateTime(
      state.capturedAt.year,
      state.capturedAt.month,
      state.capturedAt.day,
    );
    _initialDte = expiry
        .difference(captureDate)
        .inDays
        .clamp(0, 365)
        .toDouble();
    _spot = _initialSpot;
    _vix = _initialVix;
    _dte = _initialDte;
  }

  void _resetSpot() => setState(() => _spot = _initialSpot);
  void _resetVix() => setState(() => _vix = _initialVix);
  void _resetDte() => setState(() => _dte = _initialDte);
  void _resetAll() => setState(() {
    _spot = _initialSpot;
    _vix = _initialVix;
    _dte = _initialDte;
  });

  double _cdf(double x) {
    final ax = x.abs();
    final t = 1 / (1 + 0.2316419 * ax);
    final density = 0.3989422804014327 * math.exp(-ax * ax / 2);
    final polynomial =
        0.319381530 * t -
        0.356563782 * t * t +
        1.781477937 * t * t * t -
        1.821255978 * t * t * t * t +
        1.330274429 * t * t * t * t * t;
    final probability = 1 - density * polynomial;
    return (x >= 0 ? probability : 1 - probability).toDouble();
  }

  ({double price, double delta, double gamma, double theta, double vega})
  _optionModel({
    required double spot,
    required double strike,
    required bool isCall,
    required double volPct,
    required double days,
  }) {
    final years = math.max(days, 0.01).toDouble() / 365;
    final sigma = math.max(volPct, 0.1).toDouble() / 100;
    const rate = 0.06;
    final rootT = math.sqrt(years);
    final d1 =
        (math.log(spot / strike) + (rate + sigma * sigma / 2) * years) /
        (sigma * rootT);
    final d2 = d1 - sigma * rootT;
    final density = 0.3989422804014327 * math.exp(-d1 * d1 / 2);
    final discount = math.exp(-rate * years);
    final callPrice = spot * _cdf(d1) - strike * discount * _cdf(d2);
    final putPrice = strike * discount * _cdf(-d2) - spot * _cdf(-d1);
    final delta = isCall ? _cdf(d1) : _cdf(d1) - 1;
    final gamma = density / (spot * sigma * rootT);
    final vega = spot * density * rootT / 100; // per 1 volatility point
    final thetaCall =
        (-spot * density * sigma / (2 * rootT) -
            rate * strike * discount * _cdf(d2)) /
        365;
    final thetaPut =
        (-spot * density * sigma / (2 * rootT) +
            rate * strike * discount * _cdf(-d2)) /
        365;
    return (
      price: math.max(0.0, isCall ? callPrice : putPrice).toDouble(),
      delta: delta,
      gamma: gamma,
      theta: isCall ? thetaCall : thetaPut,
      vega: vega,
    );
  }

  Execution? _matchingExecution(PositionLeg leg) {
    for (final execution in widget.trade.executions) {
      if (execution.contract.underlying == leg.contract.underlying &&
          execution.contract.expiry == leg.contract.expiry &&
          execution.contract.strike == leg.contract.strike &&
          execution.contract.optionType == leg.contract.optionType &&
          (execution.side == ExecutionSide.buy
                  ? PositionSide.buy
                  : PositionSide.sell) ==
              leg.side)
        return execution;
    }
    return null;
  }

  double? _entryPremiumFor(PositionLeg leg) =>
      leg.entryPremium ?? _matchingExecution(leg)?.price;

  String _money(double? value) => value == null || !value.isFinite
      ? 'Unavailable'
      : '${value < 0 ? '−' : ''}₹${value.abs().toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final legs = widget.state.position.legs;
    final missingEntry = legs.any((leg) => _entryPremiumFor(leg) == null);
    double mtm = 0;
    double expiryPnl = 0;
    double delta = 0, gamma = 0, theta = 0, vega = 0;
    for (final leg in legs) {
      final entryPremium = _entryPremiumFor(leg);
      if (entryPremium == null) continue;
      final sign = leg.side == PositionSide.buy ? 1.0 : -1.0;
      final model = _optionModel(
        spot: _spot,
        strike: leg.contract.strike.toDouble(),
        isCall: leg.contract.optionType == OptionType.call,
        volPct: _vix,
        days: _dte,
      );
      mtm += sign * (model.price - entryPremium) * leg.quantity;
      final intrinsic =
          (leg.contract.optionType == OptionType.call
                  ? math.max(0.0, _spot - leg.contract.strike)
                  : math.max(0.0, leg.contract.strike - _spot))
              .toDouble();
      expiryPnl += sign * (intrinsic - entryPremium) * leg.quantity;
      delta += sign * model.delta * leg.quantity;
      gamma += sign * model.gamma * leg.quantity;
      theta += sign * model.theta * leg.quantity;
      vega += sign * model.vega * leg.quantity;
    }
    final visibleHalfRange = math
        .max(1.0, _initialSpot * 0.3 * _payoffZoom)
        .toDouble();
    // Keep the chart centered on the selected scenario spot; zoom only changes
    // the chart's visible range and never changes the scenario slider bounds.
    final minSpot = math.max(1.0, _spot - visibleHalfRange).toDouble();
    final maxSpot = (_spot + visibleHalfRange).toDouble();
    // Spot scenarios are anchored to the saved/captured spot, move in 10-point
    // increments, and stay within +/-20% regardless of the chart zoom level.
    final spotSliderMin = ((_initialSpot * 0.8) / 10).ceil() * 10.0;
    final spotSliderMax = ((_initialSpot * 1.2) / 10).floor() * 10.0;
    final spotSliderDivisions = math.max(
      1,
      ((spotSliderMax - spotSliderMin) / 10).round(),
    );
    final maxDte = math.max(1.0, _initialDte).toDouble();
    final canUseSpot = maxSpot > minSpot;
    double? pnlAtSpot(double spot, {required bool expiry}) {
      var result = 0.0;
      for (final leg in legs) {
        final entryPremium = _entryPremiumFor(leg);
        if (entryPremium == null) return null;
        final sign = leg.side == PositionSide.buy ? 1.0 : -1.0;
        if (expiry) {
          final intrinsic =
              (leg.contract.optionType == OptionType.call
                      ? math.max(0.0, spot - leg.contract.strike)
                      : math.max(0.0, leg.contract.strike - spot))
                  .toDouble();
          result += sign * (intrinsic - entryPremium) * leg.quantity;
        } else {
          final model = _optionModel(
            spot: spot,
            strike: leg.contract.strike.toDouble(),
            isCall: leg.contract.optionType == OptionType.call,
            volPct: _vix,
            days: _dte,
          );
          result += sign * (model.price - entryPremium) * leg.quantity;
        }
      }
      return result;
    }

    // More samples keep the theoretical MTM curve visually smooth on narrow
    // mobile screens while retaining exact spot endpoints.
    final chartSpots = List<double>.generate(
      181,
      (i) => minSpot + (maxSpot - minSpot) * i / 180,
    );
    final mtmCurve = chartSpots
        .map((spot) => pnlAtSpot(spot, expiry: false))
        .toList();
    final expiryCurve = chartSpots
        .map((spot) => pnlAtSpot(spot, expiry: true))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Scenario payoff · based on this saved position state',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        const Text(
          'MTM is a theoretical estimate using Black–Scholes and the VIX slider as an IV proxy—not a live broker quote. Taxes, charges, dividends and volatility skew are excluded.',
          style: TextStyle(fontSize: 12, color: Colors.black54, height: 1.35),
        ),
        if (!_spotWasCaptured || !_vixWasCaptured) ...[
          const SizedBox(height: 6),
          Text(
            'Assumption: ${!_spotWasCaptured ? 'spot was not captured; slider starts at the average leg strike' : ''}${!_spotWasCaptured && !_vixWasCaptured ? '; ' : ''}${!_vixWasCaptured ? 'VIX was not captured; slider starts at a 15% IV proxy' : ''}.',
            style: const TextStyle(fontSize: 12, color: Colors.deepOrange),
          ),
        ],
        const SizedBox(height: 14),
        _ScenarioSlider(
          label: 'Spot',
          value: _spot,
          min: spotSliderMin,
          max: spotSliderMax,
          divisions: spotSliderDivisions,
          display: _spot.toStringAsFixed(2),
          onChanged: (value) => setState(() => _spot = value),
          onReset: _resetSpot,
        ),
        _ScenarioSlider(
          label: 'VIX / IV adjustment',
          value: _vix - _initialVix,
          // Equal positive/negative movement around the captured IV, limited
          // by the model's supported 1–100% IV bounds.
          min: -math.min(_initialVix - 1.0, 100.0 - _initialVix),
          max: math.min(_initialVix - 1.0, 100.0 - _initialVix),
          divisions: math.max(
            1,
            (2 * math.min(_initialVix - 1.0, 100.0 - _initialVix)).round(),
          ),
          display:
              '${_vix.toStringAsFixed(1)}% IV (${(_vix - _initialVix) >= 0 ? '+' : ''}${(_vix - _initialVix).toStringAsFixed(1)} pp)',
          onChanged: (adjustment) => setState(
            () =>
                _vix = (_initialVix + adjustment).clamp(1.0, 100.0).toDouble(),
          ),
          onReset: _resetVix,
        ),
        _ScenarioSlider(
          label: 'DTE',
          // Reverse the slider direction: full DTE on the left, expiry (0) on the right.
          value: (maxDte - _dte).clamp(0, maxDte).toDouble(),
          min: 0,
          max: maxDte,
          divisions: math.max(1, maxDte.round()).toInt(),
          display: '${_dte.round()} days',
          onChanged: (v) => setState(() => _dte = maxDte - v),
          onReset: _resetDte,
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _resetAll,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset all scenarios'),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Text(
              'Zoom',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Zoom in',
              visualDensity: VisualDensity.compact,
              onPressed: _payoffZoom > 0.0625
                  ? () => setState(
                      () => _payoffZoom = (_payoffZoom * 0.75)
                          .clamp(0.0625, 8.0)
                          .toDouble(),
                    )
                  : null,
              icon: const Icon(Icons.zoom_in),
            ),
            IconButton(
              tooltip: 'Zoom out',
              visualDensity: VisualDensity.compact,
              onPressed: _payoffZoom < 8.0
                  ? () => setState(
                      () => _payoffZoom = (_payoffZoom / 0.75)
                          .clamp(0.0625, 8.0)
                          .toDouble(),
                    )
                  : null,
              icon: const Icon(Icons.zoom_out),
            ),
            TextButton(
              onPressed: _payoffZoom == 0.25
                  ? null
                  : () => setState(() => _payoffZoom = 0.25),
              child: const Text('Reset zoom'),
            ),
          ],
        ),
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: _ScenarioPayoffPainter(
              spots: chartSpots,
              mtm: mtmCurve.map((v) => v ?? double.nan).toList(),
              expiry: expiryCurve.map((v) => v ?? double.nan).toList(),
              minSpot: minSpot,
              maxSpot: maxSpot,
              // Mark the currently selected scenario spot, not the immutable
              // historical capture spot, so the marker follows the slider.
              capturedSpot: _spot,
              textColor: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        const Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            _CurveLegend(color: Color(0xFF176B87), label: 'MTM P&L'),
            _CurveLegend(color: Color(0xFFE07A32), label: 'Expiry P&L'),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetricChip(
              label: 'MTM P&L at selected spot',
              value: missingEntry ? 'Unavailable' : _money(mtm),
            ),
            _MetricChip(
              label: 'Expiry P&L',
              value: missingEntry ? 'Unavailable' : _money(expiryPnl),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const Text(
          'Position Greeks (modeled)',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetricChip(
              label: 'Delta',
              value: missingEntry ? 'Unavailable' : delta.toStringAsFixed(3),
            ),
            _MetricChip(
              label: 'Gamma',
              value: missingEntry ? 'Unavailable' : gamma.toStringAsFixed(5),
            ),
            _MetricChip(
              label: 'Theta / day',
              value: missingEntry ? 'Unavailable' : theta.toStringAsFixed(2),
            ),
            _MetricChip(
              label: 'Vega / vol pt',
              value: missingEntry ? 'Unavailable' : vega.toStringAsFixed(2),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (missingEntry)
          const Text(
            'Some saved legs do not match recorded executions, so MTM, expiry P&L and aggregate Greeks cannot be reconstructed reliably. Save entry premiums for each leg to enable these calculations.',
            style: TextStyle(color: Colors.deepOrange, fontSize: 12),
          ),
      ],
    );
  }
}

class _CurveLegend extends StatelessWidget {
  const _CurveLegend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 18, height: 3, color: color),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}

class _ScenarioPayoffPainter extends CustomPainter {
  const _ScenarioPayoffPainter({
    required this.spots,
    required this.mtm,
    required this.expiry,
    required this.minSpot,
    required this.maxSpot,
    required this.capturedSpot,
    required this.textColor,
  });
  final List<double> spots, mtm, expiry;
  final double minSpot, maxSpot;
  final double? capturedSpot;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    final compact = size.width < 360;
    final left = compact ? 42.0 : 50.0;
    const right = 8.0, top = 18.0, bottom = 27.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final all = [...mtm, ...expiry].where((v) => v.isFinite).toList();
    if (all.isEmpty ||
        plot.width <= 0 ||
        plot.height <= 0 ||
        maxSpot <= minSpot)
      return;
    var minY = all.reduce((a, b) => a < b ? a : b);
    var maxY = all.reduce((a, b) => a > b ? a : b);
    if ((maxY - minY).abs() < 0.01) {
      minY -= 1;
      maxY += 1;
    }
    final yRange = maxY - minY;
    final xFor = (double x) =>
        plot.left + (x - minSpot) / (maxSpot - minSpot) * plot.width;
    final yFor = (double y) => plot.bottom - (y - minY) / yRange * plot.height;

    final grid = Paint()
      ..color = textColor.withValues(alpha: 0.10)
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr, maxLines: 1);
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final value = maxY - yRange * i / 4;
      tp.text = TextSpan(
        text: _compactMoney(value),
        style: TextStyle(
          color: textColor.withValues(alpha: .68),
          fontSize: compact ? 9 : 10,
        ),
      );
      tp.layout(maxWidth: left - 7);
      tp.paint(canvas, Offset(plot.left - tp.width - 5, y - tp.height / 2));
    }
    final zeroY = yFor(0);
    if (zeroY >= plot.top && zeroY <= plot.bottom) {
      canvas.drawLine(
        Offset(plot.left, zeroY),
        Offset(plot.right, zeroY),
        Paint()
          ..color = textColor.withValues(alpha: .48)
          ..strokeWidth = 1.1,
      );
    }

    // Smooth interpolation between dense samples. The expiry payoff is still
    // sampled densely so strike kinks remain localized rather than jagged.
    void drawCurve(List<double> values, Color color, {double width = 2.4}) {
      final pts = <Offset>[];
      for (var i = 0; i < values.length && i < spots.length; i++) {
        if (values[i].isFinite)
          pts.add(Offset(xFor(spots[i]), yFor(values[i])));
      }
      if (pts.length < 2) return;
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length - 1; i++) {
        final mid = Offset(
          (pts[i].dx + pts[i + 1].dx) / 2,
          (pts[i].dy + pts[i + 1].dy) / 2,
        );
        path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }

    drawCurve(mtm, const Color(0xFF176B87), width: 2.7);
    drawCurve(expiry, const Color(0xFFE07A32), width: 2.2);

    final spot = capturedSpot;
    if (spot != null && spot >= minSpot && spot <= maxSpot) {
      final spotX = xFor(spot);
      final marker = Paint()
        ..color = const Color(0xFFB45309).withValues(alpha: .9)
        ..strokeWidth = 1.25;
      const dash = 4.0, gap = 3.5;
      for (var y = plot.top; y < plot.bottom; y += dash + gap) {
        canvas.drawLine(
          Offset(spotX, y),
          Offset(spotX, math.min(y + dash, plot.bottom)),
          marker,
        );
      }
      final label = spot.toStringAsFixed(0);
      tp.text = TextSpan(
        text: 'Spot $label',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      );
      tp.layout();
      final bubbleWidth = tp.width + 12, bubbleHeight = tp.height + 7;
      final bubbleLeft = (spotX + 6 + bubbleWidth > plot.right)
          ? spotX - bubbleWidth - 6
          : spotX + 6;
      final bubble = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bubbleLeft.clamp(plot.left, plot.right - bubbleWidth),
          plot.top + 2,
          bubbleWidth,
          bubbleHeight,
        ),
        const Radius.circular(5),
      );
      canvas.drawRRect(bubble, Paint()..color = const Color(0xFF92400E));
      tp.paint(canvas, Offset(bubble.left + 6, bubble.top + 3.5));
      canvas.drawCircle(
        Offset(spotX, yFor(0).clamp(plot.top, plot.bottom)),
        3.2,
        Paint()..color = const Color(0xFFB45309),
      );
    }

    void xLabel(String text, double x, {bool center = false}) {
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: textColor.withValues(alpha: .72),
          fontSize: compact ? 9 : 10,
        ),
      );
      tp.layout();
      final dx = center ? x - tp.width / 2 : x;
      tp.paint(
        canvas,
        Offset(dx.clamp(plot.left, plot.right - tp.width), plot.bottom + 5),
      );
    }

    xLabel(minSpot.toStringAsFixed(0), plot.left);
    xLabel(maxSpot.toStringAsFixed(0), plot.right - 1 - 24);
  }

  String _compactMoney(double value) {
    final abs = value.abs();
    final prefix = value < 0 ? '−₹' : '₹';
    if (abs >= 10000000)
      return '$prefix${(abs / 10000000).toStringAsFixed(1)}Cr';
    if (abs >= 100000) return '$prefix${(abs / 100000).toStringAsFixed(1)}L';
    if (abs >= 1000) return '$prefix${(abs / 1000).toStringAsFixed(1)}k';
    return '$prefix${abs.toStringAsFixed(0)}';
  }

  @override
  bool shouldRepaint(covariant _ScenarioPayoffPainter oldDelegate) =>
      spots != oldDelegate.spots ||
      mtm != oldDelegate.mtm ||
      expiry != oldDelegate.expiry ||
      minSpot != oldDelegate.minSpot ||
      maxSpot != oldDelegate.maxSpot ||
      capturedSpot != oldDelegate.capturedSpot ||
      textColor != oldDelegate.textColor;
}

class _ScenarioSlider extends StatelessWidget {
  const _ScenarioSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
    required this.onReset,
  });
  final String label;
  final double value, min, max;
  final int divisions;
  final String display;
  final ValueChanged<double>? onChanged;
  final VoidCallback onReset;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(display, style: const TextStyle(fontWeight: FontWeight.w700)),
          IconButton(
            tooltip: 'Reset $label',
            visualDensity: VisualDensity.compact,
            onPressed: onReset,
            icon: const Icon(Icons.restart_alt, size: 18),
          ),
        ],
      ),
      Slider(
        value: value.clamp(min, max).toDouble(),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    ],
  );
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _StaticHistoricalPayoff extends StatefulWidget {
  const _StaticHistoricalPayoff({required this.trade, required this.state});
  final Trade trade;
  final PositionState state;

  @override
  State<_StaticHistoricalPayoff> createState() =>
      _StaticHistoricalPayoffState();
}

class _StaticHistoricalPayoffState extends State<_StaticHistoricalPayoff> {
  // 1.0 is the original chart range. Smaller values zoom in; larger values
  // zoom out. This is presentation-only and never changes saved snapshot data.
  double _zoom = 1.0;

  @override
  Widget build(BuildContext context) {
    final trade = widget.trade;
    final state = widget.state;
    if (state.position.legs.isEmpty ||
        state.position.legs.any((leg) => leg.entryPremium == null)) {
      return const Text(
        'This historical snapshot predates per-leg price capture or has missing entry premiums. Its payoff cannot be reconstructed exactly, so no later execution price is substituted.',
      );
    }
    final strikes = state.position.legs
        .map((l) => l.contract.strike.toDouble())
        .toList();
    final minStrike = strikes.reduce((a, b) => a < b ? a : b);
    final maxStrike = strikes.reduce((a, b) => a > b ? a : b);
    final span = (maxStrike - minStrike).abs();
    final padding = span == 0 ? minStrike * 0.15 : span * 0.75;
    final baseLow = (minStrike - padding)
        .clamp(0.0, double.infinity)
        .toDouble();
    final baseHigh = maxStrike + padding;
    final capturedSpot = state.market.spot;
    final baseLowWithSpot = capturedSpot == null
        ? baseLow
        : math.min(baseLow, math.max(0.0, capturedSpot * 0.98)).toDouble();
    final baseHighWithSpot = capturedSpot == null
        ? baseHigh
        : math.max(baseHigh, capturedSpot * 1.02).toDouble();
    final chartCenter =
        capturedSpot ?? (baseLowWithSpot + baseHighWithSpot) / 2;
    final baseHalfRange = math
        .max(chartCenter - baseLowWithSpot, baseHighWithSpot - chartCenter)
        .toDouble();
    final halfRange = math.max(1.0, baseHalfRange * _zoom).toDouble();
    final low = math.max(0.0, chartCenter - halfRange).toDouble();
    final high = chartCenter + halfRange;
    double payoff(double underlying) {
      var result = 0.0;
      for (final leg in state.position.legs) {
        final premium = leg.entryPremium!;
        final intrinsic = leg.contract.optionType == OptionType.call
            ? (underlying - leg.contract.strike)
                  .clamp(0.0, double.infinity)
                  .toDouble()
            : (leg.contract.strike - underlying)
                  .clamp(0.0, double.infinity)
                  .toDouble();
        final perUnit = leg.side == PositionSide.buy
            ? intrinsic - premium
            : premium - intrinsic;
        result += perUnit * leg.quantity;
      }
      return result;
    }

    final points = List<double>.generate(
      81,
      (i) => low + (high - low) * i / 80,
    );
    final values = points.map(payoff).toList();
    if (values.any((v) => !v.isFinite))
      return const Text(
        'Historical payoff is unavailable because entry prices do not match the saved leg structure.',
      );
    final minY = values.reduce((a, b) => a < b ? a : b);
    final maxY = values.reduce((a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Historical expiry payoff · saved legs and entry premiums',
          style: TextStyle(color: Colors.black54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text(
              'Zoom',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Zoom in',
              visualDensity: VisualDensity.compact,
              onPressed: _zoom > 0.0625
                  ? () => setState(
                      () =>
                          _zoom = (_zoom * 0.75).clamp(0.0625, 8.0).toDouble(),
                    )
                  : null,
              icon: const Icon(Icons.zoom_in),
            ),
            IconButton(
              tooltip: 'Zoom out',
              visualDensity: VisualDensity.compact,
              onPressed: _zoom < 8.0
                  ? () => setState(
                      () =>
                          _zoom = (_zoom / 0.75).clamp(0.0625, 8.0).toDouble(),
                    )
                  : null,
              icon: const Icon(Icons.zoom_out),
            ),
            TextButton(
              onPressed: _zoom == 1.0
                  ? null
                  : () => setState(() => _zoom = 1.0),
              child: const Text('Reset'),
            ),
          ],
        ),
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: _PayoffPainter(
              points: points,
              values: values,
              minX: low,
              maxX: high,
              minY: minY,
              maxY: maxY,
              capturedSpot: state.market.spot,
              textColor: Theme.of(context).colorScheme.onSurface,
              lineColor: _positionBrand,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          state.market.spot == null
              ? 'Spot was not captured for this historical state. No current spot is substituted, so the historical spot marker cannot be shown.'
              : 'Spot at capture: ${state.market.spot!.toStringAsFixed(2)} · MTM P&L at capture: ${state.economics.pnl == null ? 'Unavailable' : '₹${state.economics.pnl!.toStringAsFixed(2)}'}',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const Text(
          'Static historical view. No live prices or scenario controls are used.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
      ],
    );
  }
}

class _PayoffPainter extends CustomPainter {
  _PayoffPainter({
    required this.points,
    required this.values,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.capturedSpot,
    required this.textColor,
    required this.lineColor,
  });
  final List<double> points, values;
  final double minX, maxX, minY, maxY;
  final double? capturedSpot;
  final Color textColor, lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final compact = size.width < 360;
    final left = compact ? 42.0 : 50.0;
    const right = 8.0, top = 18.0, bottom = 27.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    if (plot.width <= 0 || plot.height <= 0 || maxX <= minX) return;
    final yRange = (maxY - minY).abs() < 0.0001 ? 1.0 : maxY - minY;
    final xFor = (double x) =>
        plot.left + (x - minX) / (maxX - minX) * plot.width;
    final yFor = (double y) => plot.bottom - (y - minY) / yRange * plot.height;
    final grid = Paint()
      ..color = textColor.withValues(alpha: .10)
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr, maxLines: 1);
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final val = maxY - yRange * i / 4;
      final abs = val.abs();
      final label = abs >= 100000
          ? '${val < 0 ? '−' : ''}₹${(abs / 1000).toStringAsFixed(0)}k'
          : '${val < 0 ? '−' : ''}₹${abs.toStringAsFixed(0)}';
      tp.text = TextSpan(
        text: label,
        style: TextStyle(
          color: textColor.withValues(alpha: .68),
          fontSize: compact ? 9 : 10,
        ),
      );
      tp.layout(maxWidth: left - 7);
      tp.paint(canvas, Offset(plot.left - tp.width - 5, y - tp.height / 2));
    }
    final zeroY = yFor(0);
    if (zeroY >= plot.top && zeroY <= plot.bottom) {
      canvas.drawLine(
        Offset(plot.left, zeroY),
        Offset(plot.right, zeroY),
        Paint()
          ..color = textColor.withValues(alpha: .48)
          ..strokeWidth = 1.1,
      );
    }
    final pts = <Offset>[];
    for (var i = 0; i < points.length && i < values.length; i++) {
      if (points[i].isFinite && values[i].isFinite)
        pts.add(Offset(xFor(points[i]), yFor(values[i])));
    }
    if (pts.length > 1) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length - 1; i++) {
        final mid = Offset(
          (pts[i].dx + pts[i + 1].dx) / 2,
          (pts[i].dy + pts[i + 1].dy) / 2,
        );
        path.quadraticBezierTo(pts[i].dx, pts[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }
    final spot = capturedSpot;
    if (spot != null && spot >= minX && spot <= maxX) {
      final spotX = xFor(spot);
      // A solid, high-contrast line makes the exact historical capture spot
      // obvious even when the payoff curve crosses it. This value comes only
      // from this saved PositionState; no current/live spot is substituted.
      final marker = Paint()
        ..color = const Color(0xFFB45309)
        ..strokeWidth = 2.2;
      canvas.drawLine(
        Offset(spotX, plot.top),
        Offset(spotX, plot.bottom),
        marker,
      );
      tp.text = TextSpan(
        text: 'Spot ${spot.toStringAsFixed(2)}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      );
      tp.layout();
      final bw = tp.width + 12, bh = tp.height + 7;
      final bx = (spotX + 6 + bw > plot.right) ? spotX - bw - 6 : spotX + 6;
      final bubble = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          bx.clamp(plot.left, plot.right - bw),
          plot.top + 2,
          bw,
          bh,
        ),
        const Radius.circular(5),
      );
      canvas.drawRRect(bubble, Paint()..color = const Color(0xFF92400E));
      tp.paint(canvas, Offset(bubble.left + 6, bubble.top + 3.5));
    }
    void xLabel(String text, double x) {
      tp.text = TextSpan(
        text: text,
        style: TextStyle(
          color: textColor.withValues(alpha: .72),
          fontSize: compact ? 9 : 10,
        ),
      );
      tp.layout();
      tp.paint(
        canvas,
        Offset(x.clamp(plot.left, plot.right - tp.width), plot.bottom + 5),
      );
    }

    xLabel(minX.toStringAsFixed(0), plot.left);
    xLabel(maxX.toStringAsFixed(0), plot.right - 24);
  }

  @override
  bool shouldRepaint(covariant _PayoffPainter oldDelegate) =>
      points != oldDelegate.points ||
      values != oldDelegate.values ||
      minX != oldDelegate.minX ||
      maxX != oldDelegate.maxX ||
      minY != oldDelegate.minY ||
      maxY != oldDelegate.maxY ||
      capturedSpot != oldDelegate.capturedSpot ||
      textColor != oldDelegate.textColor ||
      lineColor != oldDelegate.lineColor;
}
