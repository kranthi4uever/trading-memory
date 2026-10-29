import 'dart:math' as math;

import '../trade/trade.dart';
import '../trade/trade_status.dart';
import 'position_state/position_leg.dart';
import 'position_state/position_state.dart';

/// A comparable historical snapshot. Similarity describes context, not the
/// probability of a profitable outcome.
class SimilarPositionMatch {
  final Trade trade;
  final PositionState state;
  final double score;
  final List<PositionSimilarityFactor> factors;

  SimilarPositionMatch({
    required this.trade,
    required this.state,
    required this.score,
    required List<PositionSimilarityFactor> factors,
  }) : factors = List.unmodifiable(factors);
}

class PositionSimilarityFactor {
  final String name;
  final double? similarity;
  final double weight;
  final String explanation;

  const PositionSimilarityFactor({
    required this.name,
    required this.similarity,
    required this.weight,
    required this.explanation,
  });
}

/// Finds historical position states across closed trades. It deliberately
/// compares snapshot structure rather than the original trade strategy label.
class PositionStateSimilarityService {
  const PositionStateSimilarityService();

  List<SimilarPositionMatch> findMatches({
    required PositionState current,
    required Iterable<Trade> trades,
    int limit = 10,
    double minimumScore = 0.0,
  }) {
    if (current.position.legs.isEmpty || limit <= 0) return const [];
    final matches = <SimilarPositionMatch>[];
    for (final trade in trades) {
      if (trade.id.value == current.tradeId ||
          trade.status != TradeStatus.closed ||
          trade.executions.isEmpty ||
          trade.executions.first.contract.underlying !=
              current.position.underlying) {
        continue;
      }
      for (final historical in trade.positionStates) {
        if (historical.position.underlying != current.position.underlying ||
            historical.position.legs.isEmpty) {
          continue;
        }
        final factors = _factors(current, historical);
        var weighted = 0.0;
        var totalWeight = 0.0;
        for (final factor in factors) {
          final value = factor.similarity;
          if (value == null || factor.weight <= 0) continue;
          weighted += value.clamp(0.0, 1.0) * factor.weight;
          totalWeight += factor.weight;
        }
        if (totalWeight == 0) continue;
        final score = weighted / totalWeight;
        if (score >= minimumScore) {
          matches.add(SimilarPositionMatch(
            trade: trade,
            state: historical,
            score: score,
            factors: factors,
          ));
        }
      }
    }
    matches.sort((a, b) {
      final scoreOrder = b.score.compareTo(a.score);
      return scoreOrder != 0
          ? scoreOrder
          : b.state.capturedAt.compareTo(a.state.capturedAt);
    });
    return List.unmodifiable(matches.take(limit));
  }

  List<PositionSimilarityFactor> _factors(
    PositionState current,
    PositionState historical,
  ) {
    final result = <PositionSimilarityFactor>[];
    final a = current.position;
    final b = historical.position;
    result.add(PositionSimilarityFactor(
      name: 'Leg structure',
      weight: 35,
      similarity: _legSimilarity(current, historical),
      explanation: 'Compares option type, buy/sell direction and relative strike geometry; quantity is normalized.',
    ));
    result.add(PositionSimilarityFactor(
      name: 'Strategy label',
      weight: 5,
      similarity: a.strategy == b.strategy ? 1 : 0.5,
      explanation: a.strategy == b.strategy
          ? 'Saved snapshot strategy labels match.'
          : 'Strategy labels differ; actual legs are compared independently.',
    ));

    final currentDte = _dte(a.expiry.value, current.capturedAt);
    final historicalDte = _dte(b.expiry.value, historical.capturedAt);
    result.add(PositionSimilarityFactor(
      name: 'DTE',
      weight: 15,
      similarity: currentDte == null || historicalDte == null
          ? null
          : math.exp(-(currentDte - historicalDte).abs() / 14.0),
      explanation: currentDte == null || historicalDte == null
          ? 'DTE unavailable.'
          : 'Current $currentDte days; historical $historicalDte days.',
    ));

    result.add(PositionSimilarityFactor(
      name: 'Distance from spot',
      weight: 15,
      similarity: _spotGeometrySimilarity(current, historical),
      explanation: 'Compares each leg strike relative to its snapshot spot, scaled by ATM straddle when available.',
    ));
    result.add(PositionSimilarityFactor(
      name: 'Wing width',
      weight: 10,
      similarity: _relativeMetricSimilarity(
        current.geometry.wingWidth,
        historical.geometry.wingWidth,
      ),
      explanation: 'Compares recorded wing widths proportionally.',
    ));
    result.add(PositionSimilarityFactor(
      name: 'VIX',
      weight: 10,
      similarity: _relativeMetricSimilarity(
        current.market.vix,
        historical.market.vix,
      ),
      explanation: 'Compares recorded VIX values; missing values are ignored.',
    ));
    result.add(PositionSimilarityFactor(
      name: 'ATM straddle',
      weight: 10,
      similarity: _relativeMetricSimilarity(
        current.market.atmStraddle,
        historical.market.atmStraddle,
      ),
      explanation: 'Compares recorded ATM straddle values; missing values are ignored.',
    ));
    return result;
  }

  int? _dte(DateTime expiry, DateTime capturedAt) {
    final days = DateTime(expiry.year, expiry.month, expiry.day)
        .difference(DateTime(capturedAt.year, capturedAt.month, capturedAt.day))
        .inDays;
    return days < 0 ? null : days;
  }

  double? _legSimilarity(PositionState a, PositionState b) {
    final left = a.position.legs;
    final right = b.position.legs;
    if (left.length != right.length) return 0;
    final spotA = a.market.spot;
    final spotB = b.market.spot;
    final scaleA = _positive(a.market.atmStraddle) ??
        _positive(a.geometry.wingWidth) ?? 1.0;
    final scaleB = _positive(b.market.atmStraddle) ??
        _positive(b.geometry.wingWidth) ?? 1.0;
    final descriptorsA = left.map((leg) => _descriptor(leg, spotA, scaleA)).toList()
      ..sort();
    final descriptorsB = right.map((leg) => _descriptor(leg, spotB, scaleB)).toList()
      ..sort();
    var total = 0.0;
    for (var i = 0; i < descriptorsA.length; i++) {
      final aParts = descriptorsA[i].split('|');
      final bParts = descriptorsB[i].split('|');
      if (aParts[0] != bParts[0] || aParts[1] != bParts[1]) return 0;
      final ma = double.tryParse(aParts[2]);
      final mb = double.tryParse(bParts[2]);
      total += ma == null || mb == null
          ? 0.5
          : math.exp(-(ma - mb).abs() / 1.5);
    }
    return total / descriptorsA.length;
  }

  String _descriptor(PositionLeg leg, double? spot, double scale) {
    final moneyness = spot == null || spot == 0
        ? 'na'
        : ((leg.contract.strike - spot) / scale).toStringAsFixed(3);
    return '${leg.contract.optionType.name}|${leg.side.name}|$moneyness';
  }

  double? _spotGeometrySimilarity(PositionState a, PositionState b) {
    final spotA = a.market.spot;
    final spotB = b.market.spot;
    if (spotA == null || spotB == null || spotA <= 0 || spotB <= 0) {
      return null;
    }
    if (a.position.legs.length != b.position.legs.length) return 0;
    final scaleA = _positive(a.market.atmStraddle) ??
        _positive(a.geometry.wingWidth) ?? 1.0;
    final scaleB = _positive(b.market.atmStraddle) ??
        _positive(b.geometry.wingWidth) ?? 1.0;
    final remaining = [...b.position.legs];
    var total = 0.0;
    for (final legA in a.position.legs) {
      var bestIndex = -1;
      var bestDistance = double.infinity;
      var bestSimilarity = 0.0;
      final normalizedA = (legA.contract.strike - spotA) / scaleA;
      for (var i = 0; i < remaining.length; i++) {
        final legB = remaining[i];
        if (legA.contract.optionType != legB.contract.optionType ||
            legA.side != legB.side) continue;
        final normalizedB = (legB.contract.strike - spotB) / scaleB;
        final distance = (normalizedA - normalizedB).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = i;
          bestSimilarity = math.exp(-distance / 1.5);
        }
      }
      if (bestIndex < 0) return 0;
      remaining.removeAt(bestIndex);
      total += bestSimilarity;
    }
    return total / a.position.legs.length;
  }

  double? _relativeMetricSimilarity(double? a, double? b) {
    if (a == null || b == null || a <= 0 || b <= 0) return null;
    final ratio = math.max(a, b) / math.min(a, b);
    return math.exp(-math.log(ratio));
  }

  double? _positive(double? value) =>
      value != null && value > 0 ? value : null;
}
