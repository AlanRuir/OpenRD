import 'package:flutter_test/flutter_test.dart';

import 'package:openrd_frontend/main.dart';

void main() {
  testWidgets('OpenRD app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenRdApp());
    expect(find.text('OpenRD 远程驾驶控制台'), findsOneWidget);
    expect(find.text('基础控制'), findsOneWidget);
  });
}
