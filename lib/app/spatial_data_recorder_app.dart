import 'package:flutter/material.dart';

import '../features/home/home_page.dart';

class SpatialDataRecorderApp extends StatelessWidget {
  const SpatialDataRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spatial Data Recorder',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
