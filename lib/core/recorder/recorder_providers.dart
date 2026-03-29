import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'recorder_method_channel.dart';
import 'recorder_platform.dart';

final recorderPlatformProvider = Provider<RecorderPlatform>(
  (ref) => RecorderMethodChannel(),
);
