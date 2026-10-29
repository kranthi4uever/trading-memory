import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'features/positions/presentation/positions_page.dart';
import 'features/positions/presentation/portfolio_performance_page.dart';

import 'features/market_data/presentation/nifty_option_chain_page.dart';
import 'features/market_data/market_data_auth.dart';
import 'domain/trade/strategy_structure.dart';
import 'domain/trade/trade.dart';
import 'domain/trade/trade_id.dart';
import 'domain/trade/trade_status.dart';
import 'domain/trading/execution/execution.dart';
import 'domain/trading/execution/execution_id.dart';
import 'domain/trading/execution/execution_source.dart';
import 'domain/trading/execution/expiry_date.dart';
import 'domain/trading/execution/option_contract.dart';
import 'domain/trading/position_state/economic_snapshot.dart';
import 'domain/trading/position_state/geometry_snapshot.dart';
import 'domain/trading/position_state/market_snapshot.dart';
import 'domain/trading/position_state/position_leg.dart';
import 'domain/trading/position_state/position_snapshot.dart';
import 'domain/trading/position_state/position_state.dart';
import 'domain/trading/position_state/position_state_id.dart';
import 'domain/trading/position_state/risk_snapshot.dart';
import 'domain/trading/trading_repository.dart';
import 'domain/trading/position_state_similarity_service.dart';
import 'infrastructure/persistence/sqlite/sqlite_trading_repository.dart';
import 'infrastructure/persistence/sqlite/trading_database.dart';

const _brand = Color(0xFF176B87);
const _pageBackground = Color(0xFFF7F9FA);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = TradingDatabase();
  final repository = SqliteTradingRepository(database);
  runApp(TradingMemoryApp(repository: repository));
}

class TradingMemoryApp extends StatelessWidget {
  const TradingMemoryApp({super.key, required this.repository});
  final TradingRepository repository;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Trading Memory',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Arial',
      colorScheme: ColorScheme.fromSeed(seedColor: _brand),
      scaffoldBackgroundColor: _pageBackground,
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        displayMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        displaySmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        headlineLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16),
        bodyMedium: TextStyle(fontSize: 14),
        bodySmall: TextStyle(fontSize: 12),
        labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    ),
    home: PositionsHome(repository: repository),
  );
}

class PositionsHome extends StatefulWidget {
  const PositionsHome({super.key, required this.repository});
  final TradingRepository repository;

  @override
  State<PositionsHome> createState() => _PositionsHomeState();
}

enum _PositionListMode { open, closed }

enum _PositionSortMode { lossesFirst, underlying, expiry, created }

class _PositionsHomeState extends State<PositionsHome> {
  int _tab = 0;
  _PositionListMode _listMode = _PositionListMode.open;
  _PositionSortMode _sortMode = _PositionSortMode.lossesFirst;
  String _closedUnderlying = 'All';

  @override
  Widget build(BuildContext context) {
    const titles = [
      'Positions',
      'Strategy Builder',
      'Configurations',
      'Portfolio',
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab]),
        backgroundColor: _pageBackground,
      ),
      body: SafeArea(
        child: switch (_tab) {
          0 => _positionsBody(),
          1 => StrategyBuilderHome(
            onCreatePaperTrade: _createPaperTrade,
            onImportBrokerTrades: _showBrokerImportPlaceholder,
          ),
          2 => const ConfigurationsHome(),
          _ => PortfolioPerformancePage(repository: widget.repository),
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.stacked_line_chart),
            label: 'Positions',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            label: 'Strategy Builder',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'Configurations',
          ),
          NavigationDestination(
            icon: Icon(Icons.query_stats),
            label: 'Portfolio',
          ),
        ],
      ),
    );
  }

  Future<void> _createPaperTrade() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PaperTradeEntryPage(repository: widget.repository),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showBrokerImportPlaceholder() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Broker trade import will be added in a separate change.',
        ),
      ),
    );
  }

  Future<void> _openTrade(Trade trade) async {
    if (trade.status == TradeStatus.draft) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PaperTradeEntryPage(
            repository: widget.repository,
            existingTrade: trade,
          ),
        ),
      );
    } else {
      final allTrades = await widget.repository.getTrades();
      final orderedStates = [...trade.positionStates]
        ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
      final currentState = orderedStates.isEmpty ? null : orderedStates.last;
      final similarPositionMatches =
          trade.status == TradeStatus.closed || currentState == null
          ? const <SimilarPositionMatch>[]
          : const PositionStateSimilarityService().findMatches(
              current: currentState,
              trades: allTrades,
              limit: 10,
            );
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PositionsPage(
            trade: trade,
            similarMatches: similarPositionMatches,
            repository: widget.repository,
          ),
        ),
      );
    }
    if (mounted) setState(() {});
  }

  DateTime _expiryOf(Trade trade) => trade.executions
      .map((execution) => execution.contract.expiry.value)
      .reduce((a, b) => a.isBefore(b) ? a : b);

  DateTime _createdAtOf(Trade trade) => trade.executions
      .map((execution) => execution.executedAt)
      .reduce((a, b) => a.isBefore(b) ? a : b);

  double? _pnlOf(Trade trade) {
    final states = [...trade.positionStates]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final latest = states.isEmpty ? null : states.last;
    if (latest?.economics.pnl != null) return latest!.economics.pnl;

    // A closed trade can still show gross realized P&L from its recorded
    // buy/sell cashflows even if an economics snapshot was not saved.
    if (trade.status == TradeStatus.closed) {
      return trade.executions.fold<double>(
        0,
        (total, execution) =>
            total +
            execution.price *
                execution.quantity *
                (execution.side == ExecutionSide.sell ? 1 : -1),
      );
    }

    // For open positions, use only complete saved entry/mark pairs. This is
    // explicitly a last-saved-mark estimate, not a claim of live quote data.
    final legs = latest?.position.legs ?? const <PositionLeg>[];
    if (legs.isEmpty) return null;
    var total = 0.0;
    for (final leg in legs) {
      final entry = leg.entryPremium;
      final mark = leg.marketPrice;
      if (entry == null || mark == null) return null;
      final sign = leg.side.name == 'buy' ? 1.0 : -1.0;
      total += (mark - entry) * leg.quantity * sign;
    }
    return total;
  }

  String _dateLabel(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

  List<Trade> _sortPositions(List<Trade> trades) {
    final result = List<Trade>.of(trades);
    result.sort((a, b) {
      switch (_sortMode) {
        case _PositionSortMode.lossesFirst:
          final ap = _pnlOf(a);
          final bp = _pnlOf(b);
          if (ap == null && bp != null) return 1;
          if (ap != null && bp == null) return -1;
          if (ap != null && bp != null) {
            final aLoss = ap < 0;
            final bLoss = bp < 0;
            if (aLoss != bLoss) return aLoss ? -1 : 1;
            if (aLoss && bLoss && ap != bp) return ap.compareTo(bp);
            if (!aLoss && !bLoss && ap != bp) return ap.compareTo(bp);
          }
          return _expiryOf(a).compareTo(_expiryOf(b));
        case _PositionSortMode.underlying:
          final underlyingCompare = a.executions.first.contract.underlying
              .compareTo(b.executions.first.contract.underlying);
          return underlyingCompare != 0
              ? underlyingCompare
              : _expiryOf(a).compareTo(_expiryOf(b));
        case _PositionSortMode.expiry:
          final expiryCompare = _expiryOf(a).compareTo(_expiryOf(b));
          return expiryCompare != 0
              ? expiryCompare
              : _createdAtOf(b).compareTo(_createdAtOf(a));
        case _PositionSortMode.created:
          return _createdAtOf(b).compareTo(_createdAtOf(a));
      }
    });
    return result;
  }

  Widget _positionsBody() => FutureBuilder<List<Trade>>(
    future: widget.repository.getTrades(),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load saved trades. ${snapshot.error}'),
          ),
        );
      }

      final allTrades = snapshot.data ?? const <Trade>[];
      final candidates = allTrades
          .where(
            (trade) => _listMode == _PositionListMode.closed
                ? trade.status == TradeStatus.closed
                : trade.status != TradeStatus.closed,
          )
          .toList();
      final underlyings = <String>{
        'All',
        ...candidates.map(
          (trade) => trade.executions.first.contract.underlying,
        ),
      }.toList()..sort();
      if (_listMode == _PositionListMode.closed &&
          !underlyings.contains(_closedUnderlying)) {
        _closedUnderlying = 'All';
      }
      final filtered =
          _listMode == _PositionListMode.closed && _closedUnderlying != 'All'
          ? candidates
                .where(
                  (trade) =>
                      trade.executions.first.contract.underlying ==
                      _closedUnderlying,
                )
                .toList()
          : candidates;
      final trades = _sortPositions(filtered);

      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<_PositionListMode>(
                  segments: const [
                    ButtonSegment(
                      value: _PositionListMode.open,
                      label: Text('Open positions'),
                    ),
                    ButtonSegment(
                      value: _PositionListMode.closed,
                      label: Text('Closed positions'),
                    ),
                  ],
                  selected: {_listMode},
                  onSelectionChanged: (selection) => setState(() {
                    _listMode = selection.first;
                  }),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (_listMode == _PositionListMode.closed) ...[
                      const Text('Underlying'),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: underlyings.contains(_closedUnderlying)
                              ? _closedUnderlying
                              : 'All',
                          items: underlyings
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) => setState(
                            () => _closedUnderlying = value ?? 'All',
                          ),
                        ),
                      ),
                    ] else ...[
                      const Expanded(
                        child: Text(
                          'Losses first by default',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    DropdownButton<_PositionSortMode>(
                      value: _sortMode,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: _PositionSortMode.lossesFirst,
                          child: Text('Losses first'),
                        ),
                        DropdownMenuItem(
                          value: _PositionSortMode.expiry,
                          child: Text('Expiry date'),
                        ),
                        DropdownMenuItem(
                          value: _PositionSortMode.underlying,
                          child: Text('Underlying'),
                        ),
                        DropdownMenuItem(
                          value: _PositionSortMode.created,
                          child: Text('Created date'),
                        ),
                      ],
                      onChanged: (value) => setState(
                        () =>
                            _sortMode = value ?? _PositionSortMode.lossesFirst,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: trades.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      const SizedBox(height: 32),
                      Icon(
                        _listMode == _PositionListMode.open
                            ? Icons.note_add_outlined
                            : Icons.history,
                        size: 42,
                        color: _brand,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _listMode == _PositionListMode.open
                            ? 'No open positions yet'
                            : 'No closed positions found',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _listMode == _PositionListMode.open
                            ? 'Create a paper trade or import trades from your broker to start building your position history.'
                            : 'Closed positions will appear here. Filter by underlying when you have historical trades.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.black54,
                          height: 1.4,
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                    itemCount: trades.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) =>
                        _positionBanner(trades[index]),
                  ),
          ),
        ],
      );
    },
  );

  Widget _positionBanner(Trade trade) {
    final pnl = _pnlOf(trade);
    final isLoss = pnl != null && pnl < 0;
    final pnlKnown = pnl != null;
    final background = !pnlKnown
        ? Colors.white
        : isLoss
        ? const Color(0xFFFFE9E7)
        : const Color(0xFFE7F5EA);
    final border = !pnlKnown
        ? const Color(0xFFE2E7EA)
        : isLoss
        ? const Color(0xFFE5A29C)
        : const Color(0xFF9ACDA5);
    final underlying = trade.executions.first.contract.underlying;
    final statusLabel = trade.status == TradeStatus.draft
        ? 'DRAFT'
        : 'CONFIRMED';
    return Card(
      color: background,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Row(
          children: [
            Expanded(
              child: Text(
                underlying,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            if (_listMode == _PositionListMode.open)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: trade.status == TradeStatus.draft
                      ? const Color(0xFFFFF1E5)
                      : const Color(0xFFEAF3F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusLabel,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Expiry ${_dateLabel(_expiryOf(trade))} · ${trade.strategy.name}'
            '${pnl != null && trade.status == TradeStatus.confirmed && (trade.positionStates.isEmpty || trade.positionStates.last.economics.pnl == null) ? ' · Last saved marks' : ''}'
            '${pnl != null && trade.status == TradeStatus.closed && (trade.positionStates.isEmpty || trade.positionStates.last.economics.pnl == null) ? ' · Gross realized estimate' : ''}',
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  pnl == null
                      ? 'P&L unavailable'
                      : '${isLoss ? '−' : ''}₹${pnl.abs().toStringAsFixed(2)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: !pnlKnown
                        ? Colors.black54
                        : isLoss
                        ? const Color(0xFFB3261E)
                        : const Color(0xFF16743B),
                  ),
                ),
                const SizedBox(height: 4),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ],
        ),
        onTap: () => _openTrade(trade),
      ),
    );
  }
}

class StrategyBuilderHome extends StatelessWidget {
  const StrategyBuilderHome({
    super.key,
    required this.onCreatePaperTrade,
    required this.onImportBrokerTrades,
  });
  final VoidCallback onCreatePaperTrade;
  final VoidCallback onImportBrokerTrades;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        'Build a strategy',
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        'Choose real trades from your broker or create a paper trade using the option chain.',
        style: TextStyle(color: Colors.black54, height: 1.4),
      ),
      const SizedBox(height: 18),
      Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.show_chart)),
          title: const Text(
            'Create paper trade',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: const Text('Use the option chain and strategy templates.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onCreatePaperTrade,
        ),
      ),
      Card(
        child: ListTile(
          leading: const CircleAvatar(
            child: Icon(Icons.download_for_offline_outlined),
          ),
          title: const Text(
            'Import trades from broker',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: const Text(
            'Select real executions and group them into a position.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onImportBrokerTrades,
        ),
      ),
    ],
  );
}

class ConfigurationsHome extends StatelessWidget {
  const ConfigurationsHome({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        'Configurations',
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        'Trading targets, risk thresholds, default lots, hedge width, and display preferences will be configured here in separate changes.',
        style: TextStyle(color: Colors.black54, height: 1.45),
      ),
      const SizedBox(height: 16),
      const Card(
        child: ListTile(
          leading: Icon(Icons.notifications_active_outlined),
          title: Text('Target and risk triggers'),
          subtitle: Text('Coming in a later change.'),
        ),
      ),
      const Card(
        child: ListTile(
          leading: Icon(Icons.tune),
          title: Text('Trade defaults'),
          subtitle: Text(
            'Default lot size, hedge width, and quantity display.',
          ),
        ),
      ),
      const Card(
        child: ListTile(
          leading: Icon(Icons.sort),
          title: Text('Position ordering'),
          subtitle: Text('Sort by loss, underlying, expiry, or created date.'),
        ),
      ),
    ],
  );
}

class _ComingSoonPage extends StatelessWidget {
  const _ComingSoonPage({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: _brand),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, height: 1.45),
          ),
        ],
      ),
    ),
  );
}

class _LegDraft {
  _LegDraft({
    this.side = ExecutionSide.sell,
    this.optionType = OptionType.call,
    String quantity = '1',
    String strike = '',
    String premium = '',
    this.existingExecutionId,
    this.lotSize,
  }) : strike = TextEditingController(text: strike),
       premium = TextEditingController(text: premium),
       quantityController = TextEditingController(text: quantity);

  ExecutionId? existingExecutionId;
  final int? lotSize;
  bool quantityInLots = false;
  ExecutionSide side;
  OptionType optionType;
  final TextEditingController strike;
  final TextEditingController premium;
  final TextEditingController quantityController;

  void dispose() {
    strike.dispose();
    premium.dispose();
    quantityController.dispose();
  }
}

class _StrategyTemplate {
  const _StrategyTemplate(this.label, this.structure, this.description);
  final String label;
  final StrategyStructure structure;
  final String description;
}

class PaperTradeEntryPage extends StatefulWidget {
  const PaperTradeEntryPage({
    super.key,
    required this.repository,
    this.existingTrade,
  });
  final TradingRepository repository;
  final Trade? existingTrade;

  @override
  State<PaperTradeEntryPage> createState() => _PaperTradeEntryPageState();
}

class _PaperTradeEntryPageState extends State<PaperTradeEntryPage> {
  final _formKey = GlobalKey<FormState>();
  final _setupName = TextEditingController();
  final _referenceStrike = TextEditingController(text: '25000');
  final _quantity = TextEditingController(text: '1');
  bool _baseQuantityInLots = false;
  final List<_LegDraft> _legs = [];
  String _underlying = 'NIFTY';
  DateTime _tradeDate = DateTime.now();
  DateTime _expiry = DateTime.now().add(const Duration(days: 7));
  List<DateTime> _availableExpiries = [];
  bool _loadingExpiries = false;
  String? _expiryLoadError;
  int _strikeStep = 50;
  int _hedgeWidth = 200;
  int? _currentLotSize;
  StrategyStructure _selectedStrategy = StrategyStructure.custom;
  bool _saving = false;
  String? _saveError;

  static const _templates = <_StrategyTemplate>[
    _StrategyTemplate(
      'Bear Call Spread',
      StrategyStructure.bearCallSpread,
      'Sell a call; buy a higher-strike call as the hedge.',
    ),
    _StrategyTemplate(
      'Bull Put Spread',
      StrategyStructure.bullPutSpread,
      'Sell a put; buy a lower-strike put as the hedge.',
    ),
    _StrategyTemplate(
      'Iron Condor',
      StrategyStructure.ironCondor,
      'Sell an OTM call and put, protected by wider wings.',
    ),
    _StrategyTemplate(
      'Iron Butterfly',
      StrategyStructure.ironButterfly,
      'Sell the centre straddle and buy both wings.',
    ),
    _StrategyTemplate(
      'Neutral Butterfly',
      StrategyStructure.neutralButterfly,
      'A 1:2:1 butterfly built around the reference strike.',
    ),
    _StrategyTemplate(
      'Custom',
      StrategyStructure.custom,
      'Start with an empty builder and choose each option yourself.',
    ),
  ];

  int get _reference =>
      int.tryParse(_referenceStrike.text) ?? _defaultReference;
  int get _defaultReference => switch (_underlying) {
    'BANKNIFTY' => 50000,
    'SENSEX' => 80000,
    _ => 25000,
  };
  int get _centerStrike => ((_reference / _strikeStep).round()) * _strikeStep;
  @override
  void initState() {
    super.initState();
    final trade = widget.existingTrade;
    if (trade != null) {
      _underlying = trade.executions.first.contract.underlying;
      _strikeStep = _underlying == 'NIFTY' ? 50 : 100;
      _hedgeWidth = _strikeStep * 4;
      _tradeDate = trade.executions.first.executedAt;
      final expiry = trade.executions.first.contract.expiry.value;
      _expiry = DateTime(expiry.year, expiry.month, expiry.day);
      _referenceStrike.text = trade.executions.first.contract.strike.toString();
      _legs.clear();
      for (final execution in trade.executions) {
        _legs.add(
          _LegDraft(
            side: execution.side,
            optionType: execution.contract.optionType,
            quantity: execution.quantity.toString(),
            strike: execution.contract.strike.toString(),
            premium: execution.price.toString(),
            existingExecutionId: execution.id,
          ),
        );
      }
    } else {
      _legs.addAll([]);
    }
    // A new trade must use an actual expiry supplied by the same Zerodha
    // instrument/option-chain service used by the option-chain screen.
    _loadAvailableExpiries();
  }

  @override
  void dispose() {
    _setupName.dispose();
    _referenceStrike.dispose();
    _quantity.dispose();
    for (final leg in _legs) {
      leg.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAvailableExpiries() async {
    final marketToken = await MarketDataAuth.readToken();
    if (_underlying != 'NIFTY' || marketToken == null || marketToken.isEmpty) {
      if (mounted) {
        setState(() {
          _availableExpiries = [];
          _expiryLoadError =
              'Zerodha expiry dates are currently available for NIFTY only.';
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loadingExpiries = true;
        _expiryLoadError = null;
      });
    }
    try {
      final response = await http
          .get(
            Uri.parse('$tradingMemoryMarketDataBaseUrl/api/nifty/expiries'),
            headers: {
              'X-Trading-Memory-Token': marketToken,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Could not load expiry dates (HTTP ${response.statusCode}).',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Unexpected expiry response from market data service.',
        );
      }
      final dates =
          (decoded['expiries'] as List<dynamic>? ?? const [])
              .map((value) => DateTime.tryParse(value.toString()))
              .whereType<DateTime>()
              .map(DateUtils.dateOnly)
              .toSet()
              .toList()
            ..sort();
      if (dates.isEmpty) {
        throw StateError(
          'Zerodha returned no upcoming expiries. Check the Kite connection and instrument master.',
        );
      }
      if (!mounted) return;
      setState(() {
        _availableExpiries = dates;
        final currentExpiry = DateUtils.dateOnly(_expiry);
        if (dates.contains(currentExpiry)) {
          _expiry = currentExpiry;
        } else if (widget.existingTrade != null) {
          // Keep an existing historical trade's original expiry editable
          // without silently rewriting its saved contract dates.
          _availableExpiries = [...dates, currentExpiry]..sort();
          _expiry = currentExpiry;
        } else {
          final tradeDay = DateUtils.dateOnly(_tradeDate);
          _expiry = dates.firstWhere(
            (date) => !date.isBefore(tradeDay),
            orElse: () => dates.first,
          );
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _expiryLoadError = error.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _loadingExpiries = false);
    }
    // Quantity mode must use the live instrument lot size, not a fallback of 1.
    await _refreshCurrentLotSize();
  }

  Future<void> _refreshCurrentLotSize() async {
    final marketToken = await MarketDataAuth.readToken();
    if (_underlying != 'NIFTY' || marketToken == null || marketToken.isEmpty)
      return;
    final chain = await _fetchTemplateChain();
    if (!mounted || chain == null) return;
    int? lotSize;
    for (final raw in chain['strikes'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      for (final side in ['call', 'put']) {
        final quote = raw[side];
        if (quote is Map<String, dynamic>) {
          final value = (quote['lot_size'] as num?)?.toInt();
          if (value != null && value > 0) {
            lotSize = value;
            break;
          }
        }
      }
      if (lotSize != null) break;
    }
    if (lotSize != null && lotSize > 0 && mounted) {
      setState(() {
        _currentLotSize = lotSize;
        // Keep the default base size valid in unit mode. A new strategy starts
        // with one exchange lot, not one contract unit.
        if (!_baseQuantityInLots && _quantity.text.trim() == '1') {
          _quantity.text = '$lotSize';
        }
      });
    }
  }

  Future<DateTime?> _pickDate(DateTime initial, {DateTime? firstDate}) =>
      showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: firstDate ?? DateTime(2020),
        lastDate: DateTime(2035),
      );

  String? _positiveInt(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed == null || parsed <= 0
        ? 'Enter a whole quantity greater than zero.'
        : null;
  }

  String? _quantityForLeg(String? value, int? lotSize) {
    final baseError = _positiveInt(value);
    if (baseError != null) return baseError;
    final quantity = int.parse(value!);
    if (lotSize != null && lotSize > 0 && quantity % lotSize != 0) {
      return 'Quantity must be a multiple of $lotSize units (exchange lot size).';
    }
    return null;
  }

  String? _positiveStrike(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed == null || parsed <= 0
        ? 'Enter a positive whole-number strike.'
        : null;
  }

  String? _premium(String? value) {
    final parsed = double.tryParse(value ?? '');
    return parsed == null || !parsed.isFinite || parsed < 0
        ? 'Enter a premium per unit.'
        : null;
  }

  void _selectUnderlying(String? value) {
    if (value == null || value == _underlying) return;
    setState(() {
      _underlying = value;
      _availableExpiries = [];
      _expiryLoadError = null;
      _strikeStep = value == 'NIFTY' ? 50 : 100;
      _hedgeWidth = _strikeStep * 4;
      _currentLotSize = null;
      _referenceStrike.text = _defaultReference.toString();
      for (final leg in _legs) {
        leg.dispose();
      }
      _legs.clear();
      _selectedStrategy = StrategyStructure.custom;
      _saveError = null;
    });
    _loadAvailableExpiries();
  }

  Future<void> _applyTemplate(_StrategyTemplate template) async {
    setState(() {
      _selectedStrategy = template.structure;
      for (final leg in _legs) {
        leg.dispose();
      }
      _legs.clear();
      final c = _centerStrike;
      final w = _hedgeWidth;
      final parsedQuantity = int.tryParse(_quantity.text.trim());
      final enteredBase = parsedQuantity != null && parsedQuantity > 0
          ? parsedQuantity
          : 1;
      final baseUnits = _baseQuantityInLots
          ? enteredBase * (_currentLotSize ?? 1)
          : enteredBase;
      final q = baseUnits.toString();
      void add(
        int strike,
        OptionType type,
        ExecutionSide side, {
        String quantity = '',
      }) {
        _legs.add(
          _LegDraft(
            strike: strike.toString(),
            optionType: type,
            side: side,
            quantity: quantity.isEmpty ? q : quantity,
            lotSize: _currentLotSize,
          ),
        );
      }

      switch (template.structure) {
        case StrategyStructure.bearCallSpread:
          add(c, OptionType.call, ExecutionSide.sell);
          add(c + w, OptionType.call, ExecutionSide.buy);
        case StrategyStructure.bullPutSpread:
          add(c, OptionType.put, ExecutionSide.sell);
          add(c - w, OptionType.put, ExecutionSide.buy);
        case StrategyStructure.ironCondor:
          add(c + _strikeStep, OptionType.call, ExecutionSide.sell);
          add(c + _strikeStep + w, OptionType.call, ExecutionSide.buy);
          add(c - _strikeStep, OptionType.put, ExecutionSide.sell);
          add(c - _strikeStep - w, OptionType.put, ExecutionSide.buy);
        case StrategyStructure.ironButterfly:
          add(c, OptionType.call, ExecutionSide.sell);
          add(c, OptionType.put, ExecutionSide.sell);
          add(c + w, OptionType.call, ExecutionSide.buy);
          add(c - w, OptionType.put, ExecutionSide.buy);
        case StrategyStructure.neutralButterfly:
          add(c - w, OptionType.call, ExecutionSide.buy);
          add(
            c,
            OptionType.call,
            ExecutionSide.sell,
            quantity: (int.parse(q) * 2).toString(),
          );
          add(c + w, OptionType.call, ExecutionSide.buy);
        case StrategyStructure.custom:
        case StrategyStructure.unknown:
          break;
      }
      _saveError = null;
    });
    // Templates stay on this screen. Resolve only their premiums from the
    // live chain; the explicit manual-chain button remains the navigation path.
    final marketToken = await MarketDataAuth.readToken();
    if (_underlying == 'NIFTY' &&
        marketToken != null &&
        marketToken.isNotEmpty) {
      final chain = await _fetchTemplateChain();
      if (!mounted) return;
      var priced = 0;
      setState(() {
        for (final leg in _legs) {
          final strike = int.tryParse(leg.strike.text);
          if (strike == null) continue;
          final premium = _templateQuoteFor(chain, strike, leg.optionType);
          if (premium != null) {
            leg.premium.text = premium.toStringAsFixed(2);
            priced++;
          }
        }
      });
      if (priced < _legs.length && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              priced == 0
                  ? 'Strategy legs created. Live premiums were unavailable; enter them manually or use the option chain.'
                  : 'Premiums loaded for $priced of ${_legs.length} legs. Review missing prices before saving.',
            ),
          ),
        );
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Strategy legs created. Live premiums are available for NIFTY only; enter premiums manually.',
          ),
        ),
      );
    }
  }

  Future<Map<String, dynamic>?> _fetchTemplateChain() async {
    final marketToken = await MarketDataAuth.readToken();
    if (marketToken == null || marketToken.isEmpty) return null;

    final expiry = DateUtils.dateOnly(_expiry);
    final key =
        '${expiry.year.toString().padLeft(4, '0')}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}';
    try {
      final response = await http
          .get(
            Uri.parse(
              '$tradingMemoryMarketDataBaseUrl/api/nifty/chain?expiry=$key&wing_count=30',
            ),
            headers: {
              'X-Trading-Memory-Token': marketToken,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  double? _templateQuoteFor(
    Map<String, dynamic>? chain,
    int strike,
    OptionType type,
  ) {
    for (final raw in chain?['strikes'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic> ||
          (raw['strike'] as num?)?.toInt() != strike)
        continue;
      final quote = raw[type == OptionType.call ? 'call' : 'put'];
      final price = quote is Map<String, dynamic>
          ? (quote['last_price'] as num?)?.toDouble()
          : null;
      if (price != null && price.isFinite && price > 0) return price;
    }
    return null;
  }

  Future<void> _openLiveOptionChain() async {
    if (_underlying != 'NIFTY') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The first live market-data integration supports NIFTY options only.',
          ),
        ),
      );
      return;
    }

    final currentExpiry = DateUtils.dateOnly(_expiry);
    final initialSelections = _legs
        .map((leg) {
          final strike = int.tryParse(leg.strike.text) ?? 0;
          final enteredQuantity =
              int.tryParse(leg.quantityController.text) ??
              (leg.lotSize ?? _currentLotSize ?? 1);
          final quantity = leg.quantityInLots
              ? enteredQuantity * (leg.lotSize ?? _currentLotSize ?? 1)
              : enteredQuantity;
          final premium = double.tryParse(leg.premium.text);
          return NiftyOptionContractSelection(
            expiry: currentExpiry,
            strike: strike,
            optionType: leg.optionType,
            tradingSymbol: '',
            lotSize: leg.lotSize ?? _currentLotSize ?? 1,
            side: leg.side,
            quantity: quantity > 0
                ? quantity
                : (leg.lotSize ?? _currentLotSize ?? 1),
            entryPremium: premium,
            lastPrice: null,
          );
        })
        .where((selection) => selection.strike > 0)
        .toList();

    final selections = await Navigator.of(context)
        .push<List<NiftyOptionContractSelection>>(
          MaterialPageRoute<List<NiftyOptionContractSelection>>(
            builder: (_) => NiftyOptionChainPage(
              initialExpiry: _expiry,
              initialSelections: initialSelections,
            ),
          ),
        );
    if (selections == null || !mounted) return;

    final oldLegs = List<_LegDraft>.from(_legs);
    final currentDate = DateUtils.dateOnly(_expiry);
    final selectedExpiry = selections.isEmpty
        ? currentDate
        : DateUtils.dateOnly(selections.first.expiry);
    final replacementLegs = selections.map((selection) {
      final sameContract = selectedExpiry == currentDate
          ? oldLegs.where(
              (old) =>
                  int.tryParse(old.strike.text) == selection.strike &&
                  old.optionType == selection.optionType,
            )
          : const <_LegDraft>[];
      final existingId = sameContract.isEmpty
          ? null
          : sameContract.first.existingExecutionId;
      return _LegDraft(
        strike: selection.strike.toString(),
        optionType: selection.optionType,
        side: selection.side,
        quantity: selection.quantity.toString(),
        premium: selection.entryPremium?.toStringAsFixed(2) ?? '',
        lotSize: selection.lotSize > 0 ? selection.lotSize : null,
        existingExecutionId: existingId,
      );
    }).toList();

    setState(() {
      for (final leg in _legs) {
        leg.dispose();
      }
      _legs
        ..clear()
        ..addAll(replacementLegs);

      if (selections.isNotEmpty) {
        _expiry = selectedExpiry;
        _referenceStrike.text = selections.first.strike.toString();
        _currentLotSize = selections.first.lotSize > 0
            ? selections.first.lotSize
            : null;
        _quantity.text = _baseQuantityInLots
            ? (selections.first.quantity ~/
                      (selections.first.lotSize > 0
                          ? selections.first.lotSize
                          : 1))
                  .toString()
            : selections.first.quantity.toString();
      }

      _selectedStrategy = StrategyStructure.custom;
      _saveError = null;
    });

    if (selections.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${selections.length} leg${selections.length == 1 ? '' : 's'} added from the option chain. Review quantities and entry premiums, then tap Save draft and review.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'All legs removed. Select contracts from the option chain or add a template.',
          ),
        ),
      );
    }
  }

  Future<void> _saveDraft() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    if (_legs.isEmpty) {
      setState(
        () => _saveError = 'Choose a strategy template or add at least one leg from the option chain.',
      );
      return;
    }
    if (_expiry.isBefore(
      DateTime(_tradeDate.year, _tradeDate.month, _tradeDate.day),
    )) {
      setState(
        () => _saveError = 'Expiry cannot be earlier than the trade date.',
      );
      return;
    }
    final parsedUnderlying = _legs
        .map((l) => int.tryParse(l.strike.text))
        .toList();
    if (parsedUnderlying.any((strike) => strike == null || strike <= 0)) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final suffix = DateTime.now().microsecondsSinceEpoch.toString();
      final executions = <Execution>[];
      for (var i = 0; i < _legs.length; i++) {
        final leg = _legs[i];
        executions.add(
          Execution(
            id: leg.existingExecutionId ?? ExecutionId('paper-$suffix-$i'),
            executedAt: _tradeDate,
            contract: OptionContract(
              underlying: _underlying,
              expiry: ExpiryDate(_expiry.year, _expiry.month, _expiry.day),
              strike: int.parse(leg.strike.text),
              optionType: leg.optionType,
            ),
            side: leg.side,
            source: ExecutionSource.manual,
            quantity:
                (int.parse(leg.quantityController.text) *
                (leg.quantityInLots
                    ? (leg.lotSize ?? _currentLotSize ?? 1)
                    : 1)),
            price: double.parse(leg.premium.text),
          ),
        );
      }
      final tradeId =
          widget.existingTrade?.id ?? TradeId('paper-trade-$suffix');
      if (widget.existingTrade == null) {
        await widget.repository.createDraftPaperTrade(
          tradeId: tradeId,
          executions: executions,
        );
      } else {
        await widget.repository.updateDraftPaperTrade(
          tradeId: tradeId,
          executions: executions,
        );
      }
      if (!mounted) return;
      final confirmed = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (_) => PaperTradeConfirmationPage(
            repository: widget.repository,
            tradeId: tradeId,
            setupName: _setupName.text.trim(),
            initialStrategy: _selectedStrategy,
          ),
        ),
      );
      if (confirmed == true && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted)
        setState(
          () => _saveError =
              'Could not save the draft. Your entries are still on this screen. Details: $error',
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteExistingDraft() async {
    final trade = widget.existingTrade;
    if (trade == null || trade.status != TradeStatus.draft || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete draft trade?'),
        content: const Text(
          'This draft will be permanently deleted. This action cannot be undone.',
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
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deleteTrade(trade.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete draft: $error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.existingTrade == null ? 'Strategy builder' : 'Edit paper draft',
      ),
      backgroundColor: _pageBackground,
      actions: [
        if (widget.existingTrade?.status == TradeStatus.draft)
          IconButton(
            tooltip: 'Delete draft',
            icon: const Icon(Icons.delete_outline),
            onPressed: _saving ? null : _deleteExistingDraft,
          ),
      ],
    ),
    body: Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _StepHeader(
            step: 'STEP 1 OF 2',
            title: 'Build your strategy',
            subtitle: 'Start from a template, tune the hedge width, then choose exact strikes from the chain.',
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF3F6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFB8D6E0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.candlestick_chart, color: _brand),
                    SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        'Zerodha option chain',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                const Text(
                  'Choose a real NIFTY contract from Zerodha quotes. LTP is prefilled as a reference price and remains editable; quote snapshots must not be mistaken for an executed fill.',
                  style: TextStyle(color: Colors.black54, height: 1.35),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _saving ? null : _openLiveOptionChain,
                  icon: const Icon(Icons.show_chart),
                  label: const Text('Open Zerodha NIFTY option chain'),
                ),
                if (_underlying != 'NIFTY')
                  const Text(
                    'Live chain is currently available for NIFTY only.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Underlying and expiry',
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _underlying,
                  decoration: const InputDecoration(labelText: 'Underlying'),
                  items: const [
                    DropdownMenuItem(value: 'NIFTY', child: Text('NIFTY')),
                    DropdownMenuItem(
                      value: 'BANKNIFTY',
                      child: Text('BANKNIFTY'),
                    ),
                    DropdownMenuItem(value: 'SENSEX', child: Text('SENSEX')),
                  ],
                  onChanged: _saving ? null : _selectUnderlying,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _DateField(
                        label: 'Trade date',
                        value: _dateLabel(_tradeDate),
                        onTap: () async {
                          final d = await _pickDate(_tradeDate);
                          if (d != null)
                            setState(() {
                              _tradeDate = d;
                              if (_expiry.isBefore(d)) _expiry = d;
                            });
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<DateTime>(
                        value:
                            _availableExpiries.contains(
                              DateUtils.dateOnly(_expiry),
                            )
                            ? DateUtils.dateOnly(_expiry)
                            : null,
                        decoration: InputDecoration(
                          labelText: 'Expiry',
                          helperText: _loadingExpiries
                              ? 'Loading Zerodha expiries…'
                              : _expiryLoadError,
                          helperMaxLines: 3,
                        ),
                        isExpanded: true,
                        items: _availableExpiries
                            .map(
                              (date) => DropdownMenuItem<DateTime>(
                                value: date,
                                child: Text(_dateLabel(date)),
                              ),
                            )
                            .toList(),
                        onChanged:
                            _saving ||
                                _loadingExpiries ||
                                _availableExpiries.isEmpty
                            ? null
                            : (date) {
                                if (date == null) return;
                                setState(() {
                                  _expiry = date;
                                  _currentLotSize = null;
                                });
                              },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _setupName,
                  decoration: const InputDecoration(
                    labelText: 'Setup name (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _referenceStrike,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Reference strike',
                          helperText: 'Set near ATM',
                        ),
                        onChanged: (_) => setState(() {}),
                        validator: _positiveStrike,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _strikeStep,
                        decoration: const InputDecoration(
                          labelText: 'Strike interval',
                        ),
                        items: [50, 100, 500]
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text('$v points'),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() {
                          _strikeStep = v ?? _strikeStep;
                          _hedgeWidth = _strikeStep * 4;
                        }),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Strategy templates',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 134,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _templates.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final template = _templates[index];
                final selected = template.structure == _selectedStrategy;
                return SizedBox(
                  width: 178,
                  child: InkWell(
                    onTap: () => _applyTemplate(template),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xFFE7F2F5)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected ? _brand : const Color(0xFFE2E7EA),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _templateIcon(template.structure),
                            color: _brand,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            template.label,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Expanded(
                            child: Text(
                              template.description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Position sizing and hedge',
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _quantity,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: _baseQuantityInLots
                              ? 'Base quantity (lots)'
                              : 'Base quantity (units)',
                          helperText: _currentLotSize == null
                              ? 'Connect option chain to load lot size'
                              : (_baseQuantityInLots
                                    ? '1 lot = $_currentLotSize units'
                                    : '1 lot = $_currentLotSize units'),
                          suffixIcon: _compactQuantitySuffix(
                            isLots: _baseQuantityInLots,
                            onChanged: (toLots) {
                              final lotSize = _currentLotSize;
                              if (lotSize == null || lotSize <= 0) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Lot size is not loaded yet. Connect the option chain and try again.',
                                    ),
                                  ),
                                );
                                return;
                              }
                              setState(() {
                                final entered = int.tryParse(
                                  _quantity.text.trim(),
                                );
                                if (entered != null && entered > 0) {
                                  if (toLots) {
                                    if (entered % lotSize != 0) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Quantity must be a multiple of $lotSize units to switch to lots.',
                                          ),
                                        ),
                                      );
                                      return;
                                    }
                                    _quantity.text = '${entered ~/ lotSize}';
                                  } else {
                                    _quantity.text = '${entered * lotSize}';
                                  }
                                }
                                _baseQuantityInLots = toLots;
                              });
                            },
                          ),
                        ),
                        validator: _positiveInt,
                        onChanged: (_) {},
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _hedgeWidth,
                        decoration: const InputDecoration(
                          labelText: 'Hedge width',
                        ),
                        items: [
                          for (final multiplier in [1, 2, 3, 4, 5, 10])
                            DropdownMenuItem(
                              value: _strikeStep * multiplier,
                              child: Text('${_strikeStep * multiplier} points'),
                            ),
                        ],
                        onChanged: (v) =>
                            setState(() => _hedgeWidth = v ?? _hedgeWidth),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Templates use the reference strike and hedge width to propose legs. You can change them below or tap any chain strike.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => _applyTemplate(
                    _templates.firstWhere(
                      (t) => t.structure == _selectedStrategy,
                      orElse: () => _templates.last,
                    ),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Rebuild legs from selected template'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Selected legs (${_legs.length})',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  for (final l in _legs) {
                    l.dispose();
                  }
                  _legs.clear();
                  _selectedStrategy = StrategyStructure.custom;
                }),
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
            ],
          ),
          if (_legs.isEmpty)
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E7EA)),
              ),
              child: const Text(
                'Choose a template above or tap a strike in the option chain to start building.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, height: 1.4),
              ),
            ),
          for (var i = 0; i < _legs.length; i++) ...[
            _builderLegCard(i, _legs[i]),
            const SizedBox(height: 10),
          ],
          if (_saveError != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _saveError!,
                style: const TextStyle(color: Color(0xFFC62828)),
              ),
            ),
          FilledButton.icon(
            onPressed: _saving ? null : _saveDraft,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_forward),
            label: Text(_saving ? 'Saving…' : 'Save draft and review'),
          ),
          const SizedBox(height: 8),
          const Text(
            'NIFTY template legs resolve against the Zerodha option chain. Quote LTPs prefill entry premiums when available; verify the price before saving.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    ),
  );

  Widget _builderLegCard(int index, _LegDraft leg) => _SectionCard(
    title:
        'Leg ${index + 1} · ${leg.side.name.toUpperCase()} ${leg.optionType == OptionType.call ? 'CE' : 'PE'}',
    trailing: IconButton(
      tooltip: 'Remove leg',
      onPressed: () => setState(() {
        _legs.removeAt(index).dispose();
        _selectedStrategy = StrategyStructure.custom;
      }),
      icon: const Icon(Icons.delete_outline),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<ExecutionSide>(
                initialValue: leg.side,
                decoration: const InputDecoration(labelText: 'Action'),
                items: const [
                  DropdownMenuItem(
                    value: ExecutionSide.buy,
                    child: Text('BUY'),
                  ),
                  DropdownMenuItem(
                    value: ExecutionSide.sell,
                    child: Text('SELL'),
                  ),
                ],
                onChanged: (v) => setState(() {
                  leg.side = v ?? leg.side;
                  _selectedStrategy = StrategyStructure.custom;
                }),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<OptionType>(
                initialValue: leg.optionType,
                decoration: const InputDecoration(labelText: 'Option'),
                items: const [
                  DropdownMenuItem(
                    value: OptionType.call,
                    child: Text('Call (CE)'),
                  ),
                  DropdownMenuItem(
                    value: OptionType.put,
                    child: Text('Put (PE)'),
                  ),
                ],
                onChanged: (v) => setState(() {
                  leg.optionType = v ?? leg.optionType;
                  _selectedStrategy = StrategyStructure.custom;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: leg.strike,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Strike'),
                validator: _positiveStrike,
                onChanged: (_) => setState(
                  () => _selectedStrategy = StrategyStructure.custom,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: leg.quantityController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: leg.quantityInLots
                      ? 'Quantity (lots)'
                      : 'Quantity (units)',
                  suffixIcon: _compactQuantitySuffix(
                    isLots: leg.quantityInLots,
                    onChanged: (toLots) => setState(() {
                      final lotSize = leg.lotSize ?? _currentLotSize ?? 1;
                      final entered = int.tryParse(
                        leg.quantityController.text.trim(),
                      );
                      if (entered != null && entered > 0) {
                        if (toLots) {
                          if (entered % lotSize != 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Quantity must be a multiple of $lotSize units to switch to lots.',
                                ),
                              ),
                            );
                            return;
                          }
                          leg.quantityController.text = '${entered ~/ lotSize}';
                        } else {
                          leg.quantityController.text = '${entered * lotSize}';
                        }
                      }
                      leg.quantityInLots = toLots;
                    }),
                  ),
                ),
                validator: (value) => _quantityForLeg(
                  value,
                  leg.quantityInLots ? 1 : leg.lotSize,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: leg.premium,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Entry premium per unit (₹)',
          ),
          validator: _premium,
        ),
      ],
    ),
  );

  Widget _compactQuantitySuffix({
    required bool isLots,
    required ValueChanged<bool> onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Center(
      widthFactor: 1,
      child: InkWell(
        onTap: () => onChanged(!isLots),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: _brand.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            isLots ? 'Lots' : 'Qty',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    ),
  );

  IconData _templateIcon(StrategyStructure structure) => switch (structure) {
    StrategyStructure.bearCallSpread => Icons.trending_down,
    StrategyStructure.bullPutSpread => Icons.trending_up,
    StrategyStructure.ironCondor => Icons.swap_horiz,
    StrategyStructure.ironButterfly => Icons.change_history,
    StrategyStructure.neutralButterfly => Icons.filter_center_focus,
    _ => Icons.tune,
  };
}

class PaperTradeConfirmationPage extends StatefulWidget {
  const PaperTradeConfirmationPage({
    super.key,
    required this.repository,
    required this.tradeId,
    required this.setupName,
    this.initialStrategy = StrategyStructure.custom,
  });
  final TradingRepository repository;
  final TradeId tradeId;
  final String setupName;
  final StrategyStructure initialStrategy;
  @override
  State<PaperTradeConfirmationPage> createState() =>
      _PaperTradeConfirmationPageState();
}

class _PaperTradeConfirmationPageState
    extends State<PaperTradeConfirmationPage> {
  late StrategyStructure _strategy;
  late final Future<dynamic> _tradeFuture;

  @override
  void initState() {
    super.initState();
    _strategy = widget.initialStrategy;
    // Keep the same Future across rebuilds. Creating getTrade() inside build()
    // makes FutureBuilder restart on every expand/collapse setState, which can
    // reset the ListView and jump the user back to the top of the page.
    _tradeFuture = widget.repository.getTrade(widget.tradeId);
  }

  bool _saving = false;
  String? _error;
  final TextEditingController _commentsController = TextEditingController();
  final TextEditingController _rulesController = TextEditingController();
  final Map<String, TextEditingController> _snapshotFields = {
    for (final key in <String>[
      'entryDebitCredit',
      'spot',
      'vix',
      'atmStraddle',
      'lowerBreakeven',
      'upperBreakeven',
      'wingWidth',
      'distanceToLowerBreakeven',
      'distanceToUpperBreakeven',
      'profitRange',
      'pnl',
      'pnlPercentage',
      'capitalDeployed',
      'margin',
      'cost',
      'maxProfit',
      'maxLoss',
      'delta',
      'gamma',
      'theta',
      'vega',
      'iv',
    ])
      key: TextEditingController(),
  };
  bool _snapshotFieldsInitialized = false;
  final Map<String, bool> _expandedSnapshotSections = {};

  double? _fieldValue(String key, double? fallback) {
    final text = _snapshotFields[key]?.text.trim() ?? '';
    if (text.isEmpty) return fallback;
    final parsed = double.tryParse(text.replaceAll(',', ''));
    return parsed != null && parsed.isFinite ? parsed : fallback;
  }

  String _formatMetric(double? value) =>
      value == null || !value.isFinite ? '' : value.toStringAsFixed(2);

  void _initializeSnapshotFields(Trade trade) {
    if (_snapshotFieldsInitialized) return;
    _snapshotFieldsInitialized = true;
    final legs = trade.executions
        .map(
          (e) => PositionLeg(
            contract: e.contract,
            side: e.side == ExecutionSide.buy
                ? PositionSide.buy
                : PositionSide.sell,
            quantity: e.quantity,
            entryPremium: e.price,
          ),
        )
        .toList();
    final metrics = _expiryMetrics(legs, null);
    final initial = <String, double?>{
      'entryDebitCredit': trade.netPremium,
      'lowerBreakeven': metrics['lower'],
      'upperBreakeven': metrics['upper'],
      'wingWidth': metrics['width'],
      'profitRange': metrics['range'],
      'maxProfit': metrics['maxProfit'],
      'maxLoss': metrics['maxLoss'],
    };
    for (final entry in initial.entries) {
      _snapshotFields[entry.key]!.text = _formatMetric(entry.value);
    }
    // Values requiring a live capture remain blank until supplied by the user
    // or fetched from Zerodha during confirmation.
  }

  Widget _snapshotSection(String title, List<Widget> children) {
    final expanded = _expandedSnapshotSections[title] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E7EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() {
                _expandedSnapshotSections[title] = !expanded;
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 15,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _metricField(String key, String label, {String? helper}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: _snapshotFields[key],
      enabled: !_saving,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    ),
  );

  Widget _riskRewardField() => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: AnimatedBuilder(
      animation: Listenable.merge([
        _snapshotFields['maxProfit']!,
        _snapshotFields['maxLoss']!,
      ]),
      builder: (context, _) {
        final maxProfit = double.tryParse(
          _snapshotFields['maxProfit']!.text.trim().replaceAll(',', ''),
        );
        final maxLoss = double.tryParse(
          _snapshotFields['maxLoss']!.text.trim().replaceAll(',', ''),
        );
        final ratio =
            maxProfit != null &&
                maxLoss != null &&
                maxProfit.isFinite &&
                maxLoss.isFinite &&
                maxProfit >= 0 &&
                maxLoss > 0
            ? maxProfit / maxLoss
            : null;
        return InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Risk/reward (reward : risk)',
            helperText: 'Calculated as maximum profit ÷ maximum loss',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          child: Text(
            ratio == null ? '—' : '${ratio.toStringAsFixed(2)} : 1',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    _commentsController.dispose();
    _rulesController.dispose();
    for (final controller in _snapshotFields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _strategyLabel(StrategyStructure s) => switch (s) {
    StrategyStructure.unknown => 'Choose strategy',
    StrategyStructure.custom => 'Custom / other',
    StrategyStructure.neutralButterfly => 'Neutral butterfly',
    StrategyStructure.bullPutSpread => 'Bull put spread',
    StrategyStructure.bearCallSpread => 'Bear call spread',
    StrategyStructure.ironCondor => 'Iron condor',
    StrategyStructure.ironButterfly => 'Iron butterfly',
  };

  bool _looksCompatible(List<Execution> legs, StrategyStructure strategy) {
    if (strategy == StrategyStructure.custom) return true;
    final sameUnderlyingExpiry = legs.every(
      (e) =>
          e.contract.underlying == legs.first.contract.underlying &&
          e.contract.expiry == legs.first.contract.expiry,
    );
    if (!sameUnderlyingExpiry) return false;
    if (strategy == StrategyStructure.bullPutSpread ||
        strategy == StrategyStructure.bearCallSpread) {
      return legs.length == 2 &&
          legs[0].contract.optionType == legs[1].contract.optionType &&
          legs[0].side != legs[1].side &&
          legs[0].contract.strike != legs[1].contract.strike &&
          ((strategy == StrategyStructure.bullPutSpread &&
                  legs.first.contract.optionType == OptionType.put) ||
              (strategy == StrategyStructure.bearCallSpread &&
                  legs.first.contract.optionType == OptionType.call));
    }
    if (strategy == StrategyStructure.ironCondor) {
      return legs.length == 4 &&
          legs.where((e) => e.contract.optionType == OptionType.call).length ==
              2 &&
          legs.where((e) => e.contract.optionType == OptionType.put).length ==
              2 &&
          legs.map((e) => e.contract.strike).toSet().length == 4;
    }
    if (strategy == StrategyStructure.ironButterfly) {
      return legs.length == 4 &&
          legs.where((e) => e.contract.optionType == OptionType.call).length ==
              2 &&
          legs.where((e) => e.contract.optionType == OptionType.put).length ==
              2 &&
          legs.map((e) => e.contract.strike).toSet().length == 3;
    }
    if (strategy == StrategyStructure.neutralButterfly)
      return legs.length == 3 &&
          legs.every(
            (e) => e.contract.optionType == legs.first.contract.optionType,
          ) &&
          legs.map((e) => e.contract.strike).toSet().length == 3;
    return true;
  }

  Future<Map<String, dynamic>?> _fetchCaptureChain(Trade trade) async {
    final marketToken = await MarketDataAuth.readToken();
    if (trade.executions.isEmpty ||
        trade.executions.first.contract.underlying != 'NIFTY' ||
        marketToken == null ||
        marketToken.isEmpty)
      return null;
    final expiry = trade.executions.first.contract.expiry.value;
    final key =
        '${expiry.year.toString().padLeft(4, '0')}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}';
    try {
      final response = await http
          .get(
            Uri.parse(
              '$tradingMemoryMarketDataBaseUrl/api/nifty/chain?expiry=$key&wing_count=30',
            ),
            headers: {
              'X-Trading-Memory-Token': marketToken,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  double? _quoteFor(Map<String, dynamic>? chain, int strike, OptionType type) {
    for (final raw in chain?['strikes'] as List<dynamic>? ?? const []) {
      if (raw is! Map<String, dynamic> ||
          (raw['strike'] as num?)?.toInt() != strike)
        continue;
      final quote = raw[type == OptionType.call ? 'call' : 'put'];
      final price = quote is Map<String, dynamic>
          ? (quote['last_price'] as num?)?.toDouble()
          : null;
      if (price != null && price.isFinite && price > 0) return price;
    }
    return null;
  }

  Map<String, double?> _expiryMetrics(List<PositionLeg> legs, double? spot) {
    if (legs.isEmpty || legs.any((leg) => leg.entryPremium == null))
      return {
        'lower': null,
        'upper': null,
        'width': null,
        'lowerDistance': null,
        'upperDistance': null,
        'range': null,
        'maxProfit': null,
        'maxLoss': null,
      };
    double payoff(double underlying) {
      var total = 0.0;
      for (final leg in legs) {
        final intrinsic = leg.contract.optionType == OptionType.call
            ? (underlying - leg.contract.strike)
                  .clamp(0.0, double.infinity)
                  .toDouble()
            : (leg.contract.strike - underlying)
                  .clamp(0.0, double.infinity)
                  .toDouble();
        total +=
            (leg.side == PositionSide.buy
                ? intrinsic - leg.entryPremium!
                : leg.entryPremium! - intrinsic) *
            leg.quantity;
      }
      return total;
    }

    final strikes =
        legs.map((leg) => leg.contract.strike.toDouble()).toSet().toList()
          ..sort();
    final span = strikes.length > 1 ? strikes.last - strikes.first : 500.0;
    final low = (strikes.first - span - 500)
        .clamp(0.0, double.infinity)
        .toDouble();
    final high = strikes.last + span + 500;
    final points = <double>{low, ...strikes, high}.toList()..sort();
    final values = points.map(payoff).toList();
    final roots = <double>[];
    for (var i = 0; i < points.length - 1; i++) {
      final x1 = points[i],
          x2 = points[i + 1],
          y1 = values[i],
          y2 = values[i + 1];
      if (y1 == 0) roots.add(x1);
      if ((y1 < 0 && y2 > 0) || (y1 > 0 && y2 < 0))
        roots.add(x1 + (0 - y1) * (x2 - x1) / (y2 - y1));
    }
    if (values.last == 0) roots.add(points.last);
    roots.sort();
    final lower = roots.isEmpty ? null : roots.first;
    final upper = roots.length < 2 ? null : roots.last;
    final maxValue = values.reduce((a, b) => a > b ? a : b),
        minValue = values.reduce((a, b) => a < b ? a : b);
    final shortCallQuantity = legs
        .where(
          (leg) =>
              leg.contract.optionType == OptionType.call &&
              leg.side == PositionSide.sell,
        )
        .fold<int>(0, (sum, leg) => sum + leg.quantity);
    final longCallQuantity = legs
        .where(
          (leg) =>
              leg.contract.optionType == OptionType.call &&
              leg.side == PositionSide.buy,
        )
        .fold<int>(0, (sum, leg) => sum + leg.quantity);
    final unboundedUpsideRisk = shortCallQuantity > longCallQuantity;
    return {
      'lower': lower,
      'upper': upper,
      'width': strikes.last - strikes.first,
      'lowerDistance': lower == null || spot == null ? null : spot - lower,
      'upperDistance': upper == null || spot == null ? null : upper - spot,
      'range': lower == null || upper == null ? null : upper - lower,
      'maxProfit': maxValue > 0 ? maxValue : 0,
      'maxLoss': unboundedUpsideRisk ? null : (minValue < 0 ? -minValue : 0),
    };
  }

  Future<void> _confirm() async {
    for (final entry in _snapshotFields.entries) {
      final raw = entry.value.text.trim();
      if (raw.isNotEmpty) {
        final parsed = double.tryParse(raw.replaceAll(',', ''));
        if (parsed == null || !parsed.isFinite) {
          setState(() => _error = 'Enter a valid number for ${entry.key}.');
          return;
        }
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final trade = await widget.repository.getTrade(widget.tradeId);
      if (trade == null) throw StateError('Draft could not be loaded.');
      if (!_looksCompatible(trade.executions, _strategy)) {
        throw StateError(
          'The selected strategy does not match the entered legs. Choose Custom / other or correct the leg structure.',
        );
      }
      final now = DateTime.now();
      final first = trade.executions.first;
      // Resolve the market snapshot before changing the draft's status. A
      // missing spot must not leave a confirmed position without its first
      // point-in-time spot value.
      final captureChain = await _fetchCaptureChain(trade);
      final capturedSpot = (captureChain?['spot'] as num?)?.toDouble();
      final capturedVix = (captureChain?['india_vix'] as num?)?.toDouble();
      final spotAtCapture = _fieldValue('spot', capturedSpot);
      if (spotAtCapture == null ||
          !spotAtCapture.isFinite ||
          spotAtCapture <= 0) {
        throw StateError(
          'Spot at capture is unavailable. Refresh the option chain or enter the underlying spot in Snapshot metrics before confirming this position.',
        );
      }
      if (trade.status.name == 'draft') {
        await widget.repository.confirmTrade(
          tradeId: widget.tradeId,
          strategy: _strategy,
          confirmedAt: now,
        );
      } else if (trade.status.name == 'confirmed' &&
          trade.positionStates.isNotEmpty) {
        if (mounted) Navigator.of(context).pop(true);
        return;
      } else if (trade.status.name != 'confirmed') {
        throw StateError('Only a saved draft can be confirmed.');
      }
      final snapshotLegs = trade.executions
          .map(
            (e) => PositionLeg(
              contract: e.contract,
              side: e.side == ExecutionSide.buy
                  ? PositionSide.buy
                  : PositionSide.sell,
              quantity: e.quantity,
              entryPremium: e.price,
              marketPrice: _quoteFor(
                captureChain,
                e.contract.strike,
                e.contract.optionType,
              ),
            ),
          )
          .toList();
      final allLegPricesAvailable = snapshotLegs.every(
        (leg) => leg.marketPrice != null,
      );
      final mtmPnl = allLegPricesAvailable
          ? snapshotLegs.fold<double>(
              0,
              (sum, leg) =>
                  sum +
                  (leg.side == PositionSide.buy
                          ? leg.marketPrice! - leg.entryPremium!
                          : leg.entryPremium! - leg.marketPrice!) *
                      leg.quantity,
            )
          : null;
      final rows = (captureChain?['strikes'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((row) => row['strike'] is num && capturedSpot != null)
          .toList();
      if (capturedSpot != null) {
        rows.sort(
          (a, b) =>
              ((a['strike'] as num).toDouble() - capturedSpot!).abs().compareTo(
                ((b['strike'] as num).toDouble() - capturedSpot!).abs(),
              ),
        );
      }
      final atmRow = rows.isEmpty ? null : rows.first;
      final callLtp =
          ((atmRow?['call'] as Map<String, dynamic>?)?['last_price'] as num?)
              ?.toDouble();
      final putLtp =
          ((atmRow?['put'] as Map<String, dynamic>?)?['last_price'] as num?)
              ?.toDouble();
      final atmStraddle =
          callLtp != null && putLtp != null && callLtp > 0 && putLtp > 0
          ? callLtp + putLtp
          : null;
      final metrics = _expiryMetrics(snapshotLegs, capturedSpot);
      final capturedAt =
          DateTime.tryParse(
            captureChain?['snapshot_fetched_at']?.toString() ?? '',
          ) ??
          now;
      final stateId = 'state-${now.microsecondsSinceEpoch}';
      final positionState = PositionState(
        id: PositionStateId(stateId),
        tradeId: widget.tradeId.value,
        capturedAt: capturedAt,
        position: PositionSnapshot(
          underlying: first.contract.underlying,
          expiry: first.contract.expiry,
          strategy: _strategy,
          entryDebitCredit: _fieldValue('entryDebitCredit', trade.netPremium),
          comments: _commentsController.text.trim().isEmpty
              ? null
              : _commentsController.text.trim(),
          plannedRules: _rulesController.text.trim().isEmpty
              ? null
              : _rulesController.text.trim(),
          legs: snapshotLegs,
        ),
        market: MarketSnapshot(
          spot: spotAtCapture,
          vix: _fieldValue('vix', capturedVix),
          atmStraddle: _fieldValue('atmStraddle', atmStraddle),
        ),
        geometry: GeometrySnapshot(
          lowerBreakeven: _fieldValue('lowerBreakeven', metrics['lower']),
          upperBreakeven: _fieldValue('upperBreakeven', metrics['upper']),
          wingWidth: _fieldValue('wingWidth', metrics['width']),
          distanceToLowerBreakeven: _fieldValue(
            'distanceToLowerBreakeven',
            metrics['lowerDistance'],
          ),
          distanceToUpperBreakeven: _fieldValue(
            'distanceToUpperBreakeven',
            metrics['upperDistance'],
          ),
          profitRange: _fieldValue('profitRange', metrics['range']),
        ),
        economics: EconomicSnapshot(
          pnl: _fieldValue('pnl', mtmPnl),
          pnlPercentage: _fieldValue('pnlPercentage', null),
          capitalDeployed: _fieldValue('capitalDeployed', null),
          margin: _fieldValue('margin', null),
          cost: _fieldValue('cost', null),
        ),
        risk: RiskSnapshot(
          maxProfit: _fieldValue('maxProfit', metrics['maxProfit']),
          maxLoss: _fieldValue('maxLoss', metrics['maxLoss']),
          delta: _fieldValue('delta', null),
          gamma: _fieldValue('gamma', null),
          theta: _fieldValue('theta', null),
          vega: _fieldValue('vega', null),
          iv: _fieldValue('iv', null),
        ),
      );
      await widget.repository.capturePositionState(
        tradeId: widget.tradeId,
        state: positionState,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted)
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Review and confirm'),
      backgroundColor: _pageBackground,
    ),
    body: FutureBuilder<dynamic>(
      future: _tradeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError || snapshot.data == null)
          return const Center(
            child: Text('Could not load this draft. Go back and retry.'),
          );
        final trade = snapshot.data!;
        final netCredit = trade.netPremium;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _StepHeader(
              step: 'STEP 2 OF 2',
              title: 'Confirm your position',
              subtitle: 'Review the legs and select the structure before activating this trade.',
            ),
            const SizedBox(height: 18),
            _SectionCard(
              title: widget.setupName.isEmpty
                  ? '${trade.executions.first.contract.underlying} Paper trade'
                  : widget.setupName,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Expiry · ${_dateLabel(trade.executions.first.contract.expiry.value)}',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  for (var i = 0; i < trade.executions.length; i++) ...[
                    if (i > 0) const Divider(height: 20),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: trade.executions[i].side == ExecutionSide.buy
                                ? const Color(0xFFE8F3EC)
                                : const Color(0xFFFFF1E5),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            (trade.executions[i].side == ExecutionSide.buy
                                ? 'BUY'
                                : 'SELL'),
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${trade.executions[i].contract.strike} ${trade.executions[i].contract.optionType == OptionType.call ? 'CE' : 'PE'} × ${trade.executions[i].quantity}',
                          ),
                        ),
                        Text(
                          '₹${trade.executions[i].price.toStringAsFixed(2)}',
                        ),
                      ],
                    ),
                  ],
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Entry net cash flow'),
                      Text(
                        '${netCredit >= 0 ? 'Credit' : 'Debit'} ₹${netCredit.abs().toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Calculated from entered premiums; excludes charges.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Builder(
              builder: (context) {
                _initializeSnapshotFields(trade);
                return _SectionCard(
                  title: 'Initial snapshot values',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Review and edit calculated or captured values before saving. Blank values remain unavailable unless market data is captured at confirmation.',
                        style: TextStyle(color: Colors.black54, height: 1.4),
                      ),
                      const SizedBox(height: 14),
                      _snapshotSection('Trade cash flow', [
                        _metricField(
                          'entryDebitCredit',
                          'Entry net cash flow (+ credit / − debit)',
                        ),
                      ]),
                      _snapshotSection('Market context', [
                        _metricField(
                          'spot',
                          'Spot price',
                          helper: 'Prefilled from Zerodha at confirmation when available',
                        ),
                        _metricField('vix', 'India VIX'),
                        _metricField('atmStraddle', 'ATM straddle price'),
                      ]),
                      _snapshotSection('Breakeven and geometry', [
                        _metricField('lowerBreakeven', 'Lower breakeven'),
                        _metricField('upperBreakeven', 'Upper breakeven'),
                        _metricField('wingWidth', 'Wing width / strike span'),
                        _metricField(
                          'distanceToLowerBreakeven',
                          'Spot distance to lower breakeven',
                        ),
                        _metricField(
                          'distanceToUpperBreakeven',
                          'Spot distance to upper breakeven',
                        ),
                        _metricField('profitRange', 'Breakeven profit range'),
                      ]),
                      _snapshotSection('Risk and payoff', [
                        _metricField('maxProfit', 'Maximum profit'),
                        _metricField(
                          'maxLoss',
                          'Maximum loss',
                          helper: 'Leave blank if risk is unbounded or unknown',
                        ),
                        _riskRewardField(),
                      ]),
                      _snapshotSection('Position economics', [
                        _metricField('pnl', 'Unrealized P&L / MTM'),
                        _metricField('pnlPercentage', 'P&L percentage'),
                        _metricField('capitalDeployed', 'Capital deployed'),
                        _metricField('margin', 'Margin'),
                        _metricField('cost', 'Charges / costs'),
                      ]),
                      _snapshotSection('Greeks and volatility', [
                        _metricField('delta', 'Delta'),
                        _metricField('gamma', 'Gamma'),
                        _metricField('theta', 'Theta'),
                        _metricField('vega', 'Vega'),
                        _metricField('iv', 'Implied volatility (IV)'),
                      ]),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            _snapshotSection('Snapshot notes and planned rules', [
              TextField(
                controller: _commentsController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Comments',
                  hintText: 'Why are you entering this position?',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _rulesController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Planned rules',
                  hintText: 'Adjustment, risk and exit rules',
                  border: OutlineInputBorder(),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            _snapshotSection('Strategy structure', [
              DropdownButtonFormField<StrategyStructure>(
                initialValue: _strategy,
                decoration: const InputDecoration(
                  labelText: 'Select strategy',
                  border: OutlineInputBorder(),
                ),
                items: StrategyStructure.values
                    .where((s) => s != StrategyStructure.unknown)
                    .map(
                      (s) => DropdownMenuItem(
                        value: s,
                        child: Text(_strategyLabel(s)),
                      ),
                    )
                    .toList(),
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _strategy = v ?? _strategy),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF3F6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'The initial PositionState captures Zerodha spot/VIX and per-leg LTPs when available. MTM P&L is an LTP-based estimate; missing market data remains unavailable, not zero. Margin, charges and Greeks are not currently supplied by this capture path.',
                style: TextStyle(height: 1.4),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFC62828)),
                ),
              ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _saving ? null : _confirm,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(
                _saving ? 'Confirming…' : 'Confirm trade and capture state',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _saving
                  ? null
                  : () => Navigator.of(context).pop(false),
              child: const Text('Back to draft'),
            ),
          ],
        );
      },
    ),
  );
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.step,
    required this.title,
    required this.subtitle,
  });
  final String step, title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        step,
        style: const TextStyle(
          color: _brand,
          fontSize: 11,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        title,
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
      Text(
        subtitle,
        style: const TextStyle(color: Colors.black54, height: 1.4),
      ),
    ],
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE2E7EA)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label, value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
      ),
      child: Text(value),
    ),
  );
}

String _dateLabel(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')} ${_month(date.month)} ${date.year}';
String _month(int month) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];
