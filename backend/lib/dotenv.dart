import 'dart:io';

/// Minimal .env loader.
///
/// - Supports `KEY=VALUE`
/// - Ignores blank lines and lines starting with `#`
/// - Trims spaces around KEY and VALUE
/// - Supports quoted values: VALUE="a b" or VALUE='a b'
Map<String, String> loadDotEnvFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return const {};

  final res = <String, String>{};
  for (final rawLine in file.readAsLinesSync()) {
    var line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) continue;

    final idx = line.indexOf('=');
    if (idx <= 0) continue;

    final key = line.substring(0, idx).trim();
    var value = line.substring(idx + 1).trim();
    if (key.isEmpty) continue;

    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    res[key] = value;
  }
  return res;
}

