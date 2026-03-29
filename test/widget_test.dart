import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spatial_data_recorder/app/spatial_data_recorder_app.dart';

void main() {
  testWidgets('App loads home', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: SpatialDataRecorderApp(),
      ),
    );

    expect(find.textContaining('Spatial Data Recorder'), findsWidgets);
  });
}
