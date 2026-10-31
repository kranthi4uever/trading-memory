import '../../../domain/trade/strategy_structure.dart';

import '../../../domain/trade/trade.dart';

import '../../../domain/trade/trade_id.dart';

import '../../../domain/trade/trade_mode.dart';

import '../../../domain/trade/trade_status.dart';

import '../../../domain/trading/execution/execution.dart';

import '../../../domain/trading/execution/execution_id.dart';

import '../../../domain/trading/execution/execution_inbox_entry.dart';

import '../../../domain/trading/execution/execution_source.dart';

import '../../../domain/trading/execution/expiry_date.dart';

import '../../../domain/trading/execution/option_contract.dart';

import '../../../domain/trading/trading_repository.dart';

import 'trading_database.dart';

import 'package:sqflite/sqflite.dart';

import 'dart:convert';

import '../../../domain/trading/adjustment/adjustment_episode.dart';
import '../../../domain/trading/adjustment/adjustment_reason.dart';
import '../../../domain/trading/adjustment/position_view_assessment.dart';

import '../../../domain/trading/decision/decision_record.dart';

import '../../../domain/trading/position_state/economic_snapshot.dart';

import '../../../domain/trading/position_state/geometry_snapshot.dart';

import '../../../domain/trading/position_state/market_snapshot.dart';

import '../../../domain/trading/position_state/position_leg.dart';

import '../../../domain/trading/position_state/position_snapshot.dart';

import '../../../domain/trading/position_state/position_state.dart';

import '../../../domain/trading/position_state/position_state_id.dart';

import '../../../domain/trading/position_state/risk_snapshot.dart';

class SqliteTradingRepository implements TradingRepository {
  final TradingDatabase _tradingDatabase;

  SqliteTradingRepository(this._tradingDatabase);

  @override
  Future<void> importBrokerExecution({
    required ExecutionInboxEntry entry,
  }) async {
    final execution = entry.execution;

    if (execution.source != ExecutionSource.broker) {
      throw ArgumentError('Only broker-sourced executions can be imported.');
    }

    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final existingById = await txn.query(
        'executions',

        where: 'id = ?',

        whereArgs: [execution.id.value],

        limit: 1,
      );

      if (existingById.isNotEmpty) {
        _ensureSameExecution(existingById.single, execution);

        return;
      }

      final brokerTradeId = execution.brokerTradeId;

      if (brokerTradeId != null) {
        final existingByBrokerId = await txn.query(
          'executions',

          where: 'broker_trade_id = ?',

          whereArgs: [brokerTradeId],

          limit: 1,
        );

        if (existingByBrokerId.isNotEmpty) {
          _ensureSameExecution(existingByBrokerId.single, execution);

          return;
        }
      }

      await txn.insert('executions', {
        'id': execution.id.value,

        'executed_at': execution.executedAt.toIso8601String(),

        'underlying': execution.contract.underlying,

        'expiry_year': execution.contract.expiry.value.year,

        'expiry_month': execution.contract.expiry.value.month,

        'expiry_day': execution.contract.expiry.value.day,

        'strike': execution.contract.strike,

        'option_type': execution.contract.optionType.name,

        'side': execution.side.name,

        'source': execution.source.name,

        'quantity': execution.quantity,

        'price': execution.price,

        'broker_trade_id': execution.brokerTradeId,

        'broker_order_id': execution.brokerOrderId,

        'received_at': entry.receivedAt.toIso8601String(),
      });
    });
  }

  @override
  Future<List<ExecutionInboxEntry>> getUnassignedExecutions() async {
    final db = await _tradingDatabase.database;

    final rows = await db.rawQuery('''

      SELECT e.*

      FROM executions e

      LEFT JOIN execution_assignments a

        ON a.execution_id = e.id

      WHERE a.execution_id IS NULL

        AND e.source = 'broker'

      ORDER BY e.executed_at ASC, e.id ASC

    ''');

    return List.unmodifiable(rows.map(_mapInboxEntry));
  }

  @override
  Future<Trade> createDraftPaperTrade({
    required TradeId tradeId,

    required List<Execution> executions,
  }) async {
    if (executions.isEmpty)
      throw ArgumentError('A Paper trade requires at least one execution.');

    if (executions.any((e) => e.source != ExecutionSource.manual)) {
      throw ArgumentError('Paper trades require manually entered executions.');
    }

    final ids = executions.map((e) => e.id.value).toSet();

    if (ids.length != executions.length)
      throw ArgumentError('Paper executions contain duplicate IDs.');

    final first = executions.first;

    if (executions.any(
      (e) =>
          e.contract.underlying != first.contract.underlying ||
          e.contract.expiry != first.contract.expiry,
    )) {
      throw ArgumentError(
        'All legs in a trade must share an underlying and expiry.',
      );
    }

    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final existingTrade = await txn.query(
        'trades',

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (existingTrade.isNotEmpty)
        throw StateError('A trade with this ID already exists.');

      for (final execution in executions) {
        final existingExecution = await txn.query(
          'executions',

          where: 'id = ?',

          whereArgs: [execution.id.value],

          limit: 1,
        );

        if (existingExecution.isNotEmpty)
          throw StateError('Execution ${execution.id.value} already exists.');
      }

      await txn.insert('trades', {
        'id': tradeId.value,

        'mode': TradeMode.paper.name,

        'strategy': StrategyStructure.unknown.name,

        'status': TradeStatus.draft.name,

        'confirmed_at': null,

        'closed_at': null,
      });

      final assignedAt = DateTime.now().toIso8601String();

      for (final execution in executions) {
        final expiry = execution.contract.expiry.value;

        await txn.insert('executions', {
          'id': execution.id.value,

          'executed_at': execution.executedAt.toIso8601String(),

          'underlying': execution.contract.underlying,

          'expiry_year': expiry.year,

          'expiry_month': expiry.month,

          'expiry_day': expiry.day,

          'strike': execution.contract.strike,

          'option_type': execution.contract.optionType.name,

          'side': execution.side.name,

          'source': execution.source.name,

          'quantity': execution.quantity,

          'price': execution.price,

          'broker_trade_id': null,

          'broker_order_id': null,

          'received_at': null,
        });

        await txn.insert('execution_assignments', {
          'execution_id': execution.id.value,

          'trade_id': tradeId.value,

          'assigned_at': assignedAt,
        });
      }
    });

    return Trade(
      id: tradeId,

      mode: TradeMode.paper,

      executions: executions,

      strategy: StrategyStructure.unknown,

      status: TradeStatus.draft,
    );
  }

  @override
  Future<Trade> updateDraftPaperTrade({
    required TradeId tradeId,

    required List<Execution> executions,
  }) async {
    if (executions.isEmpty) {
      throw ArgumentError('A Paper trade requires at least one execution.');
    }

    if (executions.any((e) => e.source != ExecutionSource.manual)) {
      throw ArgumentError('Paper trades require manually entered executions.');
    }

    final ids = executions.map((e) => e.id.value).toSet();

    if (ids.length != executions.length) {
      throw ArgumentError('Paper executions contain duplicate IDs.');
    }

    final first = executions.first;

    if (executions.any(
      (e) =>
          e.contract.underlying != first.contract.underlying ||
          e.contract.expiry != first.contract.expiry,
    )) {
      throw ArgumentError(
        'All legs in a trade must share an underlying and expiry.',
      );
    }

    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final tradeRows = await txn.query(
        'trades',

        columns: ['mode', 'status'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (tradeRows.isEmpty)
        throw StateError('Trade does not exist: ${tradeId.value}');

      if (tradeRows.single['mode'] != TradeMode.paper.name ||
          tradeRows.single['status'] != TradeStatus.draft.name) {
        throw StateError('Only a draft Paper trade can be edited.');
      }

      final existingRows = await txn.rawQuery(
        '''

        SELECT e.* FROM executions e

        INNER JOIN execution_assignments a ON a.execution_id = e.id

        WHERE a.trade_id = ?

      ''',

        [tradeId.value],
      );

      if (existingRows.any(
        (row) => row['source'] != ExecutionSource.manual.name,
      )) {
        throw StateError(
          'A Paper draft contains a non-manual execution and cannot be edited.',
        );
      }

      final existingIds = existingRows
          .map((row) => row['id'] as String)
          .toSet();

      final removedIds = existingIds.difference(ids);

      for (final id in removedIds) {
        await txn.delete(
          'execution_assignments',

          where: 'execution_id = ?',

          whereArgs: [id],
        );

        await txn.delete('executions', where: 'id = ?', whereArgs: [id]);
      }

      final assignedAt = DateTime.now().toIso8601String();

      for (final execution in executions) {
        final expiry = execution.contract.expiry.value;

        final values = <String, Object?>{
          'id': execution.id.value,

          'executed_at': execution.executedAt.toIso8601String(),

          'underlying': execution.contract.underlying,

          'expiry_year': expiry.year,

          'expiry_month': expiry.month,

          'expiry_day': expiry.day,

          'strike': execution.contract.strike,

          'option_type': execution.contract.optionType.name,

          'side': execution.side.name,

          'source': execution.source.name,

          'quantity': execution.quantity,

          'price': execution.price,

          'broker_trade_id': null,

          'broker_order_id': null,

          'received_at': null,
        };

        if (existingIds.contains(execution.id.value)) {
          await txn.update(
            'executions',

            values,

            where: 'id = ?',

            whereArgs: [execution.id.value],
          );
        } else {
          final collision = await txn.query(
            'executions',

            where: 'id = ?',

            whereArgs: [execution.id.value],

            limit: 1,
          );

          if (collision.isNotEmpty) {
            throw StateError(
              'Execution ${execution.id.value} already exists outside this draft.',
            );
          }

          await txn.insert('executions', values);

          await txn.insert('execution_assignments', {
            'execution_id': execution.id.value,

            'trade_id': tradeId.value,

            'assigned_at': assignedAt,
          });
        }
      }
    });

    final updated = await getTrade(tradeId);

    if (updated == null)
      throw StateError('Updated draft could not be reloaded.');

    return updated;
  }

  @override
  Future<Trade> createDraftRealTrade({
    required TradeId tradeId,

    required List<ExecutionId> executionIds,
  }) async {
    if (executionIds.isEmpty) {
      throw ArgumentError('A Real trade requires at least one execution.');
    }

    final uniqueIds = executionIds.map((id) => id.value).toSet();

    if (uniqueIds.length != executionIds.length) {
      throw ArgumentError('The execution selection contains duplicate IDs.');
    }

    final db = await _tradingDatabase.database;

    late final List<Execution> selectedExecutions;

    await db.transaction((txn) async {
      final existingTrade = await txn.query(
        'trades',

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (existingTrade.isNotEmpty) {
        throw StateError('A trade with this ID already exists.');
      }

      final executions = <Execution>[];

      for (final executionId in executionIds) {
        final rows = await txn.query(
          'executions',

          where: 'id = ?',

          whereArgs: [executionId.value],

          limit: 1,
        );

        if (rows.isEmpty) {
          throw StateError('Execution ${executionId.value} does not exist.');
        }

        final execution = _mapExecution(rows.single);

        if (execution.source != ExecutionSource.broker) {
          throw StateError(
            'A Real trade can only be created from broker executions.',
          );
        }

        final assignments = await txn.query(
          'execution_assignments',

          where: 'execution_id = ?',

          whereArgs: [executionId.value],

          limit: 1,
        );

        if (assignments.isNotEmpty) {
          throw StateError(
            'Execution ${executionId.value} is already assigned.',
          );
        }

        executions.add(execution);
      }

      await txn.insert('trades', {
        'id': tradeId.value,

        'mode': TradeMode.real.name,

        'strategy': StrategyStructure.unknown.name,

        'status': TradeStatus.draft.name,

        'confirmed_at': null,

        'closed_at': null,
      });

      final assignedAt = DateTime.now().toIso8601String();

      for (final executionId in executionIds) {
        await txn.insert('execution_assignments', {
          'execution_id': executionId.value,

          'trade_id': tradeId.value,

          'assigned_at': assignedAt,
        });
      }

      selectedExecutions = List.unmodifiable(executions);
    });

    return Trade(
      id: tradeId,

      mode: TradeMode.real,

      executions: selectedExecutions,

      strategy: StrategyStructure.unknown,

      status: TradeStatus.draft,
    );
  }

  @override
  Future<void> confirmTrade({
    required TradeId tradeId,

    required StrategyStructure strategy,

    required DateTime confirmedAt,
  }) async {
    if (strategy == StrategyStructure.unknown) {
      throw ArgumentError(
        'A trade cannot be confirmed with an unknown strategy.',
      );
    }

    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'trades',

        columns: ['status'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (rows.isEmpty) {
        throw StateError('Trade does not exist: ${tradeId.value}');
      }

      final status = rows.single['status'];

      if (status != TradeStatus.draft.name) {
        throw StateError(
          'Only a draft trade can be confirmed. Current status: $status',
        );
      }

      final updated = await txn.update(
        'trades',

        {
          'strategy': strategy.name,

          'status': TradeStatus.confirmed.name,

          'confirmed_at': confirmedAt.toIso8601String(),
        },

        where: 'id = ? AND status = ?',

        whereArgs: [tradeId.value, TradeStatus.draft.name],
      );

      if (updated != 1) {
        throw StateError('Trade could not be confirmed: ${tradeId.value}');
      }
    });
  }

  @override
  Future<List<Trade>> getTrades() async {
    final db = await _tradingDatabase.database;

    final rows = await db.rawQuery('''

      SELECT id FROM trades

      ORDER BY CASE WHEN status = 'draft' THEN 0 ELSE 1 END,

               confirmed_at DESC, id DESC

    ''');

    final trades = <Trade>[];

    for (final row in rows) {
      final trade = await getTrade(TradeId(row['id'] as String));

      if (trade != null) trades.add(trade);
    }

    return List.unmodifiable(trades);
  }

  @override
  Future<Trade?> getTrade(TradeId tradeId) async {
    final db = await _tradingDatabase.database;

    final tradeRows = await db.query(
      'trades',

      where: 'id = ?',

      whereArgs: [tradeId.value],

      limit: 1,
    );

    if (tradeRows.isEmpty) {
      return null;
    }

    final tradeRow = tradeRows.single;

    final executionRows = await db.rawQuery(
      '''

      SELECT e.*

      FROM executions e

      INNER JOIN execution_assignments a

        ON a.execution_id = e.id

      WHERE a.trade_id = ?

      ORDER BY e.executed_at ASC, e.id ASC

      ''',

      [tradeId.value],
    );

    final stateRows = await db.query(
      'position_states',

      where: 'trade_id = ?',

      whereArgs: [tradeId.value],

      orderBy: 'captured_at ASC, id ASC',
    );

    final states = <PositionState>[];

    for (final row in stateRows) {
      states.add(await _loadPositionState(db, row));
    }

    final decisionRows = await db.query(
      'decision_records',

      where: 'trade_id = ?',

      whereArgs: [tradeId.value],

      orderBy: 'recorded_at ASC, id ASC',
    );

    final decisions = decisionRows
        .map((row) {
          return DecisionRecord(
            recordedAt: DateTime.parse(row['recorded_at'] as String),

            positionStateId: PositionStateId(
              row['position_state_id'] as String,
            ),

            action: DecisionAction.values.byName(row['action'] as String),

            observation: row['observation'] as String?,
          );
        })
        .toList(growable: false);

    return Trade(
      id: tradeId,

      mode: TradeMode.values.byName(tradeRow['mode'] as String),

      executions: executionRows.map(_mapExecution).toList(),

      positionStates: states,

      decisionRecords: decisions,

      strategy: StrategyStructure.values.byName(tradeRow['strategy'] as String),

      status: TradeStatus.values.byName(tradeRow['status'] as String),

      confirmedAt: tradeRow['confirmed_at'] == null
          ? null
          : DateTime.parse(tradeRow['confirmed_at'] as String),

      closedAt: tradeRow['closed_at'] == null
          ? null
          : DateTime.parse(tradeRow['closed_at'] as String),
    );
  }

  ExecutionInboxEntry _mapInboxEntry(Map<String, Object?> row) {
    final receivedAt = row['received_at'] as String?;

    if (receivedAt == null) {
      throw StateError(
        'Broker execution ${row['id']} has no received timestamp.',
      );
    }

    return ExecutionInboxEntry(
      execution: _mapExecution(row),

      receivedAt: DateTime.parse(receivedAt),
    );
  }

  Execution _mapExecution(Map<String, Object?> row) {
    return Execution(
      id: ExecutionId(row['id'] as String),

      executedAt: DateTime.parse(row['executed_at'] as String),

      contract: OptionContract(
        underlying: row['underlying'] as String,

        expiry: ExpiryDate(
          row['expiry_year'] as int,

          row['expiry_month'] as int,

          row['expiry_day'] as int,
        ),

        strike: (row['strike'] as num).toInt(),

        optionType: OptionType.values.byName(row['option_type'] as String),
      ),

      side: ExecutionSide.values.byName(row['side'] as String),

      source: ExecutionSource.values.byName(row['source'] as String),

      quantity: row['quantity'] as int,

      price: (row['price'] as num).toDouble(),

      brokerTradeId: row['broker_trade_id'] as String?,

      brokerOrderId: row['broker_order_id'] as String?,
    );
  }

  void _ensureSameExecution(Map<String, Object?> row, Execution execution) {
    final isSame =
        row['executed_at'] == execution.executedAt.toIso8601String() &&
        row['underlying'] == execution.contract.underlying &&
        row['expiry_year'] == execution.contract.expiry.value.year &&
        row['expiry_month'] == execution.contract.expiry.value.month &&
        row['expiry_day'] == execution.contract.expiry.value.day &&
        (row['strike'] as num).toDouble() == execution.contract.strike &&
        row['option_type'] == execution.contract.optionType.name &&
        row['side'] == execution.side.name &&
        row['quantity'] == execution.quantity &&
        (row['price'] as num).toDouble() == execution.price &&
        row['broker_order_id'] == execution.brokerOrderId;

    if (!isSame) {
      throw StateError(
        'An existing execution identity was received with conflicting data.',
      );
    }
  }

  Future<PositionState> _loadPositionState(
    DatabaseExecutor db,

    Map<String, Object?> row,
  ) async {
    final stateId = row['id'] as String;

    final detailRows = await db.query(
      'position_snapshot_details',

      where: 'position_state_id = ?',

      whereArgs: [stateId],

      limit: 1,
    );

    final details = detailRows.isEmpty
        ? <String, Object?>{}
        : detailRows.single;

    final legRows = await db.query(
      'position_legs',

      where: 'position_state_id = ?',

      whereArgs: [stateId],

      orderBy: 'id ASC',
    );

    final legs = legRows
        .map((leg) {
          return PositionLeg(
            contract: OptionContract(
              underlying: leg['underlying'] as String,

              expiry: ExpiryDate(
                leg['expiry_year'] as int,

                leg['expiry_month'] as int,

                leg['expiry_day'] as int,
              ),

              strike: (leg['strike'] as num).toInt(),

              optionType: OptionType.values.byName(
                leg['option_type'] as String,
              ),
            ),

            side: PositionSide.values.byName(leg['side'] as String),

            quantity: leg['quantity'] as int,

            entryPremium: (leg['entry_premium'] as num?)?.toDouble(),

            marketPrice: (leg['market_price'] as num?)?.toDouble(),
          );
        })
        .toList(growable: false);

    final market = await _loadRequiredSnapshot(
      db,

      'market_snapshots',

      stateId,

      (snapshot) => MarketSnapshot(
        spot: (snapshot['spot'] as num?)?.toDouble(),

        vix: (snapshot['vix'] as num?)?.toDouble(),

        atmStraddle: (snapshot['atm_straddle'] as num?)?.toDouble(),
      ),
    );

    final geometry = await _loadRequiredSnapshot(
      db,

      'geometry_snapshots',

      stateId,

      (snapshot) => GeometrySnapshot(
        lowerBreakeven: (snapshot['lower_breakeven'] as num?)?.toDouble(),

        upperBreakeven: (snapshot['upper_breakeven'] as num?)?.toDouble(),

        wingWidth: (snapshot['wing_width'] as num?)?.toDouble(),

        distanceToLowerBreakeven:
            (snapshot['distance_to_lower_breakeven'] as num?)?.toDouble(),

        distanceToUpperBreakeven:
            (snapshot['distance_to_upper_breakeven'] as num?)?.toDouble(),

        profitRange: (snapshot['profit_range'] as num?)?.toDouble(),
      ),
    );

    final economics = await _loadRequiredSnapshot(
      db,

      'economic_snapshots',

      stateId,

      (snapshot) => EconomicSnapshot(
        pnl: (snapshot['pnl'] as num?)?.toDouble(),

        pnlPercentage: (snapshot['pnl_percentage'] as num?)?.toDouble(),

        capitalDeployed: (snapshot['capital_deployed'] as num?)?.toDouble(),

        margin: (snapshot['margin'] as num?)?.toDouble(),

        cost: (snapshot['cost'] as num?)?.toDouble(),
        grossRealizedPnl: (snapshot['gross_realized_pnl'] as num?)?.toDouble(),
        grossUnrealizedPnl: (snapshot['gross_unrealized_pnl'] as num?)
            ?.toDouble(),
        snapshotCharges: (snapshot['snapshot_charges'] as num?)?.toDouble(),
        actualCharges: (snapshot['actual_charges'] as num?)?.toDouble(),
        netRealizedPnl: (snapshot['net_realized_pnl'] as num?)?.toDouble(),
        returnOnMarginPercentage:
            (snapshot['return_on_margin_percentage'] as num?)?.toDouble(),
        actualRiskCommitted: (snapshot['actual_risk_committed'] as num?)
            ?.toDouble(),
        grossRMultiple: (snapshot['gross_r_multiple'] as num?)?.toDouble(),
        netRMultiple: (snapshot['net_r_multiple'] as num?)?.toDouble(),
        maxMarginBlocked: (snapshot['max_margin_blocked'] as num?)?.toDouble(),
        actualProfitTarget: (snapshot['actual_profit_target'] as num?)
            ?.toDouble(),
      ),
    );

    final risk = await _loadRequiredSnapshot(
      db,

      'risk_snapshots',

      stateId,

      (snapshot) => RiskSnapshot(
        maxProfit: (snapshot['max_profit'] as num?)?.toDouble(),

        maxLoss: (snapshot['max_loss'] as num?)?.toDouble(),

        delta: (snapshot['delta'] as num?)?.toDouble(),

        gamma: (snapshot['gamma'] as num?)?.toDouble(),

        theta: (snapshot['theta'] as num?)?.toDouble(),

        vega: (snapshot['vega'] as num?)?.toDouble(),

        iv: (snapshot['iv'] as num?)?.toDouble(),
      ),
    );

    return PositionState(
      id: PositionStateId(stateId),

      tradeId: row['trade_id'] as String,

      capturedAt: DateTime.parse(row['captured_at'] as String),

      position: PositionSnapshot(
        underlying: row['underlying'] as String,

        expiry: ExpiryDate(
          row['expiry_year'] as int,

          row['expiry_month'] as int,

          row['expiry_day'] as int,
        ),

        legs: legs,

        strategy: StrategyStructure.values.byName(row['strategy'] as String),

        entryDebitCredit: (details['entry_debit_credit'] as num?)?.toDouble(),

        comments: details['comments'] as String?,

        plannedRules: details['planned_rules'] as String?,
      ),

      market: market,

      geometry: geometry,

      economics: economics,

      risk: risk,
    );
  }

  Future<T> _loadRequiredSnapshot<T>(
    DatabaseExecutor db,

    String table,

    String stateId,

    T Function(Map<String, Object?> row) map,
  ) async {
    final rows = await db.query(
      table,

      where: 'position_state_id = ?',

      whereArgs: [stateId],

      limit: 1,
    );

    if (rows.isEmpty) {
      throw StateError('Position state $stateId is missing its $table record.');
    }

    return map(rows.single);
  }

  @override
  Future<void> capturePositionState({
    required TradeId tradeId,

    required PositionState state,
  }) async {
    if (state.tradeId != tradeId.value) {
      throw ArgumentError('PositionState belongs to a different trade.');
    }

    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final tradeRows = await txn.query(
        'trades',

        columns: ['status'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (tradeRows.isEmpty) {
        throw StateError('Trade does not exist: ${tradeId.value}');
      }

      if (tradeRows.single['status'] != TradeStatus.confirmed.name) {
        throw StateError(
          'PositionState can only be captured for a confirmed trade.',
        );
      }

      final existingState = await txn.query(
        'position_states',

        columns: ['id'],

        where: 'id = ?',

        whereArgs: [state.id.value],

        limit: 1,
      );

      if (existingState.isNotEmpty) {
        throw StateError('PositionState already exists: ${state.id.value}');
      }

      final position = state.position;

      final expiry = position.expiry.value;

      await txn.insert('position_states', {
        'id': state.id.value,

        'trade_id': tradeId.value,

        'captured_at': state.capturedAt.toIso8601String(),

        'underlying': position.underlying,

        'expiry_year': expiry.year,

        'expiry_month': expiry.month,

        'expiry_day': expiry.day,

        'strategy': position.strategy.name,
      });

      await txn.insert('position_snapshot_details', {
        'position_state_id': state.id.value,

        'entry_debit_credit': position.entryDebitCredit,

        'comments': position.comments,

        'planned_rules': position.plannedRules,
      });

      for (final leg in position.legs) {
        final contract = leg.contract;

        final legExpiry = contract.expiry.value;

        await txn.insert('position_legs', {
          'position_state_id': state.id.value,

          'underlying': contract.underlying,

          'expiry_year': legExpiry.year,

          'expiry_month': legExpiry.month,

          'expiry_day': legExpiry.day,

          'strike': contract.strike,

          'option_type': contract.optionType.name,

          'side': leg.side.name,

          'quantity': leg.quantity,

          'entry_premium': leg.entryPremium,

          'market_price': leg.marketPrice,
        });
      }

      await txn.insert('market_snapshots', {
        'position_state_id': state.id.value,

        'spot': state.market.spot,

        'vix': state.market.vix,

        'atm_straddle': state.market.atmStraddle,
      });

      await txn.insert('geometry_snapshots', {
        'position_state_id': state.id.value,

        'lower_breakeven': state.geometry.lowerBreakeven,

        'upper_breakeven': state.geometry.upperBreakeven,

        'wing_width': state.geometry.wingWidth,

        'distance_to_lower_breakeven': state.geometry.distanceToLowerBreakeven,

        'distance_to_upper_breakeven': state.geometry.distanceToUpperBreakeven,

        'profit_range': state.geometry.profitRange,
      });

      await txn.insert('economic_snapshots', {
        'position_state_id': state.id.value,

        'pnl': state.economics.pnl,

        'pnl_percentage': state.economics.pnlPercentage,

        'capital_deployed': state.economics.capitalDeployed,

        'margin': state.economics.margin,

        'cost': state.economics.cost,
        'gross_realized_pnl': state.economics.grossRealizedPnl,
        'gross_unrealized_pnl': state.economics.grossUnrealizedPnl,
        'snapshot_charges': state.economics.snapshotCharges,
        'actual_charges': state.economics.actualCharges,
        'net_realized_pnl': state.economics.netRealizedPnl,
        'return_on_margin_percentage': state.economics.returnOnMarginPercentage,
        'actual_risk_committed': state.economics.actualRiskCommitted,
        'gross_r_multiple': state.economics.grossRMultiple,
        'net_r_multiple': state.economics.netRMultiple,
        'max_margin_blocked': state.economics.maxMarginBlocked,
        'actual_profit_target': state.economics.actualProfitTarget,
      });

      await txn.insert('risk_snapshots', {
        'position_state_id': state.id.value,

        'max_profit': state.risk.maxProfit,

        'max_loss': state.risk.maxLoss,

        'delta': state.risk.delta,

        'gamma': state.risk.gamma,

        'theta': state.risk.theta,

        'vega': state.risk.vega,

        'iv': state.risk.iv,
      });
    });
  }

  @override
  Future<void> recordDecision({
    required TradeId tradeId,

    required DecisionRecord decision,
  }) async {
    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final tradeRows = await txn.query(
        'trades',

        columns: ['status'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (tradeRows.isEmpty) {
        throw StateError('Trade does not exist: ${tradeId.value}');
      }

      if (tradeRows.single['status'] != TradeStatus.confirmed.name) {
        throw StateError(
          'A decision can only be recorded for a confirmed trade.',
        );
      }

      // Decision records are append-only history. Preserve earlier ADD, EXIT,
      // ADJUST, REDUCE and HOLD records when a new decision is recorded.

      // Adjustment episodes reference before/after snapshots restrictively.
      // Remove these learning records before deleting their snapshots.
      await txn.delete(
        'adjustment_episodes',
        where: 'trade_id = ?',
        whereArgs: [tradeId.value],
      );

      final stateRows = await txn.query(
        'position_states',

        columns: ['id'],

        where: 'id = ? AND trade_id = ?',

        whereArgs: [decision.positionStateId.value, tradeId.value],

        limit: 1,
      );

      if (stateRows.isEmpty) {
        throw StateError(
          'The referenced PositionState does not belong to this trade.',
        );
      }

      await txn.insert('decision_records', {
        'trade_id': tradeId.value,

        'position_state_id': decision.positionStateId.value,

        'recorded_at': decision.recordedAt.toIso8601String(),

        'action': decision.action.name,

        'observation': decision.observation,
      });
    });
  }

  @override
  Future<void> appendPaperExecutions({
    required TradeId tradeId,

    required List<Execution> executions,
  }) async {
    if (executions.isEmpty) {
      throw ArgumentError('At least one execution is required.');
    }

    if (executions.any((e) => e.source != ExecutionSource.manual)) {
      throw ArgumentError(
        'Position-management executions must be manual paper executions.',
      );
    }

    final ids = executions.map((e) => e.id.value).toSet();

    if (ids.length != executions.length) {
      throw ArgumentError('Execution IDs must be unique.');
    }

    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'trades',

        columns: ['mode', 'status'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (rows.isEmpty)
        throw StateError('Trade does not exist: ${tradeId.value}');

      if (rows.single['mode'] != TradeMode.paper.name ||
          rows.single['status'] != TradeStatus.confirmed.name) {
        throw StateError(
          'Only an open, confirmed paper position can be adjusted.',
        );
      }

      for (final execution in executions) {
        final duplicate = await txn.query(
          'executions',

          columns: ['id'],

          where: 'id = ?',

          whereArgs: [execution.id.value],

          limit: 1,
        );

        if (duplicate.isNotEmpty) {
          throw StateError('Execution already exists: ${execution.id.value}');
        }

        final expiry = execution.contract.expiry.value;

        await txn.insert('executions', {
          'id': execution.id.value,

          'executed_at': execution.executedAt.toIso8601String(),

          'underlying': execution.contract.underlying,

          'expiry_year': expiry.year,

          'expiry_month': expiry.month,

          'expiry_day': expiry.day,

          'strike': execution.contract.strike,

          'option_type': execution.contract.optionType.name,

          'side': execution.side.name,

          'source': execution.source.name,

          'quantity': execution.quantity,

          'price': execution.price,

          'broker_trade_id': null,

          'broker_order_id': null,

          'received_at': null,
        });

        await txn.insert('execution_assignments', {
          'execution_id': execution.id.value,

          'trade_id': tradeId.value,

          'assigned_at': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  @override
  Future<void> deleteTrade(TradeId tradeId) async {
    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'trades',

        columns: ['id'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (existing.isEmpty) {
        throw StateError('Trade does not exist: ${tradeId.value}');
      }

      final stateRows = await txn.query(
        'position_states',

        columns: ['id'],

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      );

      final stateIds = stateRows.map((row) => row['id'] as String).toList();

      // Remove decisions owned by this trade and any legacy/inconsistent rows

      // that still reference one of its states. The composite FK is restrictive,

      // so both paths must be cleared before deleting position_states.

      await txn.delete(
        'decision_records',

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      );

      for (final stateId in stateIds) {
        await txn.delete(
          'decision_records',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );
      }

      for (final stateId in stateIds) {
        // Child tables use ON DELETE RESTRICT, so explicitly remove details first.

        await txn.delete(
          'position_legs',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );

        await txn.delete(
          'market_snapshots',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );

        await txn.delete(
          'geometry_snapshots',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );

        await txn.delete(
          'economic_snapshots',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );

        await txn.delete(
          'risk_snapshots',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );

        await txn.delete(
          'position_snapshot_details',

          where: 'position_state_id = ?',

          whereArgs: [stateId],
        );
      }

      await txn.delete(
        'position_states',

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      );

      // Keep execution records globally; removing the assignment makes them

      // available for reassignment without destroying broker/audit data.

      await txn.delete(
        'execution_assignments',

        where: 'trade_id = ?',

        whereArgs: [tradeId.value],
      );

      // Some existing installations do not have the optional
      // trade_performance table (it is not part of schema version 9).
      // Only delete from it when it actually exists; otherwise a valid
      // position deletion must not fail with 'no such table'.
      final performanceTable = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        ['trade_performance'],
      );
      if (performanceTable.isNotEmpty) {
        await txn.delete(
          'trade_performance',
          where: 'trade_id = ?',
          whereArgs: [tradeId.value],
        );
      }

      // Diagnose any remaining direct foreign-key references to this trade.

      final tables = await txn.rawQuery('''

  SELECT name

  FROM sqlite_master

  WHERE type = 'table'

    AND name NOT LIKE 'sqlite_%'

''');

      final blockers = <String>[];

      for (final row in tables) {
        final table = row['name'] as String;

        final foreignKeys = await txn.rawQuery(
          'PRAGMA foreign_key_list("$table")',
        );

        for (final fk in foreignKeys) {
          if (fk['table'] != 'trades' || fk['to'] != 'id') {
            continue;
          }

          final column = fk['from'] as String;

          final rows = await txn.rawQuery(
            'SELECT COUNT(*) AS count FROM "$table" WHERE "$column" = ?',

            [tradeId.value],
          );

          final count = rows.single['count'] as int;

          if (count > 0) {
            blockers.add('$table.$column ($count rows)');
          }
        }
      }

      if (blockers.isNotEmpty) {
        throw StateError(
          'Cannot delete trade ${tradeId.value}; remaining references: '
          '${blockers.join(', ')}',
        );
      }

      await txn.delete('trades', where: 'id = ?', whereArgs: [tradeId.value]);
    });
  }

  @override
  Future<void> closeTrade({
    required TradeId tradeId,

    required DateTime closedAt,
  }) async {
    final db = await _tradingDatabase.database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'trades',

        columns: ['status'],

        where: 'id = ?',

        whereArgs: [tradeId.value],

        limit: 1,
      );

      if (rows.isEmpty) {
        throw StateError('Trade does not exist: ${tradeId.value}');
      }

      final status = rows.single['status'];

      if (status != TradeStatus.confirmed.name) {
        throw StateError(
          'Only a confirmed trade can be closed. '
          'Current status: $status',
        );
      }

      await txn.update(
        'trades',

        {
          'status': TradeStatus.closed.name,

          'closed_at': closedAt.toIso8601String(),
        },

        where: 'id = ? AND status = ?',

        whereArgs: [tradeId.value, TradeStatus.confirmed.name],
      );
    });
  }

  @override
  Future<void> saveAdjustmentEpisode(AdjustmentEpisode episode) async {
    final db = await _tradingDatabase.database;
    Map<String, Object?> viewMap(
      String prefix,
      PositionViewAssessment? view,
    ) => {
      '${prefix}view_suggested': view?.suggestedView.name,
      '${prefix}view_confirmed': view?.confirmedView.name,
      '${prefix}view_assessed_at': view?.assessedAt.toIso8601String(),
      '${prefix}view_confidence': view?.confidence,
      '${prefix}view_evidence': view == null ? null : jsonEncode(view.evidence),
      '${prefix}view_correction_note': view?.correctionNote,
    };
    final row = <String, Object?>{
      'id': episode.id,
      'trade_id': episode.tradeId,
      'before_position_state_id': episode.beforePositionStateId,
      'after_position_state_id': episode.afterPositionStateId,
      ...viewMap('before_', episode.beforeView),
      ...viewMap('after_', episode.afterView),
      'reason': episode.reason.name,
      'reason_note': episode.reasonNote,
      'selected_proposal_id': episode.selectedProposalId,
      'execution_ids': jsonEncode(episode.executionIds),
      'created_at': episode.createdAt.toIso8601String(),
      'confirmed_at': episode.confirmedAt?.toIso8601String(),
      'status': episode.status.name,
      'failure_message': episode.failureMessage,
      'decision_action': episode.decision?.action.name,
      'decision_recorded_at': episode.decision?.recordedAt.toIso8601String(),
      'decision_observation': episode.decision?.observation,
    };
    await db.insert(
      'adjustment_episodes',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<AdjustmentEpisode>> getAdjustmentEpisodes(String tradeId) async {
    final db = await _tradingDatabase.database;
    final rows = await db.query(
      'adjustment_episodes',
      where: 'trade_id = ?',
      whereArgs: [tradeId],
      orderBy: 'created_at DESC',
    );
    PositionViewAssessment parseView(Map<String, Object?> row, String prefix) {
      final suggested = row['${prefix}view_suggested'] as String?;
      final confirmed = row['${prefix}view_confirmed'] as String?;
      final assessedAt = row['${prefix}view_assessed_at'] as String?;
      if (suggested == null || confirmed == null || assessedAt == null) {
        throw StateError(
          'Stored adjustment episode is missing its required $prefix view.',
        );
      }
      final evidenceJson = row['${prefix}view_evidence'] as String? ?? '[]';
      return PositionViewAssessment(
        id: '${row['id']}:$prefix',
        tradeId: row['trade_id'] as String,
        positionStateId:
            row['${prefix == 'before_' ? 'before' : 'after'}_position_state_id']
                as String? ??
            row['before_position_state_id'] as String,
        assessedAt: DateTime.parse(assessedAt),
        suggestedView: MarketView.values.byName(suggested),
        confirmedView: MarketView.values.byName(confirmed),
        confidence: (row['${prefix}view_confidence'] as num?)?.toDouble(),
        evidence: (jsonDecode(evidenceJson) as List).cast<String>(),
        correctionNote: row['${prefix}view_correction_note'] as String?,
      );
    }

    return rows
        .map((row) {
          final reasonName = row['reason'] as String;
          final executionIds = (jsonDecode(
            row['execution_ids'] as String? ?? '[]',
          ) as List).cast<String>();
          return AdjustmentEpisode(
            id: row['id'] as String,
            tradeId: row['trade_id'] as String,
            beforePositionStateId: row['before_position_state_id'] as String,
            afterPositionStateId: row['after_position_state_id'] as String?,
            beforeView: parseView(row, 'before_'),
            afterView: row['after_view_confirmed'] == null
                ? null
                : parseView(row, 'after_'),
            reason: AdjustmentReason.values.byName(reasonName),
            reasonNote: row['reason_note'] as String?,
            selectedProposalId: row['selected_proposal_id'] as String?,
            decision:
                row['decision_action'] == null ||
                    row['decision_recorded_at'] == null
                ? null
                : DecisionRecord(
                    recordedAt: DateTime.parse(
                      row['decision_recorded_at'] as String,
                    ),
                    positionStateId: PositionStateId(
                      row['before_position_state_id'] as String,
                    ),
                    action: DecisionAction.values.byName(
                      row['decision_action'] as String,
                    ),
                    observation: row['decision_observation'] as String?,
                  ),
            executionIds: executionIds,
            createdAt: DateTime.parse(row['created_at'] as String),
            confirmedAt: row['confirmed_at'] == null
                ? null
                : DateTime.parse(row['confirmed_at'] as String),
            status: AdjustmentEpisodeStatus.values.byName(
              row['status'] as String,
            ),
            failureMessage: row['failure_message'] as String?,
          );
        })
        .toList(growable: false);
  }
}
