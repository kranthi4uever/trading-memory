import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../market_data_auth.dart';

import '../../../domain/trading/execution/execution.dart';
import '../../../domain/trading/execution/option_contract.dart';

const tradingMemoryMarketDataBaseUrl = String.fromEnvironment(
  'TRADING_MEMORY_API_BASE_URL',
  defaultValue: 'https://13.234.172.179',
);

/// A contract selected from the option chain. [entryPremium] is the value the
/// user wants recorded for the paper trade, not evidence of an executed fill.
class NiftyOptionContractSelection {
  const NiftyOptionContractSelection({
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.tradingSymbol,
    required this.lotSize,
    required this.side,
    required this.quantity,
    required this.entryPremium,
    this.lastPrice,
    this.bestBid,
    this.bestAsk,
    this.lastTradeTime,
  });

  final DateTime expiry;
  final int strike;
  final OptionType optionType;
  final String tradingSymbol;
  final int lotSize;
  final ExecutionSide side;
  final int quantity;
  final double? entryPremium;
  final double? lastPrice;
  final double? bestBid;
  final double? bestAsk;
  final String? lastTradeTime;
}

class NiftyOptionChainPage extends StatefulWidget {
  const NiftyOptionChainPage({
    super.key,
    this.initialExpiry,
    this.initialSelections = const [],
    this.existingLegs = const [],
    this.existingOnly = false,
  });

  final DateTime? initialExpiry;
  final List<NiftyOptionContractSelection> initialSelections;

  /// Existing position legs shown as read-only context; never returned as new selections.
  final List<NiftyOptionContractSelection> existingLegs;

  /// When true, the chain edits the supplied selections only. It cannot add,
  /// remove, or change the side of existing position legs.
  final bool existingOnly;

  @override
  State<NiftyOptionChainPage> createState() => _NiftyOptionChainPageState();
}

class _NiftyOptionChainPageState extends State<NiftyOptionChainPage> {
  bool _loading = true;
  bool _connected = false;
  bool _paired = false;
  bool _loadingChain = false;
  bool _pairing = false;
  final TextEditingController _pairingCodeController = TextEditingController();
  String? _error;
  List<DateTime> _expiries = [];
  DateTime? _selectedExpiry;
  Map<String, dynamic>? _chain;
  int _wingCount = 30;
  bool _newLegsInLots = true;
  final List<_SelectedChainLeg> _selectedLegs = [];

  @override
  void initState() {
    super.initState();
    for (final selection in widget.initialSelections) {
      _selectedLegs.add(_SelectedChainLeg.fromSelection(selection));
    }
    _initialize();
  }

  @override
  void dispose() {
    _pairingCodeController.dispose();
    for (final leg in _selectedLegs) {
      leg.dispose();
    }
    super.dispose();
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final token = await MarketDataAuth.readToken();
    if (token == null || token.isEmpty) {
      throw const _MarketDataException(
        'Pair this installation with the market-data server below first.',
      );
    }
    final response = await http
        .get(
          Uri.parse('$tradingMemoryMarketDataBaseUrl$path'),
          headers: {
            'X-Trading-Memory-Token': token,
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 30));
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw _MarketDataException(
        'The market-data backend returned an invalid response (HTTP ${response.statusCode}).',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = decoded is Map ? decoded['detail']?.toString() : null;
      throw _MarketDataException(
        detail ?? 'Market-data request failed (HTTP ${response.statusCode}).',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const _MarketDataException(
        'Unexpected response from the local market-data backend.',
      );
    }
    return decoded;
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _getJson('/api/status');
      _paired = true;
      _connected = status['kite_connected'] == true;
      if (_connected) {
        final expiryResponse = await _getJson('/api/nifty/expiries');
        _expiries = (expiryResponse['expiries'] as List<dynamic>? ?? [])
            .map((value) => DateTime.tryParse(value.toString()))
            .whereType<DateTime>()
            .toList();
        if (_expiries.isNotEmpty) {
          final requested = widget.initialExpiry;
          _selectedExpiry = requested == null
              ? _expiries.first
              : _expiries.reduce(
                  (a, b) =>
                      a.difference(requested).inDays.abs() <=
                          b.difference(requested).inDays.abs()
                      ? a
                      : b,
                );
          // The Strategy Builder's calendar date may not be an actual exchange
          // expiry. For a template/draft selection, carry the intended strikes
          // onto the nearest real Zerodha expiry instead of silently deleting
          // every leg (which previously left templates without premiums).
          for (final leg in _selectedLegs) {
            leg.expiry = _selectedExpiry!;
          }
          await _loadChain(showSpinner: false);
        }
      }
    } catch (error) {
      _paired = await MarketDataAuth.hasToken();
      _connected = false;
      _error = error.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadChain({bool showSpinner = true}) async {
    final expiry = _selectedExpiry;
    if (expiry == null) return;
    if (showSpinner && mounted) setState(() => _loadingChain = true);
    try {
      final expiryText = _dateKey(expiry);
      final response = await _getJson(
        '/api/nifty/chain?expiry=$expiryText&wing_count=$_wingCount',
      );
      if (mounted) {
        setState(() {
          _chain = response;
          _error = null;
          _resolveInitialContractDetails();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingChain = false);
    }
  }

  double? _positiveQuote(dynamic value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return parsed != null && parsed.isFinite && parsed > 0 ? parsed : null;
  }

  void _resolveInitialContractDetails() {
    final rows = _chain?['strikes'] as List<dynamic>? ?? const [];
    for (final leg in _selectedLegs) {
      for (final rawRow in rows) {
        final row = rawRow as Map<String, dynamic>;
        if ((row['strike'] as num?)?.toInt() != leg.strike) continue;
        final quote = row[leg.optionType == OptionType.call ? 'call' : 'put'];
        if (quote is! Map<String, dynamic>) continue;
        leg.tradingSymbol =
            quote['tradingsymbol']?.toString() ?? leg.tradingSymbol;
        final actualLotSize = (quote['lot_size'] as num?)?.toInt();
        if (actualLotSize != null && actualLotSize > 0) {
          leg.lotSize = actualLotSize;
          final currentQuantity = int.tryParse(
            leg.quantityController.text.trim(),
          );
          if (!widget.existingOnly &&
              currentQuantity == 1 &&
              actualLotSize > 1) {
            // A default quantity of one is not a valid NIFTY option lot.
            leg.quantityController.text = '$actualLotSize';
          }
        }
        final quotedLtp = _positiveQuote(quote['last_price']);
        final bid = _positiveQuote(quote['best_bid']);
        final ask = _positiveQuote(quote['best_ask']);
        if (quotedLtp != null) leg.lastPrice = quotedLtp;
        leg.bestBid = bid ?? leg.bestBid;
        leg.bestAsk = ask ?? leg.bestAsk;

        // A template starts with no premium. Prefer LTP, then the executable
        // side of the book (ask for buys, bid for sells). Never write zero or
        // replace a premium the user has already edited.
        if (leg.premiumController.text.trim().isEmpty) {
          final fallback =
              leg.lastPrice ??
              (leg.side == ExecutionSide.buy ? leg.bestAsk : leg.bestBid);
          if (fallback != null) {
            leg.premiumController.text = fallback.toStringAsFixed(2);
          }
        }
        leg.lastTradeTime =
            quote['last_trade_time']?.toString() ?? leg.lastTradeTime;
        break;
      }
    }
  }

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _timestampLabel(dynamic value) {
    if (value == null) return 'Quote time unavailable';
    final timestamp = DateTime.tryParse(value.toString())?.toLocal();
    if (timestamp == null) return 'Quote time unavailable';
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    final hh = timestamp.hour.toString().padLeft(2, '0');
    final mm = timestamp.minute.toString().padLeft(2, '0');
    return '$day/$month $hh:$mm';
  }

  void _selectContract(
    Map<String, dynamic> contract,
    int strike,
    OptionType type,
    ExecutionSide side,
  ) {
    final expiry = _selectedExpiry;
    if (expiry == null) return;
    if (widget.existingOnly) return;
    final alreadyInPosition = widget.existingLegs.any(
      (leg) =>
          leg.strike == strike &&
          leg.optionType == type &&
          _sameDate(leg.expiry, expiry),
    );
    if (alreadyInPosition) {
      _showMessage(
        'This contract is already in the position. Use Edit legs to correct its quantity, or Exit legs to close it.',
        error: true,
      );
      return;
    }
    final symbol = contract['tradingsymbol']?.toString() ?? '';
    final existingIndex = _selectedLegs.indexWhere(
      (leg) =>
          leg.strike == strike &&
          leg.optionType == type &&
          _sameDate(leg.expiry, expiry),
    );
    setState(() {
      if (existingIndex >= 0) {
        final existingLeg = _selectedLegs[existingIndex];
        if (existingLeg.side == side) {
          // Tapping the already-selected B/S action toggles this leg off.
          existingLeg.dispose();
          _selectedLegs.removeAt(existingIndex);
        } else {
          // Tapping the opposite action switches the existing leg's side.
          existingLeg.side = side;
        }
      } else {
        final lotSize = (contract['lot_size'] as num?)?.toInt() ?? 1;
        final quotedLtp = (contract['last_price'] as num?)?.toDouble();
        final ltp = quotedLtp != null && quotedLtp.isFinite && quotedLtp > 0
            ? quotedLtp
            : null;
        _selectedLegs.add(
          _SelectedChainLeg(
            expiry: expiry,
            strike: strike,
            optionType: type,
            tradingSymbol: symbol,
            lotSize: lotSize,
            side: side,
            quantityController: TextEditingController(
              text: _newLegsInLots ? '1' : '$lotSize',
            ),
            quantityInLots: _newLegsInLots,
            premiumController: TextEditingController(
              text: ltp?.toStringAsFixed(2) ?? '',
            ),
            lastPrice: ltp,
            bestBid: (contract['best_bid'] as num?)?.toDouble(),
            bestAsk: (contract['best_ask'] as num?)?.toDouble(),
            lastTradeTime: contract['last_trade_time']?.toString(),
          ),
        );
      }
    });
  }

  Future<void> _changeExpiry(DateTime? value) async {
    if (widget.existingOnly) return;
    if (value == null || _sameDate(value, _selectedExpiry!)) return;
    if (_selectedLegs.isNotEmpty) {
      for (final leg in _selectedLegs) {
        leg.dispose();
      }
      _selectedLegs.clear();
      _showMessage(
        'Selections were cleared because all legs in a trade must use the same expiry.',
      );
    }
    setState(() {
      _selectedExpiry = value;
      _chain = null;
    });
    await _loadChain();
  }

  void _removeSelectedLeg(_SelectedChainLeg leg) {
    setState(() => _selectedLegs.remove(leg));
    leg.dispose();
  }

  Future<void> _finishSelection() async {
    final result = <NiftyOptionContractSelection>[];
    for (final leg in _selectedLegs) {
      final enteredQuantity = int.tryParse(leg.quantityController.text.trim());
      final quantity = enteredQuantity == null
          ? null
          : (leg.quantityInLots
                ? enteredQuantity * leg.lotSize
                : enteredQuantity);
      final premiumText = leg.premiumController.text.trim();
      final enteredPremium = premiumText.isEmpty
          ? null
          : double.tryParse(premiumText);
      final premium =
          enteredPremium ??
          leg.lastPrice ??
          (leg.side == ExecutionSide.buy ? leg.bestAsk : leg.bestBid);
      if (quantity == null ||
          quantity <= 0 ||
          (leg.lotSize > 0 && quantity % leg.lotSize != 0)) {
        _showMessage(
          '${leg.strike} ${leg.optionType == OptionType.call ? 'CE' : 'PE'} quantity must be a positive multiple of lot size ${leg.lotSize}.',
          error: true,
        );
        return;
      }
      if (premium != null && (!premium.isFinite || premium < 0)) {
        _showMessage('Enter a valid non-negative entry premium.', error: true);
        return;
      }
      result.add(
        NiftyOptionContractSelection(
          expiry: leg.expiry,
          strike: leg.strike,
          optionType: leg.optionType,
          tradingSymbol: leg.tradingSymbol,
          lotSize: leg.lotSize,
          side: leg.side,
          quantity: quantity,
          entryPremium: premium,
          lastPrice: leg.lastPrice,
          bestBid: leg.bestBid,
          bestAsk: leg.bestAsk,
          lastTradeTime: leg.lastTradeTime,
        ),
      );
    }
    if (widget.existingOnly &&
        result.length != widget.initialSelections.length) {
      _showMessage(
        'Existing-leg editing cannot add or remove contracts.',
        error: true,
      );
      return;
    }
    if (result.isEmpty) {
      if (widget.existingOnly) {
        _showMessage(
          'At least one existing leg must remain. Use Exit legs to close a position.',
          error: true,
        );
        return;
      }
      Navigator.of(context).pop(result);
      return;
    }

    Navigator.of(context).pop(result);
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade800 : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NIFTY option chain'),
        actions: [
          if (!_loading && _connected && _expiries.isNotEmpty)
            TextButton(
              onPressed: _loadingChain ? null : _finishSelection,
              child: const Text('Done'),
            ),
          IconButton(
            tooltip: 'Refresh quotes',
            onPressed: _loading || _loadingChain ? null : () => _loadChain(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                _connectionCard(),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  _messageCard(_error!, isError: true),
                ],
                if (_connected && _expiries.isEmpty) ...[
                  const SizedBox(height: 10),
                  _messageCard(
                    'No upcoming NIFTY option expiries were returned by Zerodha. Refresh after checking your Kite session and instrument master.',
                  ),
                ],
                if (_connected && _expiries.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _expiryAndRangeControls(),
                  const SizedBox(height: 8),
                  if (_loadingChain) const LinearProgressIndicator(),
                  if (_chain != null) ...[
                    _spotCard(),
                    const SizedBox(height: 8),
                    _quoteFreshnessCard(),
                    const SizedBox(height: 8),
                    _chainHeader(),
                    for (final row
                        in (_chain!['strikes'] as List<dynamic>? ?? []))
                      _strikeRow(row as Map<String, dynamic>),
                    const SizedBox(height: 12),
                    Text(
                      widget.existingOnly
                          ? 'Edit the quantities and entry premiums for the existing legs below. Contracts and sides are locked in this mode; use Add legs or Exit legs for actual position changes.'
                          : 'Tap BUY or SELL directly on a call or put to add it. Adjust lots/quantity and entry premium below, remove unwanted selections, review the final selection, then tap Done. Only the confirmed new selections are added. LTP is a quote reference, not an executed fill.',
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _selectedLegsSection(),
                ],
              ],
            ),
      bottomNavigationBar: !_loading && _connected && _expiries.isNotEmpty
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: FilledButton.icon(
                onPressed: _loadingChain ? null : _finishSelection,
                icon: const Icon(Icons.check),
                label: Text(
                  'Done · ${_selectedLegs.length} selected leg${_selectedLegs.length == 1 ? '' : 's'}',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            )
          : null,
    );
  }

  Future<void> _pairDevice() async {
    if (_pairing) return;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      await MarketDataAuth.enroll(
        baseUrl: tradingMemoryMarketDataBaseUrl,
        pairingCode: _pairingCodeController.text,
      );
      _pairingCodeController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This installation is paired securely.'),
          ),
        );
      }
      await _initialize();
    } catch (error) {
      if (mounted)
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<void> _openZerodhaLogin() async {
    try {
      final token = await MarketDataAuth.readToken();
      if (token == null || token.isEmpty)
        throw StateError('Pair this installation first.');
      final ticketResponse = await http
          .post(
            Uri.parse('$tradingMemoryMarketDataBaseUrl/api/kite/login-ticket'),
            headers: {
              'X-Trading-Memory-Token': token,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (ticketResponse.statusCode < 200 || ticketResponse.statusCode >= 300) {
        throw StateError(
          'Could not prepare Zerodha login (HTTP ${ticketResponse.statusCode}).',
        );
      }
      final decoded = jsonDecode(ticketResponse.body);
      final ticket = decoded is Map ? decoded['ticket']?.toString() : null;
      if (ticket == null || ticket.isEmpty)
        throw StateError('The server did not issue a login ticket.');
      final uri = Uri.parse('$tradingMemoryMarketDataBaseUrl/api/kite/login')
          .replace(queryParameters: {'ticket': ticket});
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened)
        throw StateError('Could not open the hosted Zerodha login URL.');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    }
  }

  Widget _connectionCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _connected
                    ? Icons.check_circle
                    : (_paired ? Icons.warning_amber : Icons.link_off),
                color: _connected ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _connected
                      ? 'Zerodha connected'
                      : (_paired
                            ? 'App paired · Zerodha login needed'
                            : 'Connect to hosted market data'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(onPressed: _initialize, child: const Text('Check')),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _connected
                ? 'Live NIFTY contracts and quotes are served by your hosted backend. Your trade journal remains on this device.'
                : 'This app connects directly to your hosted HTTPS backend. Your Mac does not need to be running.',
            style: const TextStyle(color: Colors.black54, height: 1.35),
          ),
          if (!_paired) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _pairingCodeController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Server pairing code',
                helperText: 'Use TRADING_MEMORY_LOCAL_API_TOKEN from the server .env once.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _pairing ? null : _pairDevice,
                icon: _pairing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.phonelink_lock),
                label: Text(_pairing ? 'Pairing…' : 'Pair this installation'),
              ),
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 6),
            SelectableText(
              tradingMemoryMarketDataBaseUrl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_paired && !_connected) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openZerodhaLogin,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Connect Zerodha on hosted server'),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'After completing Zerodha login in the browser, return here and tap Check.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _expiryAndRangeControls() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<DateTime>(
              initialValue: _selectedExpiry,
              decoration: const InputDecoration(labelText: 'Expiry'),
              isExpanded: true,
              items: [
                for (final expiry in _expiries)
                  DropdownMenuItem(
                    value: expiry,
                    child: Text(_dateKey(expiry)),
                  ),
              ],
              onChanged: _loadingChain || widget.existingOnly
                  ? null
                  : _changeExpiry,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<int>(
              initialValue: _wingCount,
              decoration: const InputDecoration(labelText: 'Strikes each side'),
              items: const [5, 8, 12, 20, 30]
                  .map(
                    (value) =>
                        DropdownMenuItem(value: value, child: Text('$value')),
                  )
                  .toList(),
              onChanged: _loadingChain
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _wingCount = value);
                      _loadChain();
                    },
            ),
          ),
        ],
      ),
    ),
  );

  Widget _spotCard() {
    final spot = (_chain?['spot'] as num?)?.toDouble();
    return Card(
      color: const Color(0xFFEAF3F6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'NIFTY 50 spot',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              spot == null ? '—' : '₹${spot.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quoteFreshnessCard() {
    final snapshot = _chain?['snapshot_fetched_at']?.toString();
    final fetchedAt = snapshot == null
        ? null
        : DateTime.tryParse(snapshot)?.toLocal();
    final label = fetchedAt == null
        ? 'Quote timestamp unavailable'
        : 'Snapshot fetched ${_timestampLabel(snapshot)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.schedule, size: 18, color: Colors.black54),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$label. Prices may be stale outside market hours; refresh manually. Check each contract\'s quote time before relying on it.',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black54,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chainHeader() => Container(
    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF3F6),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Row(
      children: [
        Expanded(
          child: Text(
            'CALL · CE',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Text(
            'STRIKE',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Text(
            'PUT · PE',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );

  Widget _strikeRow(Map<String, dynamic> row) {
    final strike = (row['strike'] as num).toInt();
    final call = row['call'] as Map<String, dynamic>?;
    final put = row['put'] as Map<String, dynamic>?;
    final spot = (_chain?['spot'] as num?)?.toDouble();
    final isNearSpot = spot != null && (strike - spot).abs() < 30;
    return Container(
      margin: const EdgeInsets.only(top: 3),
      decoration: BoxDecoration(
        color: isNearSpot ? const Color(0xFFF0F6F8) : Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          Expanded(child: _quoteCell(call, strike, OptionType.call)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '$strike',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: isNearSpot ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(child: _quoteCell(put, strike, OptionType.put)),
        ],
      ),
    );
  }

  Widget _quoteCell(Map<String, dynamic>? quote, int strike, OptionType type) {
    final ltp = (quote?['last_price'] as num?)?.toDouble();
    final bid = (quote?['best_bid'] as num?)?.toDouble();
    final ask = (quote?['best_ask'] as num?)?.toDouble();
    final hasQuote = ltp != null && ltp.isFinite && ltp > 0;
    final matching = _selectedLegs
        .where(
          (leg) =>
              leg.strike == strike &&
              leg.optionType == type &&
              _sameDate(leg.expiry, _selectedExpiry!),
        )
        .toList();
    final selected = matching.isEmpty ? null : matching.first;
    final existing = widget.existingLegs
        .where(
          (leg) =>
              leg.strike == strike &&
              leg.optionType == type &&
              _sameDate(leg.expiry, _selectedExpiry!),
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        children: [
          Text(
            hasQuote ? ltp.toStringAsFixed(2) : '—',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: hasQuote ? const Color(0xFF176B87) : Colors.black38,
            ),
          ),
          Text(
            bid == null && ask == null
                ? 'B — · A —'
                : 'B ${bid?.toStringAsFixed(2) ?? '—'} · A ${ask?.toStringAsFixed(2) ?? '—'}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 8, color: Colors.black54),
          ),
          for (final leg in existing)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: leg.side == ExecutionSide.buy
                      ? const Color(0xFFE4F4E8)
                      : const Color(0xFFFFEBDD),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: leg.side == ExecutionSide.buy
                        ? Colors.green.shade300
                        : Colors.deepOrange.shade300,
                  ),
                ),
                child: Text(
                  'IN POSITION · ${leg.side == ExecutionSide.buy ? 'BUY' : 'SELL'} × ${leg.quantity}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    color: leg.side == ExecutionSide.buy
                        ? Colors.green.shade900
                        : Colors.deepOrange.shade900,
                  ),
                ),
              ),
            ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${selected.side == ExecutionSide.buy ? 'BUY' : 'SELL'} ✓ NEW',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: selected.side == ExecutionSide.buy
                      ? Colors.green.shade800
                      : Colors.deepOrange.shade800,
                ),
              ),
            ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: _actionButton(
                  'B',
                  ExecutionSide.buy,
                  quote,
                  strike,
                  type,
                  selected?.side == ExecutionSide.buy,
                  disabled: widget.existingOnly,
                ),
              ),
              const SizedBox(width: 3),
              Expanded(
                child: _actionButton(
                  'S',
                  ExecutionSide.sell,
                  quote,
                  strike,
                  type,
                  selected?.side == ExecutionSide.sell,
                  disabled: widget.existingOnly,
                ),
              ),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: 4),
            SizedBox(
              height: 34,
              child: TextField(
                controller: selected.quantityController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 7,
                  ),
                  labelText: selected.quantityInLots ? 'Lots' : 'Qty',
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 30,
                  ),
                  suffixIcon: _quantityModeSuffix(
                    isLots: selected.quantityInLots,
                    onChanged: (toLots) => setState(() {
                      final entered = int.tryParse(
                        selected.quantityController.text.trim(),
                      );
                      if (entered != null && entered > 0) {
                        if (toLots) {
                          if (entered % selected.lotSize != 0) {
                            _showMessage(
                              'Quantity must be a multiple of ${selected.lotSize} units to switch to lots.',
                              error: true,
                            );
                            return;
                          }
                          selected.quantityController.text =
                              '${entered ~/ selected.lotSize}';
                        } else {
                          selected.quantityController.text =
                              '${entered * selected.lotSize}';
                        }
                      }
                      selected.quantityInLots = toLots;
                    }),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
          const SizedBox(height: 3),
          InkWell(
            onTap: () => setState(() => _newLegsInLots = !_newLegsInLots),
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE7F2F5),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFFB8D6DF)),
              ),
              child: Text(
                _newLegsInLots ? 'Lots  |  Qty' : 'Qty  |  Lots',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    String label,
    ExecutionSide side,
    Map<String, dynamic>? quote,
    int strike,
    OptionType type,
    bool selected, {
    bool disabled = false,
  }) => SizedBox(
    height: 28,
    child: FilledButton(
      onPressed: quote == null || disabled
          ? null
          : () => _selectContract(quote, strike, type, side),
      style: FilledButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: selected
            ? (side == ExecutionSide.buy
                  ? Colors.green.shade700
                  : Colors.deepOrange.shade700)
            : (side == ExecutionSide.buy
                  ? const Color(0xFFE6F4EA)
                  : const Color(0xFFFFEEE5)),
        foregroundColor: selected
            ? Colors.white
            : (side == ExecutionSide.buy
                  ? Colors.green.shade900
                  : Colors.deepOrange.shade900),
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
      ),
      child: Text(label),
    ),
  );

  Widget _selectedLegsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Selected legs (${_selectedLegs.length})',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (_selectedLegs.isNotEmpty && !widget.existingOnly)
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        for (final leg in _selectedLegs) {
                          leg.dispose();
                        }
                        _selectedLegs.clear();
                      });
                    },
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('Clear'),
                  ),
              ],
            ),
            if (_selectedLegs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Tap B or S on any CE/PE quote to add a leg. You can select several legs before tapping Done.',
                  style: TextStyle(color: Colors.black54, height: 1.35),
                ),
              ),
            for (var index = 0; index < _selectedLegs.length; index++)
              _selectedLegEditor(index, _selectedLegs[index]),
          ],
        ),
      ),
    );
  }

  Widget _selectedLegEditor(int index, _SelectedChainLeg leg) {
    final option = leg.optionType == OptionType.call ? 'CE' : 'PE';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E7EA)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${index + 1}. ${leg.strike} $option',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                'Lot ${leg.lotSize}',
                style: const TextStyle(fontSize: 11, color: Colors.black54),
              ),
              if (!widget.existingOnly)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove leg',
                  onPressed: () => _removeSelectedLeg(leg),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          SegmentedButton<ExecutionSide>(
            segments: const [
              ButtonSegment(value: ExecutionSide.buy, label: Text('BUY')),
              ButtonSegment(value: ExecutionSide.sell, label: Text('SELL')),
            ],
            selected: {leg.side},
            onSelectionChanged: (values) =>
                setState(() => leg.side = values.first),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: leg.quantityController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: leg.quantityInLots
                        ? 'Quantity (lots)'
                        : 'Quantity (units)',
                    helperText: leg.quantityInLots
                        ? '1 lot = ${leg.lotSize} units'
                        : 'Multiple of ${leg.lotSize}',
                    suffixIcon: _quantityModeSuffix(
                      isLots: leg.quantityInLots,
                      onChanged: (toLots) => setState(() {
                        final entered = int.tryParse(
                          leg.quantityController.text.trim(),
                        );
                        if (entered != null && entered > 0) {
                          if (toLots) {
                            if (entered % leg.lotSize != 0) {
                              _showMessage(
                                'Quantity must be a multiple of ${leg.lotSize} units to switch to lots.',
                                error: true,
                              );
                              return;
                            }
                            leg.quantityController.text =
                                '${entered ~/ leg.lotSize}';
                          } else {
                            leg.quantityController.text =
                                '${entered * leg.lotSize}';
                          }
                        }
                        leg.quantityInLots = toLots;
                      }),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: leg.premiumController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Entry premium ₹',
                    helperText: leg.lastPrice == null
                        ? 'No LTP; enter manually'
                        : 'LTP ref ₹${leg.lastPrice!.toStringAsFixed(2)}',
                  ),
                ),
              ),
            ],
          ),
          if (leg.lastTradeTime != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Last trade ${_timestampLabel(leg.lastTradeTime)} · may be stale',
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
            ),
        ],
      ),
    );
  }

  Widget _quantityModeSuffix({
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
            color: const Color(0xFFE7F2F5),
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

  Widget _messageCard(String message, {bool isError = false}) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        style: TextStyle(
          color: isError ? Colors.red.shade800 : Colors.black54,
          height: 1.4,
        ),
      ),
    ),
  );
}

class _SelectedChainLeg {
  _SelectedChainLeg({
    required this.expiry,
    required this.strike,
    required this.optionType,
    required this.tradingSymbol,
    required this.lotSize,
    required this.side,
    required this.quantityController,
    required this.premiumController,
    this.quantityInLots = false,
    this.lastPrice,
    this.bestBid,
    this.bestAsk,
    this.lastTradeTime,
  });

  factory _SelectedChainLeg.fromSelection(
    NiftyOptionContractSelection selection,
  ) => _SelectedChainLeg(
    expiry: selection.expiry,
    strike: selection.strike,
    optionType: selection.optionType,
    tradingSymbol: selection.tradingSymbol,
    lotSize: selection.lotSize,
    side: selection.side,
    quantityController: TextEditingController(text: '${selection.quantity}'),
    premiumController: TextEditingController(
      text: selection.entryPremium?.toStringAsFixed(2) ?? '',
    ),
    lastPrice: selection.lastPrice,
    bestBid: selection.bestBid,
    bestAsk: selection.bestAsk,
    lastTradeTime: selection.lastTradeTime,
  );

  DateTime expiry;
  final int strike;
  final OptionType optionType;
  String tradingSymbol;
  int lotSize;
  bool quantityInLots = false;
  ExecutionSide side;
  final TextEditingController quantityController;
  final TextEditingController premiumController;
  double? lastPrice;
  double? bestBid;
  double? bestAsk;
  String? lastTradeTime;

  void dispose() {
    quantityController.dispose();
    premiumController.dispose();
  }
}

class _MarketDataException implements Exception {
  const _MarketDataException(this.message);
  final String message;
  @override
  String toString() => message;
}
