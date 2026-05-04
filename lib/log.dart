import 'package:flutter/foundation.dart';

class AppLog {
  static final List<String> _entries = [];
  static const int _maxEntries = 1000;
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void add(String msg) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _entries.add('$ts  $msg');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    revision.value++;
  }

  static List<String> snapshot() => List<String>.from(_entries);
  static String dump() => _entries.join('\n');
  static void clear() {
    _entries.clear();
    revision.value++;
  }
}
