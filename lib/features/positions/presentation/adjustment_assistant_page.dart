import 'package:flutter/material.dart';

import '../../../domain/trade/trade.dart';
import '../../../domain/trading/adjustment/adjustment_episode.dart';
import '../../../domain/trading/adjustment/adjustment_proposal.dart';
import '../../../domain/trading/adjustment/adjustment_reason.dart';
import '../../../domain/trading/adjustment/position_view_assessment.dart';
import '../../../domain/trading/adjustment/adjustment_suggestion_service.dart';
import '../../../domain/trading/position_state/position_state.dart';
import '../../../domain/trading/trading_repository.dart';

typedef ApplyAdjustmentProposal = Future<void> Function(AdjustmentProposal proposal);

/// Personal adjustment assistant. It explores prior decisions and routes a
/// selected proposal back to the existing position-edit/exit workflow; it does
/// not create executions itself.
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
  State<AdjustmentAssistantPage> createState() => _AdjustmentAssistantPageState();
}

class _AdjustmentAssistantPageState extends State<AdjustmentAssistantPage> {
  MarketView _perspective = MarketView.neutral;
  MarketView _suggested = MarketView.uncertain;
  AdjustmentReason _reason = AdjustmentReason.other;
  final TextEditingController _reasonNote = TextEditingController();
  List<AdjustmentEpisode> _episodes = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEpisodes();
  }

  @override
  void dispose() {
    _reasonNote.dispose();
    super.dispose();
  }

  Future<void> _loadEpisodes() async {
    try {
      final episodes = await widget.repository.getAdjustmentEpisodes(widget.trade.id.value);
      if (!mounted) return;
      setState(() { _episodes = episodes; _loading = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Could not load adjustment history: $error'; });
    }
  }

  List<AdjustmentEpisode> get _matchingEpisodes => _episodes
      .where((e) => e.beforeView.confirmedView == _perspective)
      .toList(growable: false);

  List<AdjustmentProposal> get _proposals => AdjustmentSuggestionService().buildCandidates(
    tradeId: widget.trade.id.value,
    state: widget.state,
    perspective: _perspective,
    now: DateTime.now(),
    history: _episodes,
  );

  Future<void> _saveAssessment() async {
    if (_saving) return;
    setState(() => _saving = true);
    final now = DateTime.now();
    final assessment = PositionViewAssessment(
      id: 'view-${widget.state.id.value}-${now.microsecondsSinceEpoch}',
      tradeId: widget.trade.id.value,
      positionStateId: widget.state.id.value,
      assessedAt: now,
      suggestedView: _suggested,
      confirmedView: _perspective,
      evidence: [
        'Assessment is user-confirmed.',
        if (widget.state.market.spot != null) 'Spot recorded: ${widget.state.market.spot}',
        if (widget.state.market.vix != null) 'VIX recorded: ${widget.state.market.vix}',
      ],
      correctionNote: _suggested != _perspective ? 'User corrected suggested view.' : null,
    );
    try {
      final episode = AdjustmentEpisode(
        id: 'episode-${now.microsecondsSinceEpoch}',
        tradeId: widget.trade.id.value,
        beforePositionStateId: widget.state.id.value,
        beforeView: assessment,
        reason: _reason,
        reasonNote: _reasonNote.text.trim().isEmpty ? null : _reasonNote.text.trim(),
        createdAt: now,
        status: AdjustmentEpisodeStatus.proposed,
      );
      await widget.repository.saveAdjustmentEpisode(episode);
      await _loadEpisodes();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Market view and adjustment context saved. No legs were changed.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save adjustment context: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _viewLabel(MarketView view) => switch (view) {
    MarketView.bullish => 'Bullish', MarketView.bearish => 'Bearish',
    MarketView.neutral => 'Neutral', MarketView.uncertain => 'Uncertain',
  };

  @override
  Widget build(BuildContext context) {
    final proposals = _proposals;
    return Scaffold(
      appBar: AppBar(title: const Text('Adjustment assistant')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Current position', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('${widget.state.position.underlying} · ${widget.state.position.strategy.name}'),
            Text('${widget.state.position.legs.length} active legs · snapshot ${widget.state.capturedAt.toLocal()}'),
            Text('Spot: ${widget.state.market.spot?.toStringAsFixed(2) ?? 'Unavailable'} · VIX: ${widget.state.market.vix?.toStringAsFixed(2) ?? 'Unavailable'}'),
          ]))),
          Text('Market view', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          DropdownButtonFormField<MarketView>(
            value: _suggested,
            decoration: const InputDecoration(labelText: 'App-suggested view (confirm/correct below)', border: OutlineInputBorder()),
            items: MarketView.values.map((v) => DropdownMenuItem(value: v, child: Text(_viewLabel(v)))).toList(),
            onChanged: (v) => setState(() => _suggested = v ?? MarketView.uncertain),
          ),
          const SizedBox(height: 10),
          SegmentedButton<MarketView>(
            segments: const [
              ButtonSegment(value: MarketView.bullish, label: Text('Bullish'), icon: Icon(Icons.trending_up)),
              ButtonSegment(value: MarketView.neutral, label: Text('Neutral'), icon: Icon(Icons.swap_horiz)),
              ButtonSegment(value: MarketView.bearish, label: Text('Bearish'), icon: Icon(Icons.trending_down)),
            ],
            selected: {_perspective},
            onSelectionChanged: (v) => setState(() => _perspective = v.first),
          ),
          const SizedBox(height: 8),
          Text('Reason for adjustment', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          DropdownButtonFormField<AdjustmentReason>(
            value: _reason,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: AdjustmentReason.values.map((r) => DropdownMenuItem(value: r, child: Text(r.label))).toList(),
            onChanged: (v) => setState(() => _reason = v ?? AdjustmentReason.other),
          ),
          const SizedBox(height: 8),
          TextField(controller: _reasonNote, decoration: const InputDecoration(labelText: 'Optional note', border: OutlineInputBorder()), maxLines: 2),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _saving ? null : _saveAssessment, icon: const Icon(Icons.save_outlined), label: Text(_saving ? 'Saving…' : 'Save view and reason')),
          const Divider(height: 28),
          Text('Historical precedents · ${_viewLabel(_perspective)}', style: Theme.of(context).textTheme.titleLarge),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          if (!_loading && _matchingEpisodes.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No saved adjustment episodes for this confirmed market view yet. New episodes will build your personal history.')),
          for (final episode in _matchingEpisodes.take(10)) Card(child: ListTile(
            title: Text('${episode.reason.label} · ${episode.status.name}'),
            subtitle: Text('${episode.createdAt.toLocal()}${episode.reasonNote == null ? '' : '\n${episode.reasonNote}'}'),
            trailing: Text(_viewLabel(episode.beforeView.confirmedView)),
          )),
          const Divider(height: 28),
          Text('Possible actions to review', style: Theme.of(context).textTheme.titleLarge),
          const Text('These are review prompts, not automatic recommendations. Historical matches are shown separately from outcomes. Review exact legs, quantity, quote and payoff in the existing position workflow before confirming.'),
          const SizedBox(height: 8),
          for (final proposal in proposals) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(proposal.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4), Text(proposal.explanation),
            const SizedBox(height: 6), Text('Perspective: ${_viewLabel(proposal.perspective)} · ${proposal.precedentEpisodeIds.length} same-view history records', style: Theme.of(context).textTheme.bodySmall),
            if (proposal.assumptions.isNotEmpty) ...[const SizedBox(height: 4), Text(proposal.assumptions.join('\n'), style: Theme.of(context).textTheme.bodySmall)],
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () async {
              final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                title: const Text('Review this adjustment'),
                content: Text('${proposal.title}\n\n${proposal.explanation}\n\nNo leg changes will be made by this dialog. You will review and confirm the actual leg operations in the existing position workflow.'),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue to leg review'))],
              ));
              if (accepted == true && mounted) await widget.onApplyProposal(proposal);
            }, child: const Text('Select and review')),
          ]))),
        ],
      ),
    );
  }
}
