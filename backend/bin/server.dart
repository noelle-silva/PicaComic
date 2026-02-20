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

  final bind = envOrDot('PICA_BIND', '0.0.0.0');
  final port = int.tryParse(envOrDot('PICA_PORT', '8080')) ?? 8080;
  final storage = envOrDot('PICA_STORAGE', './storage');
  final apiKey = Platform.environment['PICA_API_KEY'] ?? dotEnv['PICA_API_KEY'];
  final enableUserdata = envOrDot('PICA_ENABLE_USERDATA', '0').trim() == '1';

  final handler = buildHandler(
    storageDir: storage,
    apiKey: apiKey,
    enableUserdata: enableUserdata,
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
