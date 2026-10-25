import 'package:flutter_test/flutter_test.dart';
import 'package:trading_memory/domain/trade/trade.dart';
import 'package:trading_memory/domain/trading/trading_repository.dart';
import 'package:trading_memory/main.dart';

class _FakeTradingRepository implements TradingRepository {
  @override
  Future<List<Trade>> getTrades() async => <Trade>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Trading Memory home screen loads', (tester) async {
    await tester.pumpWidget(TradingMemoryApp(repository: _FakeTradingRepository()));
    await tester.pumpAndSettle();

    expect(find.text('Positions'), findsWidgets);
    expect(find.text('New Paper Trade'), findsOneWidget);
  });
}
