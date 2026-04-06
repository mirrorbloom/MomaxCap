import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spatial_data_recorder/app/spatial_data_recorder_app.dart';
import 'package:spatial_data_recorder/features/home/home_page.dart';

void main() {
  testWidgets('App renders HomePage', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: SpatialDataRecorderApp()),
    );

    await tester.pump();
    expect(find.byType(HomePage), findsOneWidget);
  });
}
