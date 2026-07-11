import 'package:flutter_test/flutter_test.dart';

import 'package:opencfu_mobile/main.dart';

void main() {
  testWidgets('shows the OpenCFU Mobile landing page', (WidgetTester tester) async {
    await tester.pumpWidget(const OpencfuMobileApp(cameras: []));

    expect(find.text('Basic Capture'), findsOneWidget);
  });
}
