import 'package:flutter/material.dart';

import '../../../domain/trade/trade.dart';
import '../../../domain/trade/trade_status.dart';
import '../../../domain/trading/adjustment/adjustment_episode.dart';
import '../../../domain/trading/adjustment/adjustment_reason.dart';
import '../../../domain/trading/adjustment/position_view_assessment.dart';
import '../../../domain/trading/decision/decision_record.dart';
import '../../../domain/trading/position_state/position_state.dart';
import '../../../domain/trading/position_state/position_leg.dart';
import '../../../domain/trading/execution/option_contract.dart';
import '../../../domain/trading/trading_repository.dart';
import '../../../domain/trading/position_state_similarity_service.dart';

import '../../../domain/trading/adjustment/adjustment_proposal.dart';
import '../../../domain/trading/position_state/position_snapshot.dart';
import '../../../domain/trading/position_state/position_state_id.dart';
import '../../../domain/trading/position_state/market_snapshot.dart';
import '../../../domain/trading/position_state/geometry_snapshot.dart';
import '../../../domain/trading/position_state/economic_snapshot.dart';
import '../../../domain/trading/position_state/risk_snapshot.dart';
import 'positions_page.dart';

typedef ApplyAdjustmentProposal = Future<void> Function(
  AdjustmentProposal proposal,
);

/// Historical-decision assistant. Candidates come from the user's applied
/// adjustment history; this page does not invent or execute adjustments.
class AdjustmentAssistantPage extends StatefulWidget {
  const AdjustmentAssistantPage({
    super.key,
    required this.trade,
    required this.state,
    required this.repository,
    required this.onApplyProposal,
  });

  final Trade trade;
  final PositionState state;
  final TradingRepository repository;
  final ApplyAdjustmentProposal onApplyProposal;

  @override
  State<AdjustmentAssistantPage> createState() =>
      _AdjustmentAssistantPageState();
}

class _AdjustmentAssistantPageState extends State<AdjustmentAssistantPage> {
  List<AdjustmentEpisode> _episodes = const [];
  Map<String, Trade> _trades = const {};
  String? _selectedId;
  bool _loading = true;
  String? _error;
  double _scenarioSpot = 0;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final trades = await widget.repository.getTrades();
      final byId = <String, Trade>{};
      final episodes = <AdjustmentEpisode>[];
      final persistedEpisodesByTrade = <String, List<AdjustmentEpisode>>{};
      for (final trade in trades) {
        byId[trade.id.value] = trade;
        final saved = await widget.repository.getAdjustmentEpisodes(
          trade.id.value,
        );
        persistedEpisodesByTrade[trade.id.value] = saved;
        episodes.addAll(saved);
      }
      // Historical structural changes are evidence even if the older workflow did not
      // persist an AdjustmentEpisode. Reconstruct transitions (added, removed,
      // or quantity-changed legs) from CLOSED trades only.
      for (final trade in trades) {
        if (trade.status != TradeStatus.closed) continue;
        final states = [...trade.positionStates]
          ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
        final persistedPairs = (persistedEpisodesByTrade[trade.id.value] ?? [])
            .where((e) => e.afterPositionStateId != null)
            .map((e) => '${e.beforePositionStateId}->${e.afterPositionStateId}')
            .toSet();
        for (var i = 0; i + 1 < states.length; i++) {
          final before = states[i];
          final after = states[i + 1];
          final pair = '${before.id.value}->${after.id.value}';
          if (persistedPairs.contains(pair) || !_hasLegChange(before, after))
            continue;
          final beforeView = PositionViewAssessment(
            id: 'derived-before-${trade.id.value}-${before.id.value}',
            tradeId: trade.id.value,
            positionStateId: before.id.value,
            assessedAt: before.capturedAt,
            suggestedView: MarketView.uncertain,
            confirmedView: MarketView.uncertain,
            evidence: const [
              'Derived from consecutive saved position snapshots; no explicit decision record was available.',
            ],
          );
          final afterView = PositionViewAssessment(
            id: 'derived-after-${trade.id.value}-${after.id.value}',
            tradeId: trade.id.value,
            positionStateId: after.id.value,
            assessedAt: after.capturedAt,
            suggestedView: MarketView.uncertain,
            confirmedView: MarketView.uncertain,
            evidence: const [
              'Resulting state from the saved snapshot sequence.',
            ],
          );
          episodes.add(
            AdjustmentEpisode(
              id: 'derived-${trade.id.value}-${before.id.value}-${after.id.value}',
              tradeId: trade.id.value,
              beforePositionStateId: before.id.value,
              afterPositionStateId: after.id.value,
              beforeView: beforeView,
              afterView: afterView,
              reason: AdjustmentReason.other,
              reasonNote: 'Historical position change inferred from consecutive saved snapshots (not an explicitly recorded adjustment).',
              createdAt: after.capturedAt,
              confirmedAt: after.capturedAt,
              status: AdjustmentEpisodeStatus.applied,
            ),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        _trades = Map.unmodifiable(byId);
        _episodes = List.unmodifiable(episodes);
        _loading = false;
        _error = null;
        final candidates = _historicalAdjustments;
        if (_selectedId == null ||
            !candidates.any((e) => e.id == _selectedId)) {
          _selectedId = candidates.isEmpty ? null : candidates.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your adjustment history: $e';
      });
    }
  }

  List<AdjustmentEpisode> get _historicalAdjustments {
    final similarity = const PositionStateSimilarityService();
    final matches = similarity.findMatches(
      current: widget.state,
      trades: _trades.values,
      // Search the full closed-trade history; the result set is ranked by
      // similarity, but must not hide older relevant precedents arbitrarily.
      limit: 100000,
      minimumScore: 0.35,
    );
    // Once one state in a closed trade is a genuine structural/context match,
    // retain that trade's full subsequent transition chain. Otherwise a current
    // Bear Call Spread may find the opening state but lose the later steps that
    // converted it to an Iron Condor and eventually closed it.
    final relevantTradeIds = matches
        .map((match) => match.trade.id.value)
        .toSet();
    final similarityByTrade = <String, double>{};
    for (final match in matches) {
      final id = match.trade.id.value;
      final prior = similarityByTrade[id] ?? 0.0;
      if (match.score > prior) similarityByTrade[id] = match.score;
    }
    final current = widget.state.position;
    final results = _episodes.where((episode) {
      if (episode.tradeId == widget.trade.id.value) return false;

      // Explicit adjustment records and snapshot-inferred transitions are both
      // useful evidence, but they are not equivalent. Keep inferred transitions
      // eligible as lower-confidence precedents and label them clearly in the UI.
      if (episode.afterPositionStateId == null) return false;
      if (episode.status != AdjustmentEpisodeStatus.applied &&
          episode.status != AdjustmentEpisodeStatus.partiallyApplied) {
        return false;
      }
      final trade = _trades[episode.tradeId];
      if (trade == null) return false;
      final before = _stateFor(trade, episode.beforePositionStateId);
      final after = _stateFor(trade, episode.afterPositionStateId!);
      if (before == null || after == null) return false;
      // Match either side of the historical transition. This matters when a
      // current Iron Condor resembles the AFTER state of a closed trade that
      // started as a Bull Put Spread and later added call legs.
      if (!_hasLegChange(before, after)) return false;
      final sameUnderlying =
          before.position.underlying.toUpperCase() ==
          current.underlying.toUpperCase();
      // A structurally/contextually similar state makes this closed trade
      // relevant; include its later transitions too, so the full adjustment
      // journey remains visible even when later states no longer resemble the
      // current position.
      return sameUnderlying && relevantTradeIds.contains(episode.tradeId);
    }).toList();
    results.sort((a, b) {
      final aTrade = _trades[a.tradeId];
      final bTrade = _trades[b.tradeId];
      final aState = aTrade == null
          ? null
          : _stateFor(aTrade, a.beforePositionStateId);
      final bState = bTrade == null
          ? null
          : _stateFor(bTrade, b.beforePositionStateId);
      final aSameStrategy = aState?.position.strategy == currentStrategy;
      final bSameStrategy = bState?.position.strategy == currentStrategy;
      if (aSameStrategy != bSameStrategy) return aSameStrategy ? -1 : 1;
      final scoreOrder = (similarityByTrade[b.tradeId] ?? 0.0).compareTo(
        similarityByTrade[a.tradeId] ?? 0.0,
      );
      if (scoreOrder != 0) return scoreOrder;
      if (a.tradeId == b.tradeId) {
        // Show the historical journey in the order it happened.
        return a.createdAt.compareTo(b.createdAt);
      }
      return b.createdAt.compareTo(a.createdAt);
    });
    return List.unmodifiable(results);
  }

  bool _hasLegChange(PositionState before, PositionState after) {
    final beforeByKey = <String, int>{};
    final afterByKey = <String, int>{};
    for (final leg in before.position.legs) {
      beforeByKey[_legKey(leg)] =
          (beforeByKey[_legKey(leg)] ?? 0) + leg.quantity;
    }
    for (final leg in after.position.legs) {
      afterByKey[_legKey(leg)] = (afterByKey[_legKey(leg)] ?? 0) + leg.quantity;
    }
    return beforeByKey.length != afterByKey.length ||
        beforeByKey.keys.any((key) => beforeByKey[key] != afterByKey[key]);
  }

  bool _isExitOnlyChange(PositionState before, PositionState after) {
    final beforeByKey = <String, int>{};
    final afterByKey = <String, int>{};
    for (final leg in before.position.legs) {
      final key = _legKey(leg);
      beforeByKey[key] = (beforeByKey[key] ?? 0) + leg.quantity;
    }
    for (final leg in after.position.legs) {
      final key = _legKey(leg);
      afterByKey[key] = (afterByKey[key] ?? 0) + leg.quantity;
    }
    // No new/changed legs, and at least one existing leg quantity reduced.
    if (afterByKey.keys.any((key) => !beforeByKey.containsKey(key)))
      return false;
    var reduced = false;
    // Iterate the BEFORE keys too: a fully exited leg is absent from the
    // after-map, and must count as a reduction rather than being overlooked.
    for (final entry in beforeByKey.entries) {
      final afterQuantity = afterByKey[entry.key] ?? 0;
      if (afterQuantity > entry.value) return false;
      if (afterQuantity < entry.value) reduced = true;
    }
    return reduced;
  }

  dynamic get currentStrategy => widget.state.position.strategy;

  PositionState? _stateFor(Trade trade, String id) {
    for (final state in trade.positionStates) {
      if (state.id.value == id) return state;
    }
    return null;
  }

  AdjustmentEpisode? get _selectedEpisode {
    for (final episode in _historicalAdjustments) {
      if (episode.id == _selectedId) return episode;
    }
    return null;
  }

  Trade? _sourceTrade(AdjustmentEpisode? episode) =>
      episode == null ? null : _trades[episode.tradeId];

  PositionState? _before(AdjustmentEpisode? episode) {
    final trade = _sourceTrade(episode);
    return episode == null || trade == null
        ? null
        : _stateFor(trade, episode.beforePositionStateId);
  }

  PositionState? _after(AdjustmentEpisode? episode) {
    final trade = _sourceTrade(episode);
    final id = episode?.afterPositionStateId;
    return trade == null || id == null ? null : _stateFor(trade, id);
  }

  double? _pnl(PositionState state) =>
      state.economics.pnl ?? state.economics.grossUnrealizedPnl;

  double? _scenarioPnl(PositionState state, double spot) {
    final baseline = _pnl(state);
    if (baseline == null) return null;
    var value = baseline;
    for (final leg in state.position.legs) {
      final mark = leg.marketPrice;
      if (mark == null) return null;
      final strike = leg.contract.strike.toDouble();
      final intrinsic = leg.contract.optionType == OptionType.call
          ? (spot - strike).clamp(0.0, double.infinity).toDouble()
          : (strike - spot).clamp(0.0, double.infinity).toDouble();
      final sign = leg.side == PositionSide.buy ? 1.0 : -1.0;
      value += sign * (intrinsic - mark) * leg.quantity;
    }
    return value;
  }

  PositionState? _adjustedCurrentState(
    PositionState current,
    PositionState historicalBefore,
    PositionState historicalAfter,
  ) {
    // Transfer the historical exit pattern onto the current position by leg
    // identity. Never replace current legs with the historical trade's legs.
    final beforeQty = <String, int>{};
    final afterQty = <String, int>{};
    for (final leg in historicalBefore.position.legs) {
      final key = _legKey(leg);
      beforeQty[key] = (beforeQty[key] ?? 0) + leg.quantity;
    }
    for (final leg in historicalAfter.position.legs) {
      final key = _legKey(leg);
      afterQty[key] = (afterQty[key] ?? 0) + leg.quantity;
    }
    // Store the fraction exited in the historical trade, then apply that
    // fraction to the current leg quantity. Historical lot sizes can differ;
    // copying the historical absolute quantity can incorrectly close a leg.
    final exitedFraction = <String, double>{};
    for (final entry in beforeQty.entries) {
      final exited = entry.value - (afterQty[entry.key] ?? 0);
      if (exited > 0 && entry.value > 0) {
        exitedFraction[entry.key] = (exited / entry.value).clamp(0.0, 1.0);
      }
    }
    if (exitedFraction.isEmpty) return null;

    final adjustedLegs = <PositionLeg>[];
    for (final leg in current.position.legs) {
      final fraction = exitedFraction[_legKey(leg)] ?? 0.0;
      // Round to a valid whole-unit quantity; never exit more than the open leg.
      final exitQty = (leg.quantity * fraction).round().clamp(0, leg.quantity);
      final remaining = leg.quantity - exitQty;
      if (remaining <= 0) continue;
      adjustedLegs.add(
        PositionLeg(
          contract: leg.contract,
          side: leg.side,
          quantity: remaining,
          entryPremium: leg.entryPremium,
          marketPrice: leg.marketPrice,
        ),
      );
    }
    return PositionState(
      id: PositionStateId(
        'scenario-adjusted-${current.id.value}-${historicalAfter.id.value}',
      ),
      tradeId: current.tradeId,
      capturedAt: current.capturedAt,
      position: PositionSnapshot(
        underlying: current.position.underlying,
        expiry: current.position.expiry,
        legs: adjustedLegs,
        strategy: current.position.strategy,
        entryDebitCredit: current.position.entryDebitCredit,
        comments: current.position.comments,
        plannedRules: current.position.plannedRules,
      ),
      market: current.market,
      geometry: current.geometry,
      // This is a simulated leg set, so retain the known baseline only as
      // context; the payoff widget re-prices the individual legs interactively.
      economics: current.economics,
      risk: current.risk,
    );
  }

  String _money(num? value) => value == null
      ? 'Unavailable'
      : '${value < 0 ? '−' : ''}₹${value.abs().toStringAsFixed(0)}';

  String _legLabel(PositionLeg leg) =>
      '${leg.side.name.toUpperCase()} ${leg.contract.strike} '
      '${leg.contract.optionType.name.toUpperCase()} · qty ${leg.quantity}';

  String _reasonFor(AdjustmentEpisode episode) {
    final note = episode.reasonNote?.trim();
    if (note != null && note.isNotEmpty) return note;
    final observation = episode.decision?.observation?.trim();
    if (observation != null && observation.isNotEmpty) return observation;
    return episode.reason.label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = _historicalAdjustments;
    final selected = _selectedEpisode;
    final before = _before(selected);
    final after = _after(selected);
    final sourceTrade = _sourceTrade(selected);
    final center =
        widget.state.market.spot != null && widget.state.market.spot! > 0
        ? widget.state.market.spot!
        : (widget.state.position.legs.isEmpty
              ? 1.0
              : widget.state.position.legs
                        .map((l) => l.contract.strike.toDouble())
                        .reduce((a, b) => a + b) /
                    widget.state.position.legs.length);
    final spot = (_scenarioSpot > 0 ? _scenarioSpot : center)
        .clamp(
          (center * .85).clamp(1.0, double.infinity).toDouble(),
          center * 1.15,
        )
        .toDouble();

    return Scaffold(
      appBar: AppBar(title: const Text('Adjustment assistant')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // Compact context only; no duplicated journey summary or timeline.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.state.position.underlying} · ${widget.state.position.strategy.name}',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.state.position.legs.length} current legs · captured ${widget.state.capturedAt.toLocal()}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (final leg in widget.state.position.legs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        _legLabel(leg),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  const Divider(),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _metric('Current MTM', _money(_pnl(widget.state))),
                      _metric(
                        'Spot',
                        widget.state.market.spot?.toStringAsFixed(2) ??
                            'Unavailable',
                      ),
                      _metric(
                        'Margin',
                        _money(
                          widget.state.economics.margin ??
                              widget.state.economics.capitalDeployed,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Adjustments from your similar trades',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Recorded adjustments are shown separately from transitions inferred from saved snapshots. An inferred transition can help explore what changed, but does not prove which decision you made.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (!_loading && candidates.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.history_toggle_off, size: 28),
                    const SizedBox(height: 8),
                    Text(
                      'No matching historical transitions yet',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'No structurally matching historical transition was found. Similar positions alone do not establish an adjustment; saved decision records make historical precedents more reliable.',
                    ),
                  ],
                ),
              ),
            ),
          for (final episode in candidates)
            _historicalOptionCard(context, episode, episode.id == selected?.id),
          if (selected != null && before != null && after != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        _isInferredEpisode(selected)
                            ? 'Historical transition selected · inferred'
                            : 'Historical adjustment selected · recorded',
                      ),
                      subtitle: Text(
                        'Source trade ${selected.tradeId} · ${selected.createdAt.toLocal()}\n${_reasonFor(selected)}',
                      ),
                    ),
                    const Divider(height: 1),
                    ExpansionTile(
                      key: const PageStorageKey<String>(
                        'adjustment-before-section',
                      ),
                      initiallyExpanded: false,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 12),
                      title: const Text('Before transition · current position'),
                      subtitle: const Text(
                        'Current legs, risk context and interactive payoff',
                      ),
                      children: [
                        _stateComparison('Current open position', widget.state),
                        const SizedBox(height: 10),
                        PositionStateInteractivePayoffPanel(
                          key: ValueKey(
                            'current-payoff-${widget.state.id.value}',
                          ),
                          trade: widget.trade,
                          state: widget.state,
                        ),
                      ],
                    ),
                    const Divider(height: 1),
                    ExpansionTile(
                      key: PageStorageKey<String>(
                        'adjustment-after-${selected.id}',
                      ),
                      initiallyExpanded: false,
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 12),
                      title: const Text(
                        'After transition · simulated position',
                      ),
                      subtitle: const Text(
                        'Adjusted legs, risk context and separate interactive payoff',
                      ),
                      children: [
                        Builder(
                          builder: (context) {
                            final adjusted = _adjustedCurrentState(
                              widget.state,
                              before,
                              after,
                            );
                            if (adjusted == null) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Text(
                                  'This historical exit pattern does not map to the current legs, so an adjusted payoff cannot be calculated.',
                                ),
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _stateComparison(
                                  'Simulated position after adjustment',
                                  adjusted,
                                ),
                                const SizedBox(height: 10),
                                PositionStateInteractivePayoffPanel(
                                  key: ValueKey(
                                    'adjusted-payoff-${selected.id}-${adjusted.id.value}',
                                  ),
                                  trade: widget.trade,
                                  state: adjusted,
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (selected != null)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  final beforeState = _before(selected);
                  final afterState = _after(selected);
                  if (beforeState == null || afterState == null) return;
                  final similarity = const PositionStateSimilarityService();
                  final matchesBefore = similarity
                      .findMatches(
                        current: widget.state,
                        trades: [_trades[selected.tradeId]!],
                        limit: 100000,
                        minimumScore: 0.35,
                      )
                      .any(
                        (match) => match.state.id.value == beforeState.id.value,
                      );
                  if (!matchesBefore) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'This historical transition is shown as a precedent because your current position resembles its resulting state. Applying the same leg additions again could duplicate exposure.',
                        ),
                      ),
                    );
                    return;
                  }
                  final operations = _deriveTransitionOperations(
                    beforeState,
                    afterState,
                  );
                  if (operations.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No leg changes could be derived from these snapshots.',
                        ),
                      ),
                    );
                    return;
                  }
                  widget.onApplyProposal(
                    AdjustmentProposal(
                      id: 'historical-${selected.id}-${DateTime.now().microsecondsSinceEpoch}',
                      tradeId: widget.trade.id.value,
                      sourcePositionStateId: widget.state.id.value,
                      perspective: MarketView.uncertain,
                      title: 'Historical position transition',
                      explanation: _isInferredEpisode(selected)
                          ? 'Based on a transition inferred from consecutive snapshots in historical episode ${selected.id}; the original decision was not explicitly recorded. Treat this as a hypothesis, verify the market context and review every leg and price before confirming. This does not execute a trade.'
                          : 'Based on explicitly recorded historical episode ${selected.id}. Review every added, reduced, exited, or increased leg and its price before confirming. This does not execute a trade.',
                      operations: operations,
                      precedentEpisodeIds: [selected.id],
                      createdAt: DateTime.now(),
                      assumptions: const [
                        'Historical quantities must be reviewed against the current position.',
                        'This selection does not execute any trade.',
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.logout),
                label: const Text('Open exit-leg workflow'),
              ),
            ),
        ],
      ),
    );
  }

  List<ProposedLegOperation> _deriveTransitionOperations(
    PositionState before,
    PositionState after,
  ) {
    final operations = <ProposedLegOperation>[];
    final beforeByKey = <String, PositionLeg>{};
    final afterByKey = <String, PositionLeg>{};
    for (final leg in before.position.legs) {
      beforeByKey[_legKey(leg)] = leg;
    }
    for (final leg in after.position.legs) {
      afterByKey[_legKey(leg)] = leg;
    }
    for (final entry in beforeByKey.entries) {
      final oldLeg = entry.value;
      final newLeg = afterByKey[entry.key];
      final afterQty = newLeg?.quantity ?? 0;
      final delta = afterQty - oldLeg.quantity;
      if (delta < 0) {
        final exited = -delta;
        operations.add(
          ProposedLegOperation(
            type: afterQty == 0
                ? ProposedLegOperationType.exitLeg
                : ProposedLegOperationType.reduceLegQuantity,
            contract: oldLeg.contract,
            existingLegKey: entry.key,
            side: oldLeg.side == PositionSide.buy ? 'sell' : 'buy',
            quantity: exited,
            assumedPrice: oldLeg.marketPrice,
          ),
        );
      } else if (delta > 0) {
        operations.add(
          ProposedLegOperation(
            type: ProposedLegOperationType.increaseLegQuantity,
            contract: oldLeg.contract,
            existingLegKey: entry.key,
            side: oldLeg.side.name,
            quantity: delta,
            assumedPrice: newLeg?.marketPrice,
          ),
        );
      }
    }
    for (final entry in afterByKey.entries) {
      if (beforeByKey.containsKey(entry.key)) continue;
      final leg = entry.value;
      operations.add(
        ProposedLegOperation(
          type: ProposedLegOperationType.addLeg,
          contract: leg.contract,
          side: leg.side.name,
          quantity: leg.quantity,
          assumedPrice: leg.marketPrice,
        ),
      );
    }
    return operations;
  }

  String _legKey(PositionLeg leg) =>
      '${leg.contract.underlying}|${leg.contract.expiry}|${leg.contract.strike}|${leg.contract.optionType.name}|${leg.side.name}';

  bool _isInferredEpisode(AdjustmentEpisode episode) {
    final note = episode.reasonNote?.toLowerCase() ?? '';
    return episode.id.startsWith('derived-') ||
        note.contains('inferred from consecutive saved snapshots') ||
        note.contains('not an explicitly recorded adjustment');
  }

  Widget _historicalOptionCard(
    BuildContext context,
    AdjustmentEpisode episode,
    bool selected,
  ) {
    final theme = Theme.of(context);
    final trade = _trades[episode.tradeId];
    final before = _stateFor(trade!, episode.beforePositionStateId);
    final after = episode.afterPositionStateId == null
        ? null
        : _stateFor(trade, episode.afterPositionStateId!);
    final pnlBefore = before == null ? null : _pnl(before);
    final pnlAfter = after == null ? null : _pnl(after);
    final action = episode.decision?.action;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: .35)
          : null,
      child: InkWell(
        onTap: () => setState(() {
          _selectedId = episode.id;
          _scenarioSpot = 0;
        }),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isInferredEpisode(episode)
                              ? 'Snapshot-inferred transition'
                              : action == null
                              ? episode.reason.label
                              : _actionLabel(action),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Source trade ${episode.tradeId} · ${episode.createdAt.toLocal()}',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (_isInferredEpisode(episode))
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Inferred from snapshots · decision not recorded',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.tertiary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              if ((episode.reasonNote ?? episode.decision?.observation ?? '')
                  .trim()
                  .isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  episode.reasonNote ?? episode.decision!.observation!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _metric('MTM before', _money(pnlBefore)),
                  _metric('MTM after', _money(pnlAfter)),
                  _metric(
                    'Net realized',
                    _money(after?.economics.netRealizedPnl),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stateComparison(String label, PositionState state) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 5),
          Text(
            '${state.position.strategy.name} · ${state.position.legs.length} legs · ${state.capturedAt.toLocal()}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 7),
          for (final leg in state.position.legs)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(child: Text(_legLabel(leg))),
                  Text(
                    'Mark ${leg.marketPrice?.toStringAsFixed(2) ?? 'Unavailable'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          const Divider(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric('MTM', _money(_pnl(state))),
              _metric(
                'Margin',
                _money(
                  state.economics.margin ?? state.economics.capitalDeployed,
                ),
              ),
              _metric('Charges', _money(state.economics.actualCharges)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) =>
      Chip(visualDensity: VisualDensity.compact, label: Text('$label: $value'));

  String _actionLabel(DecisionAction action) => switch (action) {
    DecisionAction.hold => 'Hold',
    DecisionAction.adjust => 'Adjust',
    DecisionAction.exit => 'Exit',
    DecisionAction.add => 'Add exposure',
    DecisionAction.reduce => 'Reduce exposure',
    DecisionAction.partialExit => 'Partial exit',
  };
}
