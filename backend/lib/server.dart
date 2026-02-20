import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
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

  final extracting = <String, Future<void>>{};

  bool hasAnyPageFile(Directory pagesDir) {
    if (!pagesDir.existsSync()) return false;
    bool isPageFile(String name) {
      final base = name.replaceFirst(RegExp(r'\..+$'), '');
      return RegExp(r'^\d+$').hasMatch(base);
    }

    try {
      for (final entity in pagesDir.listSync()) {
        if (entity is File) {
          if (isPageFile(p.basename(entity.path))) return true;
        } else if (entity is Directory) {
          for (final child in entity.listSync()) {
            if (child is File && isPageFile(p.basename(child.path)))
              return true;
          }
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  int directorySizeBytes(Directory dir) {
    var total = 0;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += entity.lengthSync();
        }
      }
    } catch (_) {
      // ignore
    }
    return total;
  }

  Future<void> ensureExtracted(String id, String zipPath) async {
    final comicDir = Directory(p.join(storage.path, 'comics', _safeId(id)));
    final pagesDir = Directory(p.join(comicDir.path, 'pages'));
    final marker = File(p.join(pagesDir.path, '.extracted'));

    if (marker.existsSync() && hasAnyPageFile(pagesDir)) return;

    Future<void> run() async {
      if (pagesDir.existsSync()) {
        try {
          pagesDir.deleteSync(recursive: true);
        } catch (_) {
          // ignore
        }
      }
      pagesDir.createSync(recursive: true);

      InputFileStream? input;
      try {
        input = InputFileStream(zipPath);
        final archive = ZipDecoder().decodeBuffer(input);
        await extractArchiveToDisk(archive, pagesDir.path);
      } finally {
        try {
          input?.close();
        } catch (_) {
          // ignore
        }
      }

      marker.createSync(recursive: true);
      marker.writeAsStringSync(DateTime.now().toIso8601String());

      try {
        File(zipPath).deleteSync();
        db.execute(
          'update comics set zip_path = null, zip_sha256 = null where id = ?',
          [id],
        );
      } catch (_) {
        // ignore
      }
    }

    final task = extracting[id];
    if (task != null) return task;

    final future = run().whenComplete(() {
      extracting.remove(id);
    });
    extracting[id] = future;
    return future;
  }

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

  api.get('/v1/comics/<id>/read', (Request req, String id) {
    final row = db
        .select('select meta_json from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});

    final metaJson = row['meta_json'] as String?;
    final meta = _tryDecodeJson(metaJson);
    if (meta is! Map) return _json(500, {'ok': false, 'error': 'invalid meta'});

    final type = int.tryParse((meta['type'] ?? '').toString()) ?? -1;

    final jsonObj = meta['json'];
    final data = jsonObj is Map
        ? Map<String, Object?>.from(jsonObj)
        : const <String, Object?>{};

    final hasEps =
        type == 0 || type == 2 || (type == 6 && data['chapters'] is Map);

    List<Map<String, Object?>>? eps;
    if (hasEps) {
      final downloaded = data['downloadedChapters'] ?? data['downloadedEps'];
      final downloadedList = downloaded is List ? downloaded : const [];

      List<String>? titles;
      final chapters = data['chapters'];
      if (chapters is List) {
        titles = chapters.map((e) => e.toString()).toList();
      } else if (chapters is Map) {
        titles = chapters.values.map((e) => e.toString()).toList();
      } else {
        final comic = data['comic'];
        if (comic is Map) {
          final epNames = comic['epNames'];
          if (epNames is List) {
            titles = epNames.map((e) => e.toString()).toList();
          }
        }
      }

      final result = <Map<String, Object?>>[];
      for (final e in downloadedList) {
        final idx = int.tryParse(e.toString());
        if (idx == null) continue;
        final epNo = idx + 1;
        final title = (titles != null && idx >= 0 && idx < titles.length)
            ? titles[idx]
            : 'EP $epNo';
        result.add({'ep': epNo, 'title': title});
      }
      result.sort((a, b) => (a['ep'] as int).compareTo(b['ep'] as int));
      eps = result;
    }

    return _json(200, {'ok': true, 'id': id, 'hasEps': hasEps, 'eps': eps});
  });

  api.get('/v1/comics/<id>/pages', (Request req, String id) async {
    final ep = int.tryParse(req.url.queryParameters['ep'] ?? '0') ?? 0;
    final row =
        db.select('select zip_path from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});

    final comicDir = Directory(p.join(storage.path, 'comics', _safeId(id)));
    final pagesRoot = Directory(p.join(comicDir.path, 'pages'));
    final pagesDir =
        ep <= 0 ? pagesRoot : Directory(p.join(pagesRoot.path, ep.toString()));

    final zipPath = row['zip_path'] as String?;
    if ((!pagesDir.existsSync() || !hasAnyPageFile(pagesRoot)) &&
        zipPath != null &&
        File(zipPath).existsSync()) {
      await ensureExtracted(id, zipPath);
    }

    if (!pagesDir.existsSync()) {
      return _json(404, {'ok': false, 'error': 'ep not found'});
    }

    final files = pagesDir
        .listSync()
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .where((name) {
      final base = name.replaceFirst(RegExp(r'\..+$'), '');
      return RegExp(r'^\d+$').hasMatch(base);
    }).toList();

    files.sort((a, b) {
      final ai = int.tryParse(a.replaceFirst(RegExp(r'\..+$'), '')) ?? 0;
      final bi = int.tryParse(b.replaceFirst(RegExp(r'\..+$'), '')) ?? 0;
      final c = ai.compareTo(bi);
      return c != 0 ? c : a.compareTo(b);
    });

    return _json(200, {'ok': true, 'ep': ep, 'pages': files});
  });

  api.get('/v1/comics/<id>/image', (Request req, String id) async {
    final ep = int.tryParse(req.url.queryParameters['ep'] ?? '0') ?? 0;
    final name = (req.url.queryParameters['name'] ?? '').trim();
    if (name.isEmpty ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('..')) {
      return _json(400, {'ok': false, 'error': 'invalid name'});
    }

    final row =
        db.select('select zip_path from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});

    final comicDir = Directory(p.join(storage.path, 'comics', _safeId(id)));
    final pagesRoot = Directory(p.join(comicDir.path, 'pages'));
    final pagesDir =
        ep <= 0 ? pagesRoot : Directory(p.join(pagesRoot.path, ep.toString()));

    final zipPath = row['zip_path'] as String?;
    if ((!pagesDir.existsSync() || !hasAnyPageFile(pagesRoot)) &&
        zipPath != null &&
        File(zipPath).existsSync()) {
      await ensureExtracted(id, zipPath);
    }

    final file = File(p.join(pagesDir.path, name));
    if (!file.existsSync())
      return _json(404, {'ok': false, 'error': 'not found'});

    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    return Response.ok(file.openRead(), headers: {'content-type': mime});
  });

  api.post('/v1/userdata', (Request req) async {
    final parts = await _readMultipart(req);
    final filePart = parts.files['file'];
    if (filePart == null) {
      return _json(400, {'ok': false, 'error': 'missing file'});
    }
    final outDir = Directory(p.join(storage.path, 'userdata'))
      ..createSync(recursive: true);
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

    final pagesDir = Directory(p.join(comicDir.path, 'pages'));
    if (pagesDir.existsSync()) {
      try {
        pagesDir.deleteSync(recursive: true);
      } catch (_) {
        // ignore
      }
    }
    pagesDir.createSync(recursive: true);

    InputFileStream? input;
    try {
      input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeBuffer(input);
      await extractArchiveToDisk(archive, pagesDir.path);
    } finally {
      try {
        input?.close();
      } catch (_) {
        // ignore
      }
      try {
        File(zipPath).deleteSync();
      } catch (_) {
        // ignore
      }
    }

    String? coverPath;
    final coverPart = parts.files['cover'];
    if (coverPart != null) {
      coverPath = p.join(comicDir.path, 'cover.jpg');
      await coverPart.saveTo(coverPath);
    } else {
      final extractedCover = File(p.join(pagesDir.path, 'cover.jpg'));
      if (extractedCover.existsSync()) {
        coverPath = extractedCover.path;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final metaJson = jsonEncode(meta);

    final sizeBytes = directorySizeBytes(pagesDir);

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
        sizeBytes,
        metaJson,
        null,
        coverPath,
        null,
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
        'coverUrl': (r['has_cover'] as int) == 1
            ? '$base/api/v1/comics/${Uri.encodeComponent(id)}/cover'
            : null,
        'zipUrl': null,
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
          'zipUrl': null,
          'meta': _tryDecodeJson(row['meta_json']),
        }
      }),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });

  api.get('/v1/comics/<id>/zip', (Request req, String id) {
    return _json(410, {'ok': false, 'error': 'zip disabled'});
  });

  api.get('/v1/comics/<id>/cover', (Request req, String id) {
    final row = db
        .select('select cover_path from comics where id = ?', [id]).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});
    final coverPath = row['cover_path'] as String?;
    if (coverPath == null)
      return _json(404, {'ok': false, 'error': 'no cover'});
    final file = File(coverPath);
    if (!file.existsSync())
      return _json(404, {'ok': false, 'error': 'file missing'});
    return Response.ok(
      file.openRead(),
      headers: {'content-type': 'application/octet-stream'},
    );
  });

  api.delete('/v1/comics/<id>', (Request req, String id) {
    final row = db.select(
        'select zip_path, cover_path from comics where id = ?',
        [id]).firstOrNull;
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
