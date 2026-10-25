/// Explainable weighted similarity for historical adjustment episodes.
/// Missing values are ignored and remaining weights are renormalized; missing
/// metrics are never treated as zero. This ranks context only, not outcomes.
class SimilarityFactor {
  final String name;
  final double weight;
  final double? currentValue;
  final double? historicalValue;
  final double? similarity; // 0..1; null when not comparable.

  const SimilarityFactor({
    required this.name,
    required this.weight,
    required this.currentValue,
    required this.historicalValue,
    required this.similarity,
  });
}

class SimilarityResult {
  final String episodeId;
  final double? score;
  final List<SimilarityFactor> factors;

  SimilarityResult({required this.episodeId, required this.score, required List<SimilarityFactor> factors})
      : factors = List.unmodifiable(factors);
}

class AdjustmentSimilarityService {
  const AdjustmentSimilarityService();

  SimilarityResult score({required String episodeId, required List<SimilarityFactor> factors}) {
    var weighted = 0.0;
    var totalWeight = 0.0;
    for (final factor in factors) {
      final similarity = factor.similarity;
      if (similarity == null || factor.weight <= 0) continue;
      weighted += similarity.clamp(0.0, 1.0) * factor.weight;
      totalWeight += factor.weight;
    }
    return SimilarityResult(
      episodeId: episodeId,
      score: totalWeight == 0 ? null : weighted / totalWeight,
      factors: factors,
    );
  }
}
