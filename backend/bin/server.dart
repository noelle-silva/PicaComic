import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:path/path.dart' as p;

import '../lib/dotenv.dart';
import '../lib/server.dart';

Future<void> main(List<String> args) async {
  final scriptDir = p.dirname(Platform.script.toFilePath());
  final backendRoot = p.normalize(p.join(scriptDir, '..'));
  final dotEnvPath = p.join(backendRoot, '.env');
  final dotEnv = loadDotEnvFile(dotEnvPath);

  String envOrDot(String key, String fallback) =>
      Platform.environment[key] ?? dotEnv[key] ?? fallback;

  String? envOrDotNullable(String key) =>
      Platform.environment[key] ?? dotEnv[key];

  int intOr(String? input, int fallback, {int min = 0, int max = 10}) {
    final v = int.tryParse((input ?? '').trim()) ?? fallback;
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  final bind = envOrDot('PICA_BIND', '0.0.0.0');
  final port = int.tryParse(envOrDot('PICA_PORT', '8080')) ?? 8080;
  final storage = envOrDot('PICA_STORAGE', './storage');
  final apiKey = Platform.environment['PICA_API_KEY'] ?? dotEnv['PICA_API_KEY'];
  final enableUserdata = envOrDot('PICA_ENABLE_USERDATA', '0').trim() == '1';

  final fileRetriesDefault =
      intOr(envOrDotNullable('PICA_FILE_RETRIES_DEFAULT'), 2);
  final fileRetriesBySource = <String, int>{
    'picacg': intOr(envOrDotNullable('PICA_FILE_RETRIES_PICACG'), 2),
    'ehentai': intOr(envOrDotNullable('PICA_FILE_RETRIES_EHENTAI'), 1),
    'jm': intOr(envOrDotNullable('PICA_FILE_RETRIES_JM'), 2),
    'hitomi': intOr(envOrDotNullable('PICA_FILE_RETRIES_HITOMI'), 2),
    'htmanga': intOr(envOrDotNullable('PICA_FILE_RETRIES_HTMANGA'), 2),
    'nhentai': intOr(envOrDotNullable('PICA_FILE_RETRIES_NHENTAI'), 3),
  };

  final fileConcurrentDefault =
      intOr(envOrDotNullable('PICA_FILE_CONCURRENT_DEFAULT'), 6, min: 1, max: 16);
  final fileConcurrentBySource = <String, int>{};
  final picacgConcurrent = envOrDotNullable('PICA_FILE_CONCURRENT_PICACG');
  if (picacgConcurrent != null) {
    fileConcurrentBySource['picacg'] =
        intOr(picacgConcurrent, fileConcurrentDefault, min: 1, max: 16);
  }
  final ehentaiConcurrent = envOrDotNullable('PICA_FILE_CONCURRENT_EHENTAI');
  if (ehentaiConcurrent != null) {
    fileConcurrentBySource['ehentai'] =
        intOr(ehentaiConcurrent, fileConcurrentDefault, min: 1, max: 16);
  }
  final jmConcurrent = envOrDotNullable('PICA_FILE_CONCURRENT_JM');
  if (jmConcurrent != null) {
    fileConcurrentBySource['jm'] =
        intOr(jmConcurrent, fileConcurrentDefault, min: 1, max: 16);
  }
  final hitomiConcurrent = envOrDotNullable('PICA_FILE_CONCURRENT_HITOMI');
  if (hitomiConcurrent != null) {
    fileConcurrentBySource['hitomi'] =
        intOr(hitomiConcurrent, fileConcurrentDefault, min: 1, max: 16);
  }
  final htmangaConcurrent = envOrDotNullable('PICA_FILE_CONCURRENT_HTMANGA');
  if (htmangaConcurrent != null) {
    fileConcurrentBySource['htmanga'] =
        intOr(htmangaConcurrent, fileConcurrentDefault, min: 1, max: 16);
  }
  final nhentaiConcurrent = envOrDotNullable('PICA_FILE_CONCURRENT_NHENTAI');
  if (nhentaiConcurrent != null) {
    fileConcurrentBySource['nhentai'] =
        intOr(nhentaiConcurrent, fileConcurrentDefault, min: 1, max: 16);
  }

  final handler = buildHandler(
    storageDir: storage,
    apiKey: apiKey,
    enableUserdata: enableUserdata,
    fileRetriesDefault: fileRetriesDefault,
    fileRetriesBySource: fileRetriesBySource,
    fileConcurrentDefault: fileConcurrentDefault,
    fileConcurrentBySource: fileConcurrentBySource,
  );

  final server = await shelf_io.serve(handler, bind, port);
  server.autoCompress = true;
  stdout.writeln(
      'Pica Server listening on http://${server.address.host}:${server.port}');
  stdout.writeln('Storage: ${Directory(storage).absolute.path}');
  stdout.writeln(
      'Dotenv: ${File(dotEnvPath).existsSync() ? dotEnvPath : '(none)'}');
  stdout
      .writeln(apiKey == null ? 'Auth: disabled' : 'Auth: enabled (X-Api-Key)');
  stdout.writeln(enableUserdata ? 'Userdata: enabled' : 'Userdata: disabled');
}
