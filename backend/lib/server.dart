import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

Handler buildHandler({
  required String storageDir,
  String? apiKey,
}) {
  final storage = Directory(storageDir);
  storage.createSync(recursive: true);

  final dbFile = File(p.join(storage.path, 'library.db'));
  final db = sqlite3.open(dbFile.path);
  _initDb(db);

  final api = Router();

  api.get('/v1/health', (Request req) {
    return Response.ok(
      jsonEncode({
        'ok': true,
        'time': DateTime.now().toIso8601String(),
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  api.post('/v1/userdata', (Request req) async {
    final parts = await _readMultipart(req);
    final filePart = parts.files['file'];
    if (filePart == null) {
      return _json(400, {'ok': false, 'error': 'missing file'});
    }
    final outDir = Directory(p.join(storage.path, 'userdata'))..createSync(recursive: true);
    final outPath = p.join(outDir.path, 'userdata.picadata');
    await filePart.saveTo(outPath);
    return _json(200, {'ok': true});
  });

  api.get('/v1/userdata', (Request req) {
    final file = File(p.join(storage.path, 'userdata', 'userdata.picadata'));
    if (!file.existsSync()) {
      return _json(404, {'ok': false, 'error': 'not found'});
    }
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="userdata.picadata"',
      },
    );
  });

  api.post('/v1/comics', (Request req) async {
    final parts = await _readMultipart(req);
    final metaPart = parts.fields['meta'];
    final zipPart = parts.files['zip'];
    if (metaPart == null) {
      return _json(400, {'ok': false, 'error': 'missing meta'});
    }
    if (zipPart == null) {
      return _json(400, {'ok': false, 'error': 'missing zip'});
    }

    Map<String, dynamic> meta;
    try {
      meta = jsonDecode(metaPart) as Map<String, dynamic>;
    } catch (_) {
      return _json(400, {'ok': false, 'error': 'invalid meta json'});
    }

    final id = (meta['id'] ?? '').toString();
    if (id.isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing meta.id'});
    }

    final comicDir = Directory(p.join(storage.path, 'comics', _safeId(id)));
    comicDir.createSync(recursive: true);

    final zipPath = p.join(comicDir.path, 'comic.zip');
    await zipPart.saveTo(zipPath);

    String? coverPath;
    final coverPart = parts.files['cover'];
    if (coverPart != null) {
      coverPath = p.join(comicDir.path, 'cover.jpg');
      await coverPart.saveTo(coverPath);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final metaJson = jsonEncode(meta);

    final zipSize = File(zipPath).lengthSync();
    final zipSha256 = (await sha256.bind(File(zipPath).openRead()).first).toString();

    db.execute(
      '''
      insert or replace into comics
      (id, title, subtitle, type, tags, directory, time, size, meta_json, zip_path, cover_path, zip_sha256)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        (meta['title'] ?? '').toString(),
        (meta['subtitle'] ?? '').toString(),
        int.tryParse((meta['type'] ?? '').toString()) ?? -1,
        jsonEncode(meta['tags'] ?? []),
        (meta['directory'] ?? '').toString(),
        now,
        zipSize,
        metaJson,
        zipPath,
        coverPath,
        zipSha256,
      ],
    );

    return _json(200, {'ok': true, 'id': id});
  });

  api.get('/v1/comics', (Request req) {
    final rows = db.select(
      '''
      select id, title, subtitle, type, tags, directory, time, size, zip_sha256,
             case when cover_path is null then 0 else 1 end as has_cover
      from comics
      order by time desc
      ''',
    );

    final base = _baseUrl(req);
    final list = rows.map((r) {
      final id = (r['id'] as String);
      return {
        'id': id,
        'title': r['title'],
        'subtitle': r['subtitle'],
        'type': r['type'],
        'tags': _tryDecodeJson(r['tags']) ?? [],
        'directory': r['directory'],
        'time': r['time'],
        'size': r['size'],
        'zipSha256': r['zip_sha256'],
        'coverUrl': (r['has_cover'] as int) == 1 ? '$base/api/v1/comics/${Uri.encodeComponent(id)}/cover' : null,
        'zipUrl': '$base/api/v1/comics/${Uri.encodeComponent(id)}/zip',
      };
    }).toList();

    return Response.ok(
      jsonEncode({'ok': true, 'comics': list}),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  api.get('/v1/comics/<id>', (Request req, String id) {
    final row = db.select(
      '''
      select id, title, subtitle, type, tags, directory, time, size, zip_sha256, meta_json,
             case when cover_path is null then 0 else 1 end as has_cover
      from comics
      where id = ?
      ''',
      [id],
    ).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});

    final base = _baseUrl(req);
    final coverUrl = (row['has_cover'] as int) == 1
        ? '$base/api/v1/comics/${Uri.encodeComponent(id)}/cover'
        : null;
    final zipUrl = '$base/api/v1/comics/${Uri.encodeComponent(id)}/zip';

    return Response.ok(
      jsonEncode({
        'ok': true,
        'comic': {
          'id': row['id'],
          'title': row['title'],
          'subtitle': row['subtitle'],
          'type': row['type'],
          'tags': _tryDecodeJson(row['tags']) ?? [],
          'directory': row['directory'],
          'time': row['time'],
          'size': row['size'],
          'zipSha256': row['zip_sha256'],
          'coverUrl': coverUrl,
          'zipUrl': zipUrl,
          'meta': _tryDecodeJson(row['meta_json']),
        }
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  api.get('/v1/comics/<id>/zip', (Request req, String id) {
    final row = db.select('select zip_path from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});
    final zipPath = (row['zip_path'] as String);
    final file = File(zipPath);
    if (!file.existsSync()) return _json(404, {'ok': false, 'error': 'file missing'});
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': 'application/zip',
        'content-disposition': 'attachment; filename="${_safeFileName(id)}.zip"',
      },
    );
  });

  api.get('/v1/comics/<id>/cover', (Request req, String id) {
    final row = db.select('select cover_path from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});
    final coverPath = row['cover_path'] as String?;
    if (coverPath == null) return _json(404, {'ok': false, 'error': 'no cover'});
    final file = File(coverPath);
    if (!file.existsSync()) return _json(404, {'ok': false, 'error': 'file missing'});
    return Response.ok(
      file.openRead(),
      headers: {'content-type': 'application/octet-stream'},
    );
  });

  api.delete('/v1/comics/<id>', (Request req, String id) {
    final row = db.select('select zip_path, cover_path from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});
    db.execute('delete from comics where id = ?', [id]);

    final zipPath = row['zip_path'] as String?;
    final coverPath = row['cover_path'] as String?;
    if (zipPath != null) File(zipPath).deleteSync();
    if (coverPath != null) File(coverPath).deleteSync();
    final dir = Directory(p.join(storage.path, 'comics', _safeId(id)));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    return _json(200, {'ok': true});
  });

  final root = Router()..mount('/api/', api);

  Handler handler = root.call;
  handler = _withErrorHandling(handler);
  handler = _withLogging(handler);
  if (apiKey != null && apiKey.isNotEmpty) {
    handler = _withApiKey(handler, apiKey);
  }
  return handler;
}

void _initDb(Database db) {
  db.execute('''
    create table if not exists comics (
      id text primary key,
      title text,
      subtitle text,
      type int,
      tags text,
      directory text,
      time int,
      size int,
      meta_json text,
      zip_path text,
      cover_path text,
      zip_sha256 text
    );
  ''');
}

Handler _withLogging(Handler inner) {
  return (Request req) async {
    final sw = Stopwatch()..start();
    final res = await inner(req);
    final ms = sw.elapsedMilliseconds;
    stdout.writeln(
      '${req.method} ${req.requestedUri.path} -> ${res.statusCode} (${ms}ms)',
    );
    return res;
  };
}

Handler _withApiKey(Handler inner, String apiKey) {
  return (Request req) {
    if (!req.requestedUri.path.startsWith('/api/')) {
      return inner(req);
    }
    final provided = req.headers['x-api-key'];
    if (provided == null || provided != apiKey) {
      return _json(401, {'ok': false, 'error': 'unauthorized'});
    }
    return inner(req);
  };
}

Handler _withErrorHandling(Handler inner) {
  return (Request req) async {
    try {
      return await inner(req);
    } catch (e, s) {
      stderr.writeln('Unhandled error: $e\n$s');
      return _json(500, {'ok': false, 'error': 'internal error'});
    }
  };
}

Response _json(int status, Map<String, Object?> data) {
  return Response(
    status,
    body: jsonEncode(data),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

String _baseUrl(Request req) {
  final uri = req.requestedUri;
  return '${uri.scheme}://${uri.authority}';
}

Object? _tryDecodeJson(Object? value) {
  if (value is String) {
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }
  return null;
}

String _safeId(String id) {
  return id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
}

String _safeFileName(String input) {
  final v = input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return v.isEmpty ? 'comic' : v;
}

String? _boundaryFromContentType(String? contentType) {
  if (contentType == null) return null;
  final parts = contentType.split(';').map((e) => e.trim()).toList();
  for (final part in parts) {
    if (part.toLowerCase().startsWith('boundary=')) {
      return part.substring('boundary='.length);
    }
  }
  return null;
}

class _UploadParts {
  final Map<String, String> fields;
  final Map<String, _UploadFile> files;
  _UploadParts(this.fields, this.files);
}

class _UploadFile {
  final String fieldName;
  final String? filename;
  final String? contentType;
  final File file;

  _UploadFile({
    required this.fieldName,
    required this.file,
    this.filename,
    this.contentType,
  });

  Future<void> saveTo(String outPath) async {
    final out = File(outPath);
    if (out.existsSync()) {
      out.deleteSync();
    }
    out.createSync(recursive: true);
    await file.openRead().pipe(out.openWrite());
    try {
      file.parent.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败
    }
  }
}

Future<_UploadParts> _readMultipart(Request req) async {
  final contentType = req.headers['content-type'];
  final boundary = _boundaryFromContentType(contentType);
  if (boundary == null) {
    throw StateError('missing multipart boundary');
  }

  final transformer = MimeMultipartTransformer(boundary);
  final stream = transformer.bind(req.read());

  final fields = <String, String>{};
  final files = <String, _UploadFile>{};

  await for (final part in stream) {
    final headers = part.headers;
    final disposition = headers['content-disposition'];
    if (disposition == null) continue;

    final cd = _parseContentDisposition(disposition);
    final name = cd['name'];
    if (name == null || name.isEmpty) continue;

    final filename = cd['filename'];
    if (filename == null || filename.isEmpty) {
      final value = await utf8.decodeStream(part);
      fields[name] = value;
      continue;
    }

    final tmpDir = Directory.systemTemp.createTempSync('pica_server_');
    final tmpFile = File(p.join(tmpDir.path, 'upload.bin'));
    final sink = tmpFile.openWrite();
    await part.pipe(sink);
    await sink.flush();
    await sink.close();

    files[name] = _UploadFile(
      fieldName: name,
      filename: filename,
      contentType: headers['content-type'],
      file: tmpFile,
    );
  }

  return _UploadParts(fields, files);
}

Map<String, String> _parseContentDisposition(String input) {
  final res = <String, String>{};
  final parts = input.split(';').map((e) => e.trim()).toList();
  for (final part in parts.skip(1)) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final k = part.substring(0, idx).trim().toLowerCase();
    var v = part.substring(idx + 1).trim();
    if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
      v = v.substring(1, v.length - 1);
    }
    res[k] = v;
  }
  return res;
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
