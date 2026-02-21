import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:image/image.dart' as img;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:sqlite3/sqlite3.dart';

const _picaServerBuild = '2026-02-21.6';

enum _TaskStopMode {
  pause,
  cancel,
}

typedef _StopCheck = _TaskStopMode? Function();

class _TaskStopped implements Exception {
  final _TaskStopMode mode;
  const _TaskStopped(this.mode);

  @override
  String toString() => switch (mode) {
        _TaskStopMode.pause => 'task paused',
        _TaskStopMode.cancel => 'task canceled',
      };
}

class _RetryPolicy {
  final int fileRetriesDefault;
  final Map<String, int> fileRetriesBySource;

  const _RetryPolicy({
    required this.fileRetriesDefault,
    required this.fileRetriesBySource,
  });

  int fileRetries(String source) {
    final v = fileRetriesBySource[source];
    if (v != null) return v.clamp(0, 10);
    return fileRetriesDefault.clamp(0, 10);
  }
}

class _ConcurrencyPolicy {
  final int fileConcurrentDefault;
  final Map<String, int> fileConcurrentBySource;

  const _ConcurrencyPolicy({
    required this.fileConcurrentDefault,
    required this.fileConcurrentBySource,
  });

  int fileConcurrent(String source) {
    final v = fileConcurrentBySource[source];
    if (v != null) return v.clamp(1, 16);
    return fileConcurrentDefault.clamp(1, 16);
  }
}

_RetryPolicy _retryPolicy = const _RetryPolicy(
  fileRetriesDefault: 2,
  fileRetriesBySource: {
    'picacg': 2,
    'ehentai': 1,
    'jm': 2,
    'hitomi': 2,
    'htmanga': 2,
    'nhentai': 3,
  },
);

_ConcurrencyPolicy _concurrencyPolicy = const _ConcurrencyPolicy(
  fileConcurrentDefault: 6,
  fileConcurrentBySource: {},
);

class _TrackedFuture {
  bool done = false;
  late final Future<void> future;

  _TrackedFuture(Future<void> f) {
    future = f.whenComplete(() => done = true);
  }
}

Future<void> _forEachConcurrent<T>(
  Iterable<T> items,
  int concurrency,
  Future<void> Function(T item) fn, {
  _StopCheck? stopCheck,
  void Function()? onError,
}) async {
  final c = concurrency.clamp(1, 16);
  final it = items.iterator;
  final inFlight = <_TrackedFuture>[];

  Object? firstErr;
  StackTrace? firstSt;

  void startOne() {
    if (firstErr != null) return;
    final stop = stopCheck?.call();
    if (stop != null) throw _TaskStopped(stop);
    if (!it.moveNext()) return;
    final item = it.current;
    final tracked = _TrackedFuture(
      () async {
        final stop2 = stopCheck?.call();
        if (stop2 != null) throw _TaskStopped(stop2);
        await fn(item);
      }(),
    );
    inFlight.add(tracked);
  }

  Future<void> waitOne() async {
    if (inFlight.isEmpty) return;
    try {
      await Future.any(inFlight.map((e) => e.future));
    } catch (e, st) {
      firstErr ??= e;
      firstSt ??= st;
      onError?.call();
    } finally {
      inFlight.removeWhere((e) => e.done);
    }
  }

  try {
    for (var i = 0; i < c; i++) {
      startOne();
    }

    while (inFlight.isNotEmpty) {
      await waitOne();
      while (firstErr == null && inFlight.length < c) {
        final before = inFlight.length;
        startOne();
        if (inFlight.length == before) break;
      }
    }
  } catch (e, st) {
    firstErr ??= e;
    firstSt ??= st;
    onError?.call();
  } finally {
    // Avoid unhandled future errors.
    if (inFlight.isNotEmpty) {
      try {
        await Future.wait(inFlight.map((e) => e.future), eagerError: false);
      } catch (_) {
        // ignore
      }
    }
  }

  if (firstErr != null) {
    Error.throwWithStackTrace(firstErr!, firstSt ?? StackTrace.current);
  }
}

Future<void> _downloadToFile(
  Uri uri,
  File outFile, {
  Map<String, String>? headers,
  Duration timeout = const Duration(minutes: 20),
  int? maxBytes,
  int retries = 0,
  _StopCheck? stopCheck,
  HttpClient? client,
}) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ArgumentError('unsupported scheme');
  }

  final parent = outFile.parent;
  if (!parent.existsSync()) {
    parent.createSync(recursive: true);
  }

  Object? lastErr;
  for (var attempt = 0; attempt <= retries; attempt++) {
    final stop = stopCheck?.call();
    if (stop != null) throw _TaskStopped(stop);

    if (outFile.existsSync()) {
      try {
        outFile.deleteSync();
      } catch (_) {
        // ignore
      }
    }

    final ownedClient = client == null;
    final http = client ?? (HttpClient()..connectionTimeout = timeout);
    try {
      final req = await http.getUrl(uri).timeout(timeout);
      req.followRedirects = true;
      req.maxRedirects = 5;
      headers?.forEach((k, v) {
        if (k.trim().isEmpty) return;
        req.headers.set(k, v);
      });

      final res = await req.close().timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        if (attempt < retries && _isRetryableStatus(res.statusCode)) {
          await Future.delayed(
            Duration(milliseconds: 400 * (1 << attempt)),
          );
          continue;
        }
        throw HttpException('bad status: ${res.statusCode}', uri: uri);
      }

      if (maxBytes != null && res.contentLength >= 0) {
        if (res.contentLength > maxBytes) {
          throw StateError('file too large');
        }
      }

      final sink = outFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in res) {
          final stop = stopCheck?.call();
          if (stop != null) throw _TaskStopped(stop);

          received += chunk.length;
          if (maxBytes != null && received > maxBytes) {
            throw StateError('file too large');
          }
          sink.add(chunk);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      return;
    } catch (e) {
      lastErr = e;
      if (e is _TaskStopped) {
        if (outFile.existsSync()) {
          try {
            outFile.deleteSync();
          } catch (_) {
            // ignore
          }
        }
        rethrow;
      }
      if (attempt >= retries) rethrow;
      if (e is ArgumentError) rethrow;
      if (e is StateError) rethrow;
      await Future.delayed(Duration(milliseconds: 400 * (1 << attempt)));
    } finally {
      if (ownedClient) {
        http.close(force: true);
      }
    }
  }
  throw lastErr ?? Exception('download failed');
}

final _secureRandom = Random.secure();

String _randomId([int bytes = 16]) {
  final data = Uint8List(bytes);
  for (var i = 0; i < data.length; i++) {
    data[i] = _secureRandom.nextInt(256);
  }
  return base64UrlEncode(data).replaceAll('=', '');
}

String _randomHex(int bytes) {
  final data = Uint8List(bytes);
  for (var i = 0; i < data.length; i++) {
    data[i] = _secureRandom.nextInt(256);
  }
  final sb = StringBuffer();
  for (final b in data) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

bool _isRetryableStatus(int code) {
  if (code == 408) return true;
  if (code == 409) return true;
  if (code == 425) return true;
  if (code == 429) return true;
  return code >= 500;
}

class _HttpRes {
  final int statusCode;
  final Uint8List body;
  final Uri uri;
  final String? contentType;

  const _HttpRes({
    required this.statusCode,
    required this.body,
    required this.uri,
    required this.contentType,
  });

  String bodyText() => utf8.decode(body, allowMalformed: true);
}

class _NoRetry implements Exception {
  final Object error;
  const _NoRetry(this.error);

  @override
  String toString() => error.toString();
}

String _snippet(String input, {int maxChars = 240}) {
  var s = input.replaceAll('\r', '').trim();
  if (s.isEmpty) return '';
  s = s.replaceAll(RegExp(r'\s+'), ' ');
  if (s.length > maxChars) s = s.substring(0, maxChars);
  return s;
}

Future<_HttpRes> _httpGetBytes(
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 20),
  int? maxBytes,
  _StopCheck? stopCheck,
  HttpClient? client,
}) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ArgumentError('unsupported scheme');
  }
  final ownedClient = client == null;
  final http = client ?? (HttpClient()..connectionTimeout = timeout);
  try {
    final stop = stopCheck?.call();
    if (stop != null) throw _TaskStopped(stop);

    final req = await http.getUrl(uri).timeout(timeout);
    req.followRedirects = true;
    req.maxRedirects = 5;
    headers?.forEach((k, v) {
      if (k.trim().isEmpty) return;
      req.headers.set(k, v);
    });

    final res = await req.close().timeout(timeout);
    final contentType = res.headers.contentType?.toString();
    if (maxBytes != null && res.contentLength >= 0) {
      if (res.contentLength > maxBytes) {
        throw StateError('body too large');
      }
    }
    final chunks = <int>[];
    var received = 0;
    await for (final chunk in res) {
      final stop = stopCheck?.call();
      if (stop != null) throw _TaskStopped(stop);

      received += chunk.length;
      if (maxBytes != null && received > maxBytes) {
        throw StateError('body too large');
      }
      chunks.addAll(chunk);
    }
    return _HttpRes(
      statusCode: res.statusCode,
      body: Uint8List.fromList(chunks),
      uri: res.redirects.isNotEmpty ? res.redirects.last.location : uri,
      contentType: contentType,
    );
  } finally {
    if (ownedClient) {
      http.close(force: true);
    }
  }
}

Future<_HttpRes> _httpGetBytesWithRetry(
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 20),
  int retries = 3,
  int? maxBytes,
  _StopCheck? stopCheck,
  HttpClient? client,
}) async {
  Object? lastErr;
  for (var i = 0; i <= retries; i++) {
    final stop = stopCheck?.call();
    if (stop != null) throw _TaskStopped(stop);

    try {
      final res = await _httpGetBytes(
        uri,
        headers: headers,
        timeout: timeout,
        maxBytes: maxBytes,
        stopCheck: stopCheck,
        client: client,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return res;
      }
      if (!_isRetryableStatus(res.statusCode) || i == retries) {
        throw HttpException('bad status: ${res.statusCode}', uri: uri);
      }
      await Future.delayed(Duration(milliseconds: 300 * (1 << i)));
    } catch (e) {
      lastErr = e;
      if (i == retries) break;
      await Future.delayed(Duration(milliseconds: 300 * (1 << i)));
    }
  }
  throw lastErr ?? Exception('request failed');
}

class _TaskCtx {
  final Database db;
  final String taskId;
  final _StopCheck stopCheck;

  int _progress = 0;
  int _total = 0;
  String? _message;
  int _lastWriteMs = 0;

  _TaskCtx(this.db, this.taskId, this.stopCheck) {
    final row = db.select(
      'select progress, total, message from tasks where id = ?',
      [taskId],
    ).firstOrNull;
    if (row != null) {
      _progress = (row['progress'] as int?) ?? 0;
      _total = (row['total'] as int?) ?? 0;
      _message = row['message'] as String?;
    }
  }

  int get progress => _progress;
  int get total => _total;

  void throwIfStopped() {
    final stop = stopCheck();
    if (stop != null) throw _TaskStopped(stop);
  }

  void setTotal(int total) {
    if (total < 0) total = 0;
    _total = total;
    _write(force: true);
  }

  void setMessage(String? message) {
    _message = message;
    _write(force: true);
  }

  void ensureProgressAtLeast(int v) {
    if (v <= _progress) return;
    _progress = v;
    _write(force: true);
  }

  void advance([int delta = 1]) {
    _progress += delta;
    if (_progress < 0) _progress = 0;
    _write();
  }

  void _write({bool force = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastWriteMs < 500) return;
    _lastWriteMs = now;
    db.execute(
      '''
      update tasks
      set progress = ?, total = ?, message = ?, updated_at = ?
      where id = ?
      ''',
      [_progress, _total, _message, now, taskId],
    );
  }
}

class _DownloadedComicData {
  final String id;
  final String title;
  final String subtitle;
  final int type;
  final List<String> tags;
  final String directory;
  final Map<String, dynamic> downloadedJson;

  const _DownloadedComicData({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.tags,
    required this.directory,
    required this.downloadedJson,
  });
}

class _TaskRunner {
  final Database db;
  final Directory storage;

  final Queue<String> _queue = Queue();
  final Set<String> _running = <String>{};
  final Map<String, _TaskStopMode> _stopByTaskId = <String, _TaskStopMode>{};

  int _maxConcurrent = 1;

  _TaskRunner({
    required this.db,
    required this.storage,
  });

  int get maxConcurrent => _maxConcurrent;

  void setMaxConcurrent(int v) {
    final next = v.clamp(1, 20);
    if (next == _maxConcurrent) return;
    _maxConcurrent = next;
    _pump();
  }

  void enqueueQueuedFromDb() {
    final rows = db.select(
      "select id from tasks where status = 'queued' order by created_at asc",
    );
    for (final r in rows) {
      final id = (r['id'] ?? '').toString();
      if (id.isEmpty) continue;
      enqueue(id);
    }
  }

  void markStaleRunningTasksFailed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      update tasks
      set status = 'failed', message = 'server restarted', updated_at = ?
      where status = 'running'
      ''',
      [now],
    );
  }

  bool _comicExists(String id) {
    final row = db
        .select('select id from comics where id = ? limit 1', [id]).firstOrNull;
    return row != null;
  }

  bool _activeTaskExists(String source, String target) {
    final row = db.select(
      '''
      select id from tasks
      where source = ? and target = ?
        and status in ('queued','running','paused')
      limit 1
      ''',
      [source, target],
    ).firstOrNull;
    return row != null;
  }

  String createDownloadTask(Map<String, dynamic> params) {
    final source = (params['source'] ?? '').toString().trim();
    final target = (params['target'] ?? '').toString().trim();
    if (source.isEmpty) throw ArgumentError('missing source');
    if (target.isEmpty) throw ArgumentError('missing target');

    final canonicalId = _canonicalComicId(source: source, target: target);
    if (canonicalId.isNotEmpty && _comicExists(canonicalId)) {
      throw StateError('already downloaded');
    }
    if (_activeTaskExists(source, target)) {
      throw StateError('task already exists');
    }

    final id = _randomId(18);
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      insert into tasks
      (id, type, source, target, params_json, status, progress, total, message, comic_id, created_at, updated_at)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        id,
        'download',
        source,
        target,
        jsonEncode(params),
        'queued',
        0,
        0,
        null,
        null,
        now,
        now,
      ],
    );
    enqueue(id);
    return id;
  }

  void enqueue(String taskId) {
    if (_running.contains(taskId)) return;
    if (_queue.contains(taskId)) return;
    _queue.add(taskId);
    _pump();
  }

  void _removeFromQueue(String taskId) {
    if (_queue.isEmpty) return;
    _queue.removeWhere((e) => e == taskId);
  }

  bool isRunning(String taskId) => _running.contains(taskId);

  _TaskStopMode? stopMode(String taskId) => _stopByTaskId[taskId];

  Directory taskTempDir(String taskId) =>
      Directory(p.join(storage.path, 'tasks', taskId));

  void _tryDeleteTaskTemp(String taskId) {
    final dir = taskTempDir(taskId);
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // ignore
    }
  }

  void pauseTask(String taskId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      update tasks
      set status = 'paused', updated_at = ?
      where id = ? and status in ('queued','running')
      ''',
      [now, taskId],
    );
    _removeFromQueue(taskId);
    if (isRunning(taskId)) {
      _stopByTaskId[taskId] = _TaskStopMode.pause;
    }
  }

  void resumeTask(String taskId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      update tasks
      set status = 'queued', updated_at = ?
      where id = ? and status in ('paused','failed')
      ''',
      [now, taskId],
    );
    _stopByTaskId.remove(taskId);
    enqueue(taskId);
  }

  void cancelTask(String taskId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      update tasks
      set status = 'canceled', message = null, updated_at = ?
      where id = ? and status in ('queued','running','paused','failed')
      ''',
      [now, taskId],
    );
    _removeFromQueue(taskId);
    if (isRunning(taskId)) {
      _stopByTaskId[taskId] = _TaskStopMode.cancel;
      return;
    }
    _tryDeleteTaskTemp(taskId);
  }

  void retryTask(String taskId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      update tasks
      set status = 'queued', message = null, updated_at = ?
      where id = ? and status in ('failed','canceled','paused')
      ''',
      [now, taskId],
    );
    _stopByTaskId.remove(taskId);
    enqueue(taskId);
  }

  bool deleteTask(String taskId) {
    if (isRunning(taskId)) return false;
    _removeFromQueue(taskId);
    db.execute('delete from tasks where id = ?', [taskId]);
    _tryDeleteTaskTemp(taskId);
    return true;
  }

  void _pump() {
    while (_running.length < _maxConcurrent && _queue.isNotEmpty) {
      final taskId = _queue.removeFirst();
      if (_running.contains(taskId)) continue;
      _running.add(taskId);
      unawaited(_run(taskId).whenComplete(() {
        _stopByTaskId.remove(taskId);
        _running.remove(taskId);
        _pump();
      }));
    }
  }

  Future<void> _run(String taskId) async {
    final row = db.select(
      '''
      select source, target, params_json
      from tasks
      where id = ?
      ''',
      [taskId],
    ).firstOrNull;
    if (row == null) return;

    final source = (row['source'] as String).trim();
    final target = (row['target'] as String).trim();
    final paramsJson = (row['params_json'] as String);

    final stopCheck = () => stopMode(taskId);
    final ctx = _TaskCtx(db, taskId, stopCheck);

    Map<String, dynamic> params;
    try {
      params = Map<String, dynamic>.from(jsonDecode(paramsJson) as Map);
    } catch (_) {
      params = {'source': source, 'target': target};
    }

    // If paused/canceled before start, do not run.
    if (stopMode(taskId) != null) return;

    final canonicalId = _canonicalComicId(source: source, target: target);
    if (canonicalId.isNotEmpty && _comicExists(canonicalId)) {
      final now0 = DateTime.now().millisecondsSinceEpoch;
      db.execute(
        '''
        update tasks
        set status = 'succeeded', message = 'already downloaded', comic_id = ?, updated_at = ?
        where id = ?
        ''',
        [canonicalId, now0, taskId],
      );
      _tryDeleteTaskTemp(taskId);
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      update tasks
      set status = 'running', message = null, updated_at = ?
      where id = ?
      ''',
      [now, taskId],
    );

    try {
      ctx.throwIfStopped();

      final workDir = taskTempDir(taskId)..createSync(recursive: true);
      final downloaded = await _downloadBySource(
        source: source,
        target: target,
        params: params,
        ctx: ctx,
        workDir: workDir,
      );

      final comicId = downloaded.id;
      final comicDir = Directory(p.join(storage.path, 'comics', _safeId(comicId)));

      if (_comicExists(comicId)) {
        final now1 = DateTime.now().millisecondsSinceEpoch;
        db.execute(
          '''
          update tasks
          set status = 'succeeded', message = 'already downloaded', comic_id = ?, updated_at = ?
          where id = ?
          ''',
          [comicId, now1, taskId],
        );
        _tryDeleteTaskTemp(taskId);
        return;
      }

      if (comicDir.existsSync()) {
        try {
          comicDir.deleteSync(recursive: true);
        } catch (_) {
          // ignore
        }
      }

      final committedDir = taskTempDir(taskId);
      if (committedDir.existsSync()) {
        committedDir.renameSync(comicDir.path);
      } else {
        comicDir.createSync(recursive: true);
      }

      final pagesDir = Directory(p.join(comicDir.path, 'pages'));
      final coverFile = File(p.join(comicDir.path, 'cover.jpg'));

      String? coverPath;
      if (coverFile.existsSync()) {
        coverPath = coverFile.path;
      } else {
        final extractedCover = File(p.join(pagesDir.path, 'cover.jpg'));
        if (extractedCover.existsSync()) coverPath = extractedCover.path;
      }

      final sizeBytes = _directorySizeBytes(pagesDir);

      final meta = <String, dynamic>{
        'id': downloaded.id,
        'title': downloaded.title,
        'subtitle': downloaded.subtitle,
        'type': downloaded.type,
        'tags': downloaded.tags,
        'directory': downloaded.directory,
        'json': downloaded.downloadedJson,
      };

      db.execute(
        '''
        insert or replace into comics
        (id, title, subtitle, type, tags, directory, time, size, meta_json, zip_path, cover_path, zip_sha256)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          downloaded.id,
          downloaded.title,
          downloaded.subtitle,
          downloaded.type,
          jsonEncode(downloaded.tags),
          downloaded.directory,
          DateTime.now().millisecondsSinceEpoch,
          sizeBytes,
          jsonEncode(meta),
          null,
          coverPath,
          null,
        ],
      );

      db.execute(
        '''
        update tasks
        set status = 'succeeded', progress = total, comic_id = ?, updated_at = ?
        where id = ?
        ''',
        [downloaded.id, DateTime.now().millisecondsSinceEpoch, taskId],
      );
    } catch (e, st) {
      if (e is _TaskStopped) {
        final now2 = DateTime.now().millisecondsSinceEpoch;
        if (e.mode == _TaskStopMode.pause) {
          db.execute(
            '''
            update tasks
            set status = 'paused', message = null, updated_at = ?
            where id = ?
            ''',
            [now2, taskId],
          );
          return;
        }
        if (e.mode == _TaskStopMode.cancel) {
          db.execute(
            '''
            update tasks
            set status = 'canceled', message = null, updated_at = ?
            where id = ?
            ''',
            [now2, taskId],
          );
          _tryDeleteTaskTemp(taskId);
          return;
        }
      }
      final debug = Platform.environment['PICA_TASK_DEBUG'] == '1';
      final stText = st.toString();
      final trimmedSt =
          stText.length > 1800 ? stText.substring(0, 1800) : stText;
      final headLine = stText.split('\n').firstOrNull?.trim() ?? '';
      final msg = debug
          ? 'download failed: $e\n$trimmedSt'
          : (headLine.isEmpty
              ? 'download failed: $e'
              : 'download failed: $e @ $headLine');
      db.execute(
        '''
        update tasks
        set status = 'failed', message = ?, updated_at = ?
        where id = ?
        ''',
        [msg, DateTime.now().millisecondsSinceEpoch, taskId],
      );
    }
  }

  int _directorySizeBytes(Directory dir) {
    var total = 0;
    try {
      if (!dir.existsSync()) return 0;
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

  Map<String, dynamic>? readAuth(String source) {
    final row = db.select(
      'select data_json from auth_sessions where source = ?',
      [source],
    ).firstOrNull;
    if (row == null) return null;
    final dataJson = (row['data_json'] as String);
    try {
      final decoded = jsonDecode(dataJson);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<_DownloadedComicData> _downloadBySource({
    required String source,
    required String target,
    required Map<String, dynamic> params,
    required _TaskCtx ctx,
    required Directory workDir,
  }) async {
    return switch (source) {
      'picacg' =>
        _downloadPicacg(workDir, readAuth('picacg'), target, params, ctx),
      'ehentai' =>
        _downloadEhentai(workDir, readAuth('ehentai'), target, params, ctx),
      'jm' => _downloadJm(workDir, readAuth('jm'), target, params, ctx),
      'hitomi' =>
        _downloadHitomi(workDir, readAuth('hitomi'), target, params, ctx),
      'htmanga' =>
        _downloadHtmanga(workDir, readAuth('htmanga'), target, params, ctx),
      'nhentai' =>
        _downloadNhentai(workDir, readAuth('nhentai'), target, params, ctx),
      _ => throw ArgumentError('unknown source'),
    };
  }
}

String _canonicalComicId({required String source, required String target}) {
  final s = source.trim();
  final t = target.trim();
  if (s.isEmpty || t.isEmpty) return '';
  switch (s) {
    case 'picacg':
      return t;
    case 'jm':
      final m = RegExp(r'\d+').firstMatch(t);
      final rawId = (m?.group(0) ?? t).trim();
      return rawId.isEmpty ? '' : 'jm$rawId';
    case 'hitomi':
      final m = RegExp(r'\d+').firstMatch(t);
      final rawId = (m?.group(0) ?? t).trim();
      return rawId.isEmpty ? '' : 'hitomi$rawId';
    case 'htmanga':
      final m = RegExp(r'\d+').firstMatch(t);
      final rawId = (m?.group(0) ?? t).trim();
      return rawId.isEmpty ? '' : 'Ht$rawId';
    case 'nhentai':
      final m = RegExp(r'\d+').firstMatch(t);
      final rawId = (m?.group(0) ?? t).trim();
      return rawId.isEmpty ? '' : 'nhentai$rawId';
    case 'ehentai':
      final i = t.indexOf('/g/');
      if (i >= 0) {
        var j = i + 3;
        var gid = '';
        while (j < t.length) {
          final ch = t[j];
          if (ch == '/') break;
          gid += ch;
          j++;
        }
        if (gid.trim().isNotEmpty) return gid.trim();
      }
      final m = RegExp(r'\d+').firstMatch(t);
      return (m?.group(0) ?? '').trim();
    default:
      return '';
  }
}

String _guessExtFromUrl(Uri uri, {String fallback = 'jpg'}) {
  final path = uri.path;
  final base = path.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return fallback;
  final ext = base.substring(dot + 1).toLowerCase();
  if (ext.length > 8) return fallback;
  if (!RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return fallback;
  return ext;
}

bool _nonEmptyFileExists(File file) {
  try {
    return file.existsSync() && file.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}

bool _pageFileExists(Directory dir, int pageNo) {
  if (!dir.existsSync()) return false;
  final prefix = '$pageNo.';
  try {
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.startsWith(prefix)) return true;
    }
  } catch (_) {
    // ignore
  }
  return false;
}

int _countDownloadedProgress(Directory comicDir) {
  var count = 0;
  if (_nonEmptyFileExists(File(p.join(comicDir.path, 'cover.jpg')))) {
    count += 1;
  }
  final pagesRoot = Directory(p.join(comicDir.path, 'pages'));
  if (!pagesRoot.existsSync()) return count;
  try {
    for (final e in pagesRoot.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final base = name.replaceFirst(RegExp(r'\..+$'), '');
      if (RegExp(r'^\d+$').hasMatch(base)) count += 1;
    }
  } catch (_) {
    // ignore
  }
  return count;
}

Future<_DownloadedComicData> _downloadPicacg(
  Directory workDir,
  Map<String, dynamic>? auth,
  String target,
  Map<String, dynamic> params,
  _TaskCtx ctx,
) async {
  final token = (auth?['token'] ?? auth?['authorization'] ?? '').toString();
  if (token.trim().isEmpty) {
    throw StateError('missing auth.token');
  }

  final apiUrl = 'https://picaapi.picacomic.com';
  const apiKey = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
  const secret =
      r'~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';

  String createSignature(
      String path, String nonce, String time, String method) {
    final key = (path + time + nonce + method + apiKey).toLowerCase();
    final hmacSha256 = Hmac(sha256, utf8.encode(secret));
    return hmacSha256.convert(utf8.encode(key)).toString();
  }

  Map<String, String> headersFor(String method, String pathWithQuery) {
    final nonce = _randomHex(16);
    final time = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final signature = createSignature(pathWithQuery, nonce, time, method);
    final appChannel = (auth?['appChannel'] ?? '3').toString().trim();
    final imageQuality =
        (auth?['imageQuality'] ?? 'original').toString().trim();
    final appUuid = (auth?['appUuid'] ?? 'defaultUuid').toString().trim();

    return {
      'api-key': apiKey,
      'accept': 'application/vnd.picacomic.com.v1+json',
      'app-channel': appChannel.isEmpty ? '3' : appChannel,
      'authorization': token,
      'time': time,
      'nonce': nonce,
      'app-version': '2.2.1.3.3.4',
      'app-uuid': appUuid.isEmpty ? 'defaultUuid' : appUuid,
      'image-quality': imageQuality.isEmpty ? 'original' : imageQuality,
      'app-platform': 'android',
      'app-build-version': '45',
      'content-type': 'application/json; charset=UTF-8',
      'user-agent': 'okhttp/3.8.1',
      'version': 'v1.4.1',
      'host': 'picaapi.picacomic.com',
      'signature': signature,
    };
  }

  final httpClient = HttpClient();
  try {
  Future<Map<String, dynamic>> getJson(String pathWithQuery) async {
    final uri = Uri.parse('$apiUrl/$pathWithQuery');
    Object? lastErr;
    for (var i = 0; i < 3; i++) {
      try {
        final res = await _httpGetBytes(
          uri,
          headers: headersFor('GET', pathWithQuery),
          timeout: const Duration(seconds: 20),
          maxBytes: 10 * 1024 * 1024,
          client: httpClient,
        );
        final body = res.bodyText();
        Object? decoded;
        try {
          decoded = jsonDecode(body);
        } catch (e) {
          final head = _snippet(body);
          throw StateError(
            head.isEmpty
                ? 'picacg api returned non-json (${res.statusCode}) @ ${res.uri}: $e'
                : 'picacg api returned non-json (${res.statusCode}) @ ${res.uri}: $head',
          );
        }
        if (decoded is! Map) throw StateError('invalid json');
        final map = Map<String, dynamic>.from(decoded);
        if (res.statusCode == 200) return map;
        final msg =
            (map['message'] ?? map['error'] ?? 'request failed').toString();
        throw StateError('picacg request failed: ${res.statusCode} $msg');
      } catch (e) {
        lastErr = e;
        await Future.delayed(Duration(milliseconds: 300 * (1 << i)));
      }
    }
    throw lastErr ?? Exception('request failed');
  }

  final id = target.trim();
  if (id.isEmpty) throw StateError('invalid target');

  ctx.setMessage('fetch comic info');
  final comicRes = await getJson('comics/$id');
  final comic =
      comicRes['data'] is Map ? (comicRes['data'] as Map)['comic'] : null;
  if (comic is! Map) throw StateError('invalid comic response');

  ctx.setMessage('fetch eps');
  Future<List<String>> getEps() async {
    final eps = <String>[];
    var page = 1;
    while (true) {
      final res = await getJson('comics/$id/eps?page=$page');
      final data = res['data'];
      if (data is! Map) break;
      final epsObj = data['eps'];
      if (epsObj is! Map) break;
      final docs = epsObj['docs'];
      if (docs is List) {
        for (final d in docs) {
          if (d is Map) eps.add((d['title'] ?? '').toString());
        }
      }
      final pages = int.tryParse((epsObj['pages'] ?? '').toString()) ?? page;
      if (pages <= page) break;
      page++;
    }
    return eps.reversed.toList();
  }

  Future<List<String>> getPages(int order) async {
    final urls = <String>[];
    var page = 1;
    while (true) {
      final res = await getJson('comics/$id/order/$order/pages?page=$page');
      final data = res['data'];
      if (data is! Map) break;
      final pagesObj = data['pages'];
      if (pagesObj is! Map) break;
      final docs = pagesObj['docs'];
      if (docs is List) {
        for (final d in docs) {
          if (d is! Map) continue;
          final media = d['media'];
          if (media is! Map) continue;
          final fs = (media['fileServer'] ?? '').toString();
          final path = (media['path'] ?? '').toString();
          if (fs.isEmpty || path.isEmpty) continue;
          urls.add('$fs/static/$path');
        }
      }
      final pages = int.tryParse((pagesObj['pages'] ?? '').toString()) ?? page;
      if (pages <= page) break;
      page++;
    }
    return urls;
  }

  final epsTitles = await getEps();
  final epsRaw = params['eps'];
  final selected = <int>[];
  if (epsRaw is List) {
    for (final e in epsRaw) {
      final v = int.tryParse(e.toString());
      if (v == null) continue;
      if (v < 0) continue;
      selected.add(v);
    }
  }
  if (selected.isEmpty && epsTitles.isNotEmpty) {
    selected.addAll(List<int>.generate(epsTitles.length, (i) => i));
  }

  final title = (comic['title'] ?? '').toString();
  final author = (comic['author'] ?? '').toString();

  String thumbUrl = '';
  final thumb = comic['thumb'];
  if (thumb is Map) {
    final fs = (thumb['fileServer'] ?? '').toString();
    final path = (thumb['path'] ?? '').toString();
    if (fs.isNotEmpty && path.isNotEmpty) {
      thumbUrl = '$fs/static/$path';
    }
  }

  final creatorRaw = comic['_creator'];
  final avatar = creatorRaw is Map ? creatorRaw['avatar'] : null;
  var avatarUrl = '';
  if (avatar is Map) {
    final fs = (avatar['fileServer'] ?? '').toString();
    final path = (avatar['path'] ?? '').toString();
    if (fs.isNotEmpty && path.isNotEmpty) {
      avatarUrl = '$fs/static/$path';
    }
  }

  final creator = <String, dynamic>{
    'id': (comic['_id'] ?? id).toString(),
    'title': (creatorRaw is Map ? creatorRaw['title'] : null) ?? 'Unknown',
    'email': '',
    'name': (creatorRaw is Map ? creatorRaw['name'] : null) ?? 'Unknown',
    'level': creatorRaw is Map ? (creatorRaw['level'] ?? 0) : 0,
    'exp': creatorRaw is Map ? (creatorRaw['exp'] ?? 0) : 0,
    'avatarUrl': avatarUrl,
    'frameUrl': null,
    'isPunched': null,
    'slogan': (creatorRaw is Map ? creatorRaw['slogan'] : null) ?? '无',
  };

  final categories = <String>[];
  final categoriesRaw = comic['categories'];
  if (categoriesRaw is List) {
    for (final c in categoriesRaw) {
      final s = c.toString().trim();
      if (s.isNotEmpty) categories.add(s);
    }
  }
  final tags = <String>[];
  final tagsRaw = comic['tags'];
  if (tagsRaw is List) {
    for (final t in tagsRaw) {
      final s = t.toString().trim();
      if (s.isNotEmpty) tags.add(s);
    }
  }

  final comicItemJson = <String, dynamic>{
    'creator': creator,
    'id': id,
    'title': title,
    'description': (comic['description'] ?? '无').toString(),
    'thumbUrl': thumbUrl,
    'author': author,
    'chineseTeam': (comic['chineseTeam'] ?? 'Unknown').toString(),
    'categories': categories,
    'tags': tags,
    'likes': int.tryParse((comic['likesCount'] ?? '0').toString()) ?? 0,
    'comments': int.tryParse((comic['commentsCount'] ?? '0').toString()) ?? 0,
    'isLiked': comic['isLiked'] == true,
    'isFavourite': comic['isFavourite'] == true,
    'epsCount': int.tryParse((comic['epsCount'] ?? '0').toString()) ?? 0,
    'time': (comic['updated_at'] ?? '').toString(),
    'pagesCount': int.tryParse((comic['pagesCount'] ?? '0').toString()) ?? 0,
  };

  final downloadedJson = <String, dynamic>{
    'comicItem': comicItemJson,
    'chapters': epsTitles,
    'size': null,
    'downloadedChapters': selected,
  };

  final comicDir = workDir..createSync(recursive: true);
  final pagesRoot = Directory(p.join(comicDir.path, 'pages'))
    ..createSync(recursive: true);

  // compute total
  var totalPages = 0;
  final epPages = <int, List<String>>{};
  ctx.setMessage('fetch pages');
  for (final idx in selected) {
    ctx.throwIfStopped();
    final order = idx + 1;
    final urls = await getPages(order);
    epPages[order] = urls;
    totalPages += urls.length;
  }
  ctx.setTotal(totalPages + (thumbUrl.isNotEmpty ? 1 : 0));
  ctx.ensureProgressAtLeast(_countDownloadedProgress(comicDir));

  final fileConcurrent = _concurrencyPolicy.fileConcurrent('picacg');
  final jobs = <Future<void> Function()>[];

  if (thumbUrl.isNotEmpty) {
    final coverFile = File(p.join(comicDir.path, 'cover.jpg'));
    if (!_nonEmptyFileExists(coverFile)) {
      jobs.add(() async {
        ctx.setMessage('download cover');
        await _downloadToFile(
          Uri.parse(thumbUrl),
          coverFile,
          timeout: const Duration(minutes: 2),
          maxBytes: 20 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('picacg'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
        ctx.advance();
      });
    }
  }

  for (final entry in epPages.entries) {
    final epNo = entry.key;
    final urls = entry.value;
    final epDir = Directory(p.join(pagesRoot.path, epNo.toString()));
    epDir.createSync(recursive: true);
    for (var i = 0; i < urls.length; i++) {
      final pageNo = i + 1;
      if (_pageFileExists(epDir, pageNo)) continue;
      final u = urls[i];
      jobs.add(() async {
        ctx.setMessage('download ep $epNo ($pageNo/${urls.length})');
        final uri = Uri.parse(u);
        final ext = _guessExtFromUrl(uri);
        await _downloadToFile(
          uri,
          File(p.join(epDir.path, '$pageNo.$ext')),
          timeout: const Duration(minutes: 5),
          maxBytes: 50 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('picacg'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
        ctx.advance();
      });
    }
  }

  var closed = false;
  void abort() {
    if (closed) return;
    closed = true;
    httpClient.close(force: true);
  }

  await _forEachConcurrent(
    jobs,
    fileConcurrent,
    (job) => job(),
    stopCheck: ctx.stopCheck,
    onError: abort,
  );

  return _DownloadedComicData(
    id: id,
    title: title.isEmpty ? id : title,
    subtitle: author,
    type: 0,
    tags: tags,
    directory: _safeId(id),
    downloadedJson: downloadedJson,
  );
  } finally {
    httpClient.close(force: true);
  }
}

Future<_DownloadedComicData> _downloadEhentai(
  Directory workDir,
  Map<String, dynamic>? auth,
  String target,
  Map<String, dynamic> params,
  _TaskCtx ctx,
) async {
  final cookie = (auth?['cookie'] ?? auth?['cookies'] ?? '').toString().trim();
  if (cookie.isEmpty) {
    throw StateError('missing auth.cookie');
  }

  Uri galleryUri;
  try {
    galleryUri = Uri.parse(target.trim());
  } catch (_) {
    throw StateError('invalid target url');
  }
  if (!galleryUri.path.contains('/g/')) {
    throw StateError('target must be a gallery link');
  }

  final headersBase = <String, String>{
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'cookie': cookie,
    'referer': '${galleryUri.scheme}://${galleryUri.authority}/',
  };

  String getGalleryId(String url) {
    final i = url.indexOf('/g/');
    if (i < 0) return '';
    var j = i + 3;
    var res = '';
    while (j < url.length) {
      final ch = url[j];
      if (ch == '/') break;
      res += ch;
      j++;
    }
    return res;
  }

  final httpClient = HttpClient();
  try {
  ctx.setMessage('fetch gallery info');
  final galleryRes = await _httpGetBytesWithRetry(
    galleryUri,
    headers: headersBase,
    timeout: const Duration(seconds: 25),
    retries: 2,
    maxBytes: 12 * 1024 * 1024,
    stopCheck: ctx.stopCheck,
    client: httpClient,
  );
  final doc = html.parse(galleryRes.bodyText());

  final title = (doc.querySelector('h1#gn')?.text ?? '').trim();
  var subTitle = (doc.querySelector('h1#gj')?.text ?? '').trim();
  if (subTitle.isEmpty) subTitle = '';
  final uploader = (doc.querySelector('div#gdn a')?.text ?? '').trim();

  var maxPage = '1';
  for (final td in doc.querySelectorAll('td.gdt2')) {
    final t = td.text;
    if (t.contains('pages')) {
      final m = RegExp(r'\d+').firstMatch(t);
      if (m != null) maxPage = m.group(0)!;
      break;
    }
  }

  final type = (doc.querySelector('.cs')?.text ?? '').trim();
  final timeText =
      (doc.querySelector('div#gdd > table > tbody > tr > td.gdt2')?.text ?? '')
          .trim();

  var coverPath = '';
  final style =
      doc.querySelector('div#gleft > div#gd1 > div')?.attributes['style'];
  if (style != null) {
    final m = RegExp(
      r'https?://([-a-zA-Z0-9.]+(/\\S*)?\\.(?:jpg|jpeg|gif|png|webp))',
    ).firstMatch(style);
    if (m != null) coverPath = m.group(0)!;
  }

  final tagsMap = <String, List<String>>{};
  for (final tr in doc.querySelectorAll('div#taglist > table > tbody > tr')) {
    if (tr.children.length < 2) continue;
    final key = tr.children[0].text.replaceAll(':', '').trim();
    final list = <String>[];
    for (final div in tr.children[1].children) {
      final a = div.querySelector('a');
      if (a == null) continue;
      final v = a.text.trim();
      if (v.isNotEmpty) list.add(v);
    }
    if (key.isNotEmpty) tagsMap[key] = list;
  }
  final tagsFlat = <String>[];
  for (final values in tagsMap.values) {
    tagsFlat.addAll(values);
  }

  // collect reader links across thumbnail pages
  final firstLinks = doc.querySelectorAll('div#gdt > a');
  final perThumbPage = firstLinks.length;
  if (perThumbPage <= 0) throw StateError('no thumbnail links');
  final totalPages = int.tryParse(maxPage) ?? 1;
  final totalThumbPages = (totalPages / perThumbPage).ceil();

  final readerLinks = <String>[];
  for (var pageno = 0; pageno < totalThumbPages; pageno++) {
    ctx.throwIfStopped();
    final u = galleryUri.replace(
      queryParameters: {
        ...galleryUri.queryParameters,
        if (pageno > 0) 'p': pageno.toString(),
      },
    );
    final res = await _httpGetBytesWithRetry(
      u,
      headers: headersBase,
      timeout: const Duration(seconds: 25),
      retries: 2,
      maxBytes: 12 * 1024 * 1024,
      stopCheck: ctx.stopCheck,
      client: httpClient,
    );
    final d = html.parse(res.bodyText());
    for (final a in d.querySelectorAll('div#gdt > a')) {
      final href = a.attributes['href'];
      if (href == null || href.trim().isEmpty) continue;
      readerLinks.add(href);
    }
  }

  final gid = getGalleryId(galleryUri.toString());
  if (gid.isEmpty) throw StateError('invalid gallery id');

  final id = gid;
  final directory = _safeId(id);

  final comicDir = workDir..createSync(recursive: true);
  final pagesDir = Directory(p.join(comicDir.path, 'pages'))
    ..createSync(recursive: true);

  ctx.setTotal((coverPath.isEmpty ? 0 : 1) + readerLinks.length);
  ctx.ensureProgressAtLeast(_countDownloadedProgress(comicDir));

  final fileConcurrent = _concurrencyPolicy.fileConcurrent('ehentai');
  final jobs = <Future<void> Function()>[];

  if (coverPath.isNotEmpty) {
    final coverFile = File(p.join(comicDir.path, 'cover.jpg'));
    if (!_nonEmptyFileExists(coverFile)) {
      jobs.add(() async {
        ctx.setMessage('download cover');
        await _downloadToFile(
          Uri.parse(coverPath),
          coverFile,
          headers: headersBase,
          timeout: const Duration(minutes: 2),
          maxBytes: 20 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('ehentai'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
        ctx.advance();
      });
    }
  }

  for (var i = 0; i < readerLinks.length; i++) {
    final idx = i + 1;
    final link = readerLinks[i];
    if (_pageFileExists(pagesDir, idx)) continue;
    jobs.add(() async {
      ctx.setMessage('fetch page $idx/${readerLinks.length}');
      final pageRes = await _httpGetBytesWithRetry(
        Uri.parse(link),
        headers: {
          ...headersBase,
          'referer': galleryUri.toString(),
        },
        timeout: const Duration(seconds: 25),
        retries: 2,
        maxBytes: 8 * 1024 * 1024,
        stopCheck: ctx.stopCheck,
        client: httpClient,
      );
      final pageDoc = html.parse(pageRes.bodyText());
      var imgUrl =
          pageDoc.querySelector('div#i3 > a > img')?.attributes['src'] ?? '';
      imgUrl = imgUrl.trim();
      if (imgUrl.isEmpty) {
        throw StateError('missing image url');
      }
      if (imgUrl.contains('509.gif')) {
        throw StateError('image limit exceeded');
      }

      ctx.setMessage('download page $idx/${readerLinks.length}');
      final uri = Uri.parse(imgUrl);
      final ext = _guessExtFromUrl(uri, fallback: 'jpg');
      await _downloadToFile(
        uri,
        File(p.join(pagesDir.path, '$idx.$ext')),
        headers: {
          ...headersBase,
          'referer': link,
        },
        timeout: const Duration(minutes: 5),
        maxBytes: 80 * 1024 * 1024,
        retries: _retryPolicy.fileRetries('ehentai'),
        stopCheck: ctx.stopCheck,
        client: httpClient,
      );
      ctx.advance();
    });
  }

  var closed = false;
  void abort() {
    if (closed) return;
    closed = true;
    httpClient.close(force: true);
  }

  await _forEachConcurrent(
    jobs,
    fileConcurrent,
    (job) => job(),
    stopCheck: ctx.stopCheck,
    onError: abort,
  );

  final galleryJson = <String, dynamic>{
    'title': title.isEmpty ? id : title,
    'subTitle': subTitle.isEmpty ? null : subTitle,
    'type': type,
    'time': timeText,
    'uploader': uploader,
    'stars': 0.0,
    'rating': null,
    'coverPath': coverPath,
    'tags': tagsMap,
    'favorite': false,
    'link': galleryUri.toString(),
    'maxPage': maxPage,
    'pageSize': perThumbPage,
    'ext': 'jpg',
    'width': 200,
    'auth': <String, String>{},
  };

  final downloadedJson = <String, dynamic>{
    'gallery': galleryJson,
    'size': null,
  };

  return _DownloadedComicData(
    id: id,
    title: galleryJson['title'] as String,
    subtitle: uploader,
    type: 1,
    tags: tagsFlat,
    directory: directory,
    downloadedJson: downloadedJson,
  );
  } finally {
    httpClient.close(force: true);
  }
}

Future<_DownloadedComicData> _downloadJm(
  Directory workDir,
  Map<String, dynamic>? auth,
  String target,
  Map<String, dynamic> params,
  _TaskCtx ctx,
) async {
  final apiBaseUrl = (auth?['apiBaseUrl'] ?? '').toString().trim();
  final imgBaseUrl = (auth?['imgBaseUrl'] ?? '').toString().trim();
  final appVersion = (auth?['appVersion'] ?? '').toString().trim();
  final scrambleId = (auth?['scrambleId'] ?? '220980').toString().trim();

  if (apiBaseUrl.isEmpty) throw StateError('missing auth.apiBaseUrl');
  if (imgBaseUrl.isEmpty) throw StateError('missing auth.imgBaseUrl');
  if (appVersion.isEmpty) throw StateError('missing auth.appVersion');

  final m = RegExp(r'\d+').firstMatch(target);
  final rawId = (m?.group(0) ?? target).trim();
  if (rawId.isEmpty) throw StateError('invalid target');

  final id = 'jm$rawId';
  final directory = _safeId(id);

  const jmAuthKey = '18comicAPPContent';
  const jmSecret = '185Hcomic3PAPP7R';
  const ua =
      'Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/138.0.0.0 Mobile Safari/537.36';
  const imgUa = 'Dalvik/2.1.0 (Linux; Android 10; K)';

  final httpClient = HttpClient();
  try {
  Map<String, String> baseHeaders(int time, {bool post = false}) {
    final token = md5.convert(utf8.encode('$time$jmAuthKey')).toString();
    return {
      'accept': '*/*',
      // Dart HttpClient does not support brotli/zstd auto-decompression.
      // Advertising them may yield compressed bodies that can't be parsed.
      'accept-encoding': 'gzip',
      'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
      'connection': 'keep-alive',
      'origin': 'https://localhost',
      'referer': 'https://localhost/',
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'cross-site',
      'x-requested-with': 'com.example.app',
      'authorization': 'Bearer',
      'sec-fetch-storage-access': 'active',
      'token': token,
      'tokenparam': '$time,$appVersion',
      'user-agent': ua,
      if (post) 'content-type': 'application/x-www-form-urlencoded',
    };
  }

  String convertData(String input, String secret) {
    final key = md5.convert(utf8.encode(secret)).toString();
    final data = base64Decode(input);
    if (data.isEmpty) return '';
    String stripTail(String s) {
      var i = s.length - 1;
      for (; i >= 0; i--) {
        final ch = s[i];
        if (ch == '}' || ch == ']') break;
      }
      return s.substring(0, i + 1);
    }
    if (data.length % 16 != 0) {
      return stripTail(utf8.decode(data, allowMalformed: true));
    }
    final cipher = ECBBlockCipher(AESEngine())
      ..init(false, KeyParameter(utf8.encode(key)));
    var offset = 0;
    final out = Uint8List(data.length);
    try {
      while (offset < data.length) {
        offset += cipher.processBlock(data, offset, out, offset);
      }
      return stripTail(utf8.decode(out, allowMalformed: true));
    } on RangeError {
      return stripTail(utf8.decode(data, allowMalformed: true));
    }
  }

  Future<Map<String, dynamic>> jmGet(String pathQuery) async {
    final uri = pathQuery.startsWith('http')
        ? Uri.parse(pathQuery)
        : Uri.parse('$apiBaseUrl$pathQuery');

    Object? lastErr;
    const retries = 2;
    for (var attempt = 0; attempt <= retries; attempt++) {
      final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      try {
        final res = await _httpGetBytes(
          uri,
          headers: baseHeaders(time),
          timeout: const Duration(seconds: 20),
          maxBytes: 12 * 1024 * 1024,
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );

        if (res.statusCode == 401) {
          final body = res.bodyText();
          Object? decoded;
          try {
            decoded = jsonDecode(body);
          } catch (_) {
            decoded = null;
          }
          final msg = decoded is Map
              ? (decoded['errorMsg'] ?? 'unauthorized').toString().trim()
              : _snippet(body);
          throw _NoRetry(
            StateError(
              msg.isEmpty ? 'unauthorized @ ${res.uri}' : 'unauthorized @ ${res.uri}: $msg',
            ),
          );
        }

        if (res.statusCode < 200 || res.statusCode >= 300) {
          final err = HttpException('bad status: ${res.statusCode}', uri: uri);
          if (!_isRetryableStatus(res.statusCode) || attempt == retries) {
            throw _NoRetry(err);
          }
          await Future.delayed(Duration(milliseconds: 300 * (1 << attempt)));
          continue;
        }

        final outerBody = res.bodyText();
        Object? outerAny;
        try {
          outerAny = jsonDecode(outerBody);
        } catch (e) {
          final head = _snippet(outerBody);
          throw StateError(
            head.isEmpty
                ? 'jm api returned non-json (${res.statusCode}) @ ${res.uri}: $e'
                : 'jm api returned non-json (${res.statusCode}) @ ${res.uri}: $head',
          );
        }
        if (outerAny is! Map) throw StateError('invalid response');
        final outer = Map<String, dynamic>.from(outerAny);

        final dataField = outer['data'];
        if (dataField is List && dataField.isEmpty) {
          throw StateError('empty data');
        }
        if (dataField is! String) {
          throw StateError('missing data');
        }

        final decoded = convertData(dataField, '$time$jmSecret');
        Object? innerAny;
        try {
          innerAny = jsonDecode(decoded);
        } catch (_) {
          final head = _snippet(decoded);
          throw StateError(
            head.isEmpty ? 'invalid data' : 'invalid data: $head',
          );
        }
        if (innerAny is! Map) throw StateError('invalid data');
        return Map<String, dynamic>.from(innerAny);
      } catch (e) {
        if (e is _NoRetry) throw e.error;
        lastErr = e;
        if (attempt == retries) break;
        await Future.delayed(Duration(milliseconds: 300 * (1 << attempt)));
      }
    }

    throw lastErr ?? Exception('request failed');
  }

  int segmentationNum(String epsId, String scrambleID, String pictureName) {
    final scramble = int.tryParse(scrambleID) ?? 0;
    final eps = int.tryParse(epsId) ?? 0;
    if (eps < scramble) return 0;
    if (eps < 268850) return 10;
    final str = '$eps$pictureName';
    final hash = md5.convert(utf8.encode(str)).toString();
    final charCode = hash.codeUnitAt(hash.length - 1);
    if (eps > 421926) {
      final remainder = charCode % 8;
      return remainder * 2 + 2;
    }
    final remainder = charCode % 10;
    return remainder * 2 + 2;
  }

  Uint8List recombineJm(Uint8List data, String epsId, String pictureName) {
    final num = segmentationNum(epsId, scrambleId, pictureName);
    if (num <= 1) return data;
    final src = img.decodeImage(data);
    if (src == null) {
      throw StateError('failed to decode image');
    }
    final blockSize = (src.height / num).floor();
    final remainder = src.height % num;
    final blocks = <({int start, int end})>[];
    for (var i = 0; i < num; i++) {
      final start = i * blockSize;
      final end = start + blockSize + (i != num - 1 ? 0 : remainder);
      blocks.add((start: start, end: end));
    }
    final dst = img.Image(width: src.width, height: src.height);
    var y = 0;
    for (var i = blocks.length - 1; i >= 0; i--) {
      final b = blocks[i];
      final h = b.end - b.start;
      for (var yy = 0; yy < h; yy++) {
        for (var x = 0; x < src.width; x++) {
          final pixel = src.getPixel(x, b.start + yy);
          dst.setPixel(x, y + yy, pixel);
        }
      }
      y += h;
    }
    return Uint8List.fromList(img.encodeJpg(dst));
  }

  ctx.setMessage('fetch comic info');
  final album = await jmGet('/album?id=$rawId');

  final author = <String>[];
  final authorRaw = album['author'];
  if (authorRaw is List) {
    for (final a in authorRaw) {
      final s = a.toString().trim();
      if (s.isNotEmpty) author.add(s);
    }
  } else if (authorRaw != null) {
    final s = authorRaw.toString().trim();
    if (s.isNotEmpty) author.add(s);
  }
  if (author.isEmpty) author.add('未知');

  final series = <int, String>{};
  final epNames = <String>[];
  final seriesRaw = album['series'];
  if (seriesRaw is List) {
    var sort = 1;
    for (final s in seriesRaw) {
      if (s is! Map) continue;
      final cid = (s['id'] ?? '').toString().trim();
      if (cid.isEmpty) continue;
      series[sort] = cid;
      var name = (s['name'] ?? '').toString();
      if (name.trim().isEmpty) {
        final sortName = (s['sort'] ?? sort).toString();
        name = '第${sortName}話';
      }
      epNames.add(name);
      sort++;
    }
  }
  if (series.isEmpty) {
    series[1] = rawId;
    epNames.add('第1章');
  }

  final tags = <String>[];
  final tagsRaw = album['tags'];
  if (tagsRaw is List) {
    for (final t in tagsRaw) {
      final s = t.toString().trim();
      if (s.isNotEmpty) tags.add(s);
    }
  }

  final works = <String>[];
  final worksRaw = album['works'];
  if (worksRaw is List) {
    for (final w in worksRaw) {
      final s = w.toString().trim();
      if (s.isNotEmpty) works.add(s);
    }
  }

  final actors = <String>[];
  final actorsRaw = album['actors'];
  if (actorsRaw is List) {
    for (final a in actorsRaw) {
      final s = a.toString().trim();
      if (s.isNotEmpty) actors.add(s);
    }
  }

  final title = (album['name'] ?? '').toString().trim();
  final description = (album['description'] ?? '').toString();

  final epsRaw = params['eps'];
  final selected = <int>[];
  if (epsRaw is List) {
    for (final e in epsRaw) {
      final v = int.tryParse(e.toString());
      if (v == null) continue;
      if (v < 0) continue;
      selected.add(v);
    }
  }
  if (selected.isEmpty) {
    selected.addAll(List<int>.generate(series.length, (i) => i));
  }

  final seriesJson = <String, String>{};
  for (final e in series.entries) {
    seriesJson[e.key.toString()] = e.value;
  }

  final jmComicJson = <String, dynamic>{
    'name': title.isEmpty ? id : title,
    'id': rawId,
    'author': author,
    'description': description,
    'likes': '',
    'views': '',
    'series': seriesJson,
    'tags': tags,
    'works': works,
    'actors': actors,
    'relatedComics': [],
    'liked': '',
    'favorite': '',
    'epNames': epNames,
  };

  final downloadedJson = <String, dynamic>{
    'comic': jmComicJson,
    'size': null,
    'downloadedChapters': selected,
  };

  final comicDir = workDir..createSync(recursive: true);
  final pagesRoot = Directory(p.join(comicDir.path, 'pages'))
    ..createSync(recursive: true);

  // cover
  final coverUrl = '$imgBaseUrl/media/albums/${rawId}_3x4.jpg';
  ctx.setMessage('download cover');
  ctx.setTotal(1);
  final coverFile = File(p.join(comicDir.path, 'cover.jpg'));
  if (!_nonEmptyFileExists(coverFile)) {
    ctx.throwIfStopped();
    await _downloadToFile(
      Uri.parse(coverUrl),
      coverFile,
      headers: {'user-agent': ua, 'referer': 'https://localhost/'},
      timeout: const Duration(minutes: 2),
      maxBytes: 20 * 1024 * 1024,
      retries: _retryPolicy.fileRetries('jm'),
      stopCheck: ctx.stopCheck,
      client: httpClient,
    );
    ctx.advance();
  }

  // pages
  final selectedKeys = series.keys.toList()..sort();
  final chaptersToDownload = <int, String>{};
  for (final k in selectedKeys) {
    if (!selected.contains(k - 1)) continue;
    final cid = series[k];
    if (cid != null) chaptersToDownload[k] = cid;
  }

  // pre-fetch image lists for total
  ctx.setMessage('fetch chapters');
  final chapterImages = <int, List<String>>{};
  var totalPages = 0;
  for (final e in chaptersToDownload.entries) {
    ctx.throwIfStopped();
    final chapterId = e.value;
    final data = await jmGet('/chapter?&id=$chapterId');
    final images = <String>[];
    final imgs = data['images'];
    if (imgs is List) {
      for (final s in imgs) {
        final name = s.toString().trim();
        if (name.isEmpty) continue;
        images.add('$imgBaseUrl/media/photos/$chapterId/$name');
      }
    }
    chapterImages[e.key] = images;
    totalPages += images.length;
  }
  ctx.setTotal(1 + totalPages);
  ctx.ensureProgressAtLeast(_countDownloadedProgress(comicDir));

  final fileConcurrent = _concurrencyPolicy.fileConcurrent('jm');
  final jobs = <Future<void> Function()>[];

  for (final entry in chapterImages.entries) {
    final epNo = entry.key;
    final chapterId = chaptersToDownload[epNo] ?? '';
    final urls = entry.value;
    final epDir = Directory(p.join(pagesRoot.path, epNo.toString()));
    epDir.createSync(recursive: true);

    for (var i = 0; i < urls.length; i++) {
      final pageNo = i + 1;
      if (_pageFileExists(epDir, pageNo)) continue;
      final u = urls[i];
      jobs.add(() async {
        ctx.setMessage('download ep $epNo ($pageNo/${urls.length})');
        final uri = Uri.parse(u);
        final imageName =
            uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
        final pictureName = imageName.contains('.')
            ? imageName.substring(0, imageName.lastIndexOf('.'))
            : imageName;
        final ext = _guessExtFromUrl(uri);

        final bytesRes = await _httpGetBytesWithRetry(
          uri,
          headers: {
            'user-agent': imgUa,
            'referer': 'https://localhost/',
            'accept':
                'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
            // Same as api: don't advertise brotli/zstd to Dart HttpClient.
            'accept-encoding': 'gzip',
            'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
            'x-requested-with': 'com.example.app',
          },
          timeout: const Duration(minutes: 2),
          retries: 2,
          maxBytes: 80 * 1024 * 1024,
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );

        Uint8List outBytes = bytesRes.body;
        String outExt = ext;
        if (ext != 'gif') {
          final debug = Platform.environment['PICA_TASK_DEBUG'] == '1';
          final ct = (bytesRes.contentType ?? '').toLowerCase();
          if (ct.isNotEmpty && !ct.startsWith('image/')) {
            final preview = debug
                ? '\n${utf8.decode(outBytes.take(300).toList(), allowMalformed: true)}'
                : '';
            throw StateError('jm image not image: $ct ($uri)$preview');
          }
          try {
            outBytes = recombineJm(outBytes, chapterId, pictureName);
          } catch (e) {
            final hex = outBytes.isEmpty
                ? ''
                : outBytes
                    .take(16)
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(' ');
            final preview = debug
                ? '\ncontent-type: ${bytesRes.contentType}\nlen: ${outBytes.length}\nhex: $hex'
                : '';
            throw StateError('jm recombine failed: $e ($uri)$preview');
          }
          outExt = 'jpg';
        }

        final outPath = p.join(epDir.path, '$pageNo.$outExt');
        final outFile = File(outPath);
        if (_pageFileExists(epDir, pageNo)) return;
        if (outFile.existsSync()) outFile.deleteSync();
        outFile.createSync(recursive: true);
        outFile.writeAsBytesSync(outBytes);
        ctx.advance();
      });
    }
  }

  var closed = false;
  void abort() {
    if (closed) return;
    closed = true;
    httpClient.close(force: true);
  }

  await _forEachConcurrent(
    jobs,
    fileConcurrent,
    (job) => job(),
    stopCheck: ctx.stopCheck,
    onError: abort,
  );

  return _DownloadedComicData(
    id: id,
    title: jmComicJson['name'] as String,
    subtitle: author.first,
    type: 2,
    tags: tags,
    directory: directory,
    downloadedJson: downloadedJson,
  );
  } finally {
    httpClient.close(force: true);
  }
}

Future<_DownloadedComicData> _downloadHitomi(
  Directory workDir,
  Map<String, dynamic>? auth,
  String target,
  Map<String, dynamic> params,
  _TaskCtx ctx,
) async {
  final baseDomain =
      (auth?['baseDomain'] ?? 'hitomi.la').toString().trim().isEmpty
          ? 'hitomi.la'
          : (auth?['baseDomain'] ?? 'hitomi.la').toString().trim();

  final m = RegExp(r'\d+').firstMatch(target);
  final rawId = (m?.group(0) ?? target).trim();
  if (rawId.isEmpty) throw StateError('invalid target');

  final id = 'hitomi$rawId';
  final directory = _safeId(id);

  final headers = <String, String>{
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'referer': 'https://hitomi.la/reader/$rawId.html',
  };

  final httpClient = HttpClient();
  try {
  Future<_HttpRes> getText(String url) {
    return _httpGetBytesWithRetry(
      Uri.parse(url),
      headers: headers,
      timeout: const Duration(seconds: 20),
      retries: 2,
      maxBytes: 12 * 1024 * 1024,
      stopCheck: ctx.stopCheck,
      client: httpClient,
    );
  }

  ctx.setMessage('fetch gallery js');
  final galleryJsRes =
      await getText('https://ltn.$baseDomain/galleries/$rawId.js');
  final js = galleryJsRes.bodyText();
  final start = js.indexOf('{');
  if (start < 0) throw StateError('invalid galleries js');
  final galleryJson = jsonDecode(js.substring(start));
  if (galleryJson is! Map) throw StateError('invalid galleries json');

  ctx.setMessage('fetch cover');
  final blockRes =
      await getText('https://ltn.$baseDomain/galleryblock/$rawId.html');
  final blockDoc = html.parse(blockRes.bodyText());
  String cover = '';
  try {
    final source = blockDoc
            .querySelector('div.dj-img1 > picture > source')
            ?.attributes['data-srcset'] ??
        blockDoc
            .querySelector('div.cg-img1 > picture > source')
            ?.attributes['data-srcset'] ??
        '';
    if (source.isNotEmpty) {
      var v = source;
      if (v.startsWith('//')) v = v.substring(2);
      v = v.substring(v.indexOf('/'));
      cover = 'https://atn.$baseDomain$v';
      cover = cover.replaceAll(RegExp(r'2x.*'), '').trim();
      cover = cover.replaceFirst('avifbigtn', 'webpbigtn');
      cover = cover.replaceFirst('.avif', '.webp');
    }
  } catch (_) {
    cover = '';
  }

  final title = (galleryJson['title'] ?? '').toString().trim();
  final type = (galleryJson['type'] ?? '').toString().trim();
  final lang = (galleryJson['language'] ?? '').toString().trim();
  final time = (galleryJson['date'] ?? '').toString().trim();

  final artists = <String>[];
  final artistsRaw = galleryJson['artists'];
  if (artistsRaw is List) {
    for (final a in artistsRaw) {
      if (a is Map && a['artist'] != null) {
        artists.add(a['artist'].toString());
      } else {
        final s = a.toString().trim();
        if (s.isNotEmpty) artists.add(s);
      }
    }
  }

  final files = <Map<String, dynamic>>[];
  final filesRaw = galleryJson['files'];
  if (filesRaw is List) {
    for (final f in filesRaw) {
      if (f is! Map) continue;
      files.add({
        'name': (f['name'] ?? '').toString(),
        'hash': (f['hash'] ?? '').toString(),
        'hasWebp': (f['haswebp'] == 1) || (f['haswebp'] == true),
        'hasAvif': (f['hasavif'] == 1) || (f['hasavif'] == true),
        'height': int.tryParse((f['height'] ?? '').toString()) ?? 0,
        'width': int.tryParse((f['width'] ?? '').toString()) ?? 0,
        'galleryId': rawId,
      });
    }
  }

  // GG.js parsing + url builder (ported from app)
  var ggCacheTime = DateTime.fromMillisecondsSinceEpoch(0);
  String? ggB;
  var ggNumbers = <String>[];
  var ggInitialG = 1;

  int mm(int g) {
    if (ggNumbers.contains(g.toString())) {
      return ~ggInitialG & 1;
    }
    return ggInitialG;
  }

  String s(String h) {
    final match = RegExp(r'(..)(.)$').firstMatch(h);
    if (match == null) return '';
    final g = int.parse(match.group(2)! + match.group(1)!, radix: 16);
    return g.toString();
  }

  Future<void> ensureGg() async {
    final now = DateTime.now();
    if (now.difference(ggCacheTime).inMinutes < 1 &&
        ggB != null &&
        ggNumbers.isNotEmpty) {
      return;
    }
    final res = await getText(
      'https://ltn.$baseDomain/gg.js?_=${DateTime.now().millisecondsSinceEpoch}',
    );
    final text = res.bodyText();
    final nums = RegExp(r'(?<=case )\d+').allMatches(text);
    ggNumbers = nums.map((m) => m.group(0)!).toList();
    ggB = RegExp(r"(?<=b: ')\d+").firstMatch(text)?.group(0);
    ggInitialG = int.tryParse(
            RegExp(r'(?<=var o = )\d+').firstMatch(text)?.group(0) ?? '1') ??
        1;
    ggCacheTime = now;
  }

  String subdomainFromUrl(String url, String? base) {
    var retval = base ?? 'b';
    final m = RegExp(r'/[0-9a-f]{61}([0-9a-f]{2})([0-9a-f])').firstMatch(url);
    if (m == null) return 'a';
    final g = int.parse(m[2]! + m[1]!, radix: 16);
    final ch = String.fromCharCode(97 + mm(g));
    if (retval == 'tn') return '$ch$retval';
    if (retval == 'w') {
      if (ch == 'a') return '${retval}1';
      if (ch == 'b') return '${retval}2';
    }
    return retval;
  }

  String realFullPathFromHash(String hash) {
    final m = RegExp(r'^.*(..)(.)$').firstMatch(hash);
    if (m == null) return hash;
    return '${m.group(2)}/${m.group(1)}/$hash';
  }

  String fullPathFromHash(String hash) {
    return '${ggB ?? '0'}/${s(hash)}/$hash';
  }

  String urlFromUrl(String url, String? base) {
    return url.replaceFirst(
        'https://', 'https://${subdomainFromUrl(url, base)}.');
  }

  String urlFromHash(Map<String, dynamic> file, String? dir, String? ext) {
    final name = (file['name'] ?? '').toString();
    final hash = (file['hash'] ?? '').toString();
    ext ??= dir ??= (name.contains('.') ? name.split('.').last : 'jpg');
    dir ??= 'images';
    if (dir.contains('small')) {
      final u = 'https://$baseDomain/$dir/${realFullPathFromHash(hash)}.$ext';
      return urlFromUrl(u, 'tn');
    }
    final u = 'https://$baseDomain/${fullPathFromHash(hash)}.$ext';
    return urlFromUrl(u, 'w');
  }

  final comicDir = workDir..createSync(recursive: true);
  final pagesDir = Directory(p.join(comicDir.path, 'pages'))
    ..createSync(recursive: true);

  final total = (cover.isEmpty ? 0 : 1) + files.length;
  ctx.setTotal(total);
  ctx.ensureProgressAtLeast(_countDownloadedProgress(comicDir));

  if (cover.isNotEmpty) {
    ctx.setMessage('download cover');
    final coverFile = File(p.join(comicDir.path, 'cover.jpg'));
    if (!_nonEmptyFileExists(coverFile)) {
      ctx.throwIfStopped();
      await _downloadToFile(
        Uri.parse(cover),
        coverFile,
        headers: headers,
        timeout: const Duration(minutes: 2),
        maxBytes: 20 * 1024 * 1024,
        retries: _retryPolicy.fileRetries('hitomi'),
        stopCheck: ctx.stopCheck,
        client: httpClient,
      );
      ctx.advance();
    }
  }

  ctx.throwIfStopped();
  await ensureGg();

  final fileConcurrent = _concurrencyPolicy.fileConcurrent('hitomi');
  final jobs = <Future<void> Function()>[];

  for (var i = 0; i < files.length; i++) {
    final idx = i + 1;
    if (_pageFileExists(pagesDir, idx)) continue;
    final f = files[i];
    jobs.add(() async {
      ctx.setMessage('download pages ($idx/${files.length})');
      final uriWebp = Uri.parse(urlFromHash(f, 'webp', null));
      String ext = 'webp';
      try {
        await _downloadToFile(
          uriWebp,
          File(p.join(pagesDir.path, '$idx.$ext')),
          headers: headers,
          timeout: const Duration(minutes: 5),
          maxBytes: 50 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('hitomi'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
      } catch (_) {
        ctx.throwIfStopped();
        final name = (f['name'] ?? '').toString();
        ext = name.contains('.') ? name.split('.').last : 'jpg';
        final uri2 = Uri.parse(urlFromHash(f, null, null));
        await _downloadToFile(
          uri2,
          File(p.join(pagesDir.path, '$idx.$ext')),
          headers: headers,
          timeout: const Duration(minutes: 5),
          maxBytes: 50 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('hitomi'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
      }
      ctx.advance();
    });
  }

  var closed = false;
  void abort() {
    if (closed) return;
    closed = true;
    httpClient.close(force: true);
  }

  await _forEachConcurrent(
    jobs,
    fileConcurrent,
    (job) => job(),
    stopCheck: ctx.stopCheck,
    onError: abort,
  );

  final hitomiComicMap = <String, dynamic>{
    'id': rawId,
    'name': title.isEmpty ? id : title,
    'type': type,
    'artists': artists.isEmpty ? ['N/A'] : artists,
    'lang': lang,
    'time': time,
    'files': files,
  };

  final downloadedJson = <String, dynamic>{
    'comic': hitomiComicMap,
    'size': null,
    'link': 'https://hitomi.la/reader/$rawId.html',
    'cover': cover,
  };

  return _DownloadedComicData(
    id: id,
    title: hitomiComicMap['name'] as String,
    subtitle: artists.isEmpty ? 'N/A' : artists.first,
    type: 3,
    tags: const [],
    directory: directory,
    downloadedJson: downloadedJson,
  );
  } finally {
    httpClient.close(force: true);
  }
}

Future<_DownloadedComicData> _downloadHtmanga(
  Directory workDir,
  Map<String, dynamic>? auth,
  String target,
  Map<String, dynamic> params,
  _TaskCtx ctx,
) async {
  final baseUrlRaw = (auth?['baseUrl'] ?? '').toString().trim();
  final baseUrl = baseUrlRaw.replaceFirst(RegExp(r'/+$'), '');
  if (baseUrl.isEmpty) {
    throw StateError('missing auth.baseUrl');
  }
  final cookie = (auth?['cookie'] ?? auth?['cookies'] ?? '').toString().trim();

  final m = RegExp(r'\d+').firstMatch(target);
  final rawId = (m?.group(0) ?? target).trim();
  if (rawId.isEmpty) throw StateError('invalid target');

  final id = 'Ht$rawId';
  final directory = _safeId(id);

  final headers = <String, String>{
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    if (cookie.isNotEmpty) 'cookie': cookie,
  };

  String normalizeUrl(String input) {
    var v = input.trim();
    if (v.isEmpty) return '';
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    if (v.startsWith('//')) {
      v = v.replaceFirst(RegExp(r'^/+'), '');
      return 'https://$v';
    }
    if (v.startsWith('/')) return '$baseUrl$v';
    return '$baseUrl/$v';
  }

  final httpClient = HttpClient();
  try {
  ctx.setMessage('fetch comic info');
  final infoUrl = Uri.parse('$baseUrl/photos-index-page-1-aid-$rawId.html');
  final infoRes = await _httpGetBytesWithRetry(
    infoUrl,
    headers: headers,
    timeout: const Duration(seconds: 20),
    retries: 2,
    maxBytes: 6 * 1024 * 1024,
    stopCheck: ctx.stopCheck,
    client: httpClient,
  );
  final doc = html.parse(infoRes.bodyText());

  final name = (doc.querySelector('div.userwrap > h2')?.text ?? '').trim();
  final coverSrc = doc
      .querySelector('div.userwrap > div.asTB > div.asTBcell.uwthumb > img')
      ?.attributes['src'];
  final coverUrl = coverSrc == null ? '' : normalizeUrl(coverSrc);

  final labels = doc.querySelectorAll('div.asTBcell.uwconn > label');
  final category =
      labels.isNotEmpty ? labels[0].text.split('：').last.trim() : '';
  final pagesText = labels.length > 1 ? labels[1].text.split('：').last : '';
  final pages =
      int.tryParse(RegExp(r'\d+').firstMatch(pagesText)?.group(0) ?? '0') ?? 0;

  final tagsDom = doc.querySelectorAll('a.tagshow');
  final tagsMap = <String, String>{};
  for (final t in tagsDom) {
    final text = t.text.trim();
    final link = (t.attributes['href'] ?? '').trim();
    if (text.isEmpty) continue;
    tagsMap[text] = link;
  }

  final description =
      (doc.querySelector('div.asTBcell.uwconn > p')?.text ?? '').trim();
  final uploader =
      (doc.querySelector('div.asTBcell.uwuinfo > a > p')?.text ?? '').trim();

  var avatar =
      (doc.querySelector('div.asTBcell.uwuinfo > a > img')?.attributes['src'] ??
              '')
          .trim();
  avatar = normalizeUrl(avatar);

  final uploadNumText =
      (doc.querySelector('div.asTBcell.uwuinfo > p > font')?.text ?? '0');
  final uploadNum = int.tryParse(uploadNumText.trim()) ?? 0;

  ctx.setMessage('fetch images');
  final galleryUrl = Uri.parse('$baseUrl/photos-gallery-aid-$rawId.html');
  final galleryRes = await _httpGetBytesWithRetry(
    galleryUrl,
    headers: headers,
    timeout: const Duration(seconds: 20),
    retries: 2,
    maxBytes: 20 * 1024 * 1024,
    stopCheck: ctx.stopCheck,
    client: httpClient,
  );
  final matches =
      RegExp(r'(?<=//)[\w./\[\]()-]+').allMatches(galleryRes.bodyText());
  final imageUrls = <String>[];
  for (final m in matches) {
    final u = m.group(0);
    if (u == null || u.trim().isEmpty) continue;
    final cleaned = u.trim().replaceFirst(RegExp(r'^/+'), '');
    final lower = cleaned.toLowerCase();
    if (!(lower.contains('/data/') || lower.contains('wnimg'))) continue;
    if (lower.endsWith('.js') || lower.endsWith('.css')) continue;
    imageUrls.add('https://$cleaned');
  }

  final comicDir = workDir..createSync(recursive: true);
  final pagesDir = Directory(p.join(comicDir.path, 'pages'))
    ..createSync(recursive: true);

  final total = (coverUrl.isEmpty ? 0 : 1) + imageUrls.length;
  ctx.setTotal(total);
  ctx.ensureProgressAtLeast(_countDownloadedProgress(comicDir));

  final fileConcurrent = _concurrencyPolicy.fileConcurrent('htmanga');
  final jobs = <Future<void> Function()>[];

  if (coverUrl.isNotEmpty) {
    final coverFile = File(p.join(comicDir.path, 'cover.jpg'));
    if (!_nonEmptyFileExists(coverFile)) {
      jobs.add(() async {
        ctx.setMessage('download cover');
        await _downloadToFile(
          Uri.parse(coverUrl),
          coverFile,
          headers: headers,
          timeout: const Duration(minutes: 2),
          maxBytes: 20 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('htmanga'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
        ctx.advance();
      });
    }
  }

  for (var i = 0; i < imageUrls.length; i++) {
    final idx = i + 1;
    if (_pageFileExists(pagesDir, idx)) continue;
    final u = imageUrls[i];
    jobs.add(() async {
      ctx.setMessage('download pages ($idx/${imageUrls.length})');
      final uri = Uri.parse(u);
      final ext = _guessExtFromUrl(uri);
      final outPath = p.join(pagesDir.path, '$idx.$ext');
      await _downloadToFile(
        uri,
        File(outPath),
        headers: headers,
        timeout: const Duration(minutes: 5),
        maxBytes: 50 * 1024 * 1024,
        retries: _retryPolicy.fileRetries('htmanga'),
        stopCheck: ctx.stopCheck,
        client: httpClient,
      );
      ctx.advance();
    });
  }

  var closed = false;
  void abort() {
    if (closed) return;
    closed = true;
    httpClient.close(force: true);
  }

  await _forEachConcurrent(
    jobs,
    fileConcurrent,
    (job) => job(),
    stopCheck: ctx.stopCheck,
    onError: abort,
  );

  final comicJson = <String, dynamic>{
    'id': rawId,
    'coverPath': coverUrl,
    'name': name.isEmpty ? id : name,
    'category': category,
    'pages': pages,
    'tags': tagsMap,
    'description': description,
    'uploader': uploader,
    'avatar': avatar,
    'uploadNum': uploadNum,
  };

  final downloadedJson = <String, dynamic>{
    'comic': comicJson,
    'size': null,
  };

  return _DownloadedComicData(
    id: id,
    title: (comicJson['name'] ?? '').toString(),
    subtitle: uploader,
    type: 4,
    tags: tagsMap.keys.toList(),
    directory: directory,
    downloadedJson: downloadedJson,
  );
  } finally {
    httpClient.close(force: true);
  }
}

Future<_DownloadedComicData> _downloadNhentai(
  Directory workDir,
  Map<String, dynamic>? auth,
  String target,
  Map<String, dynamic> params,
  _TaskCtx ctx,
) async {
  final baseUrl =
      (auth?['baseUrl'] ?? 'https://nhentai.net').toString().trim().replaceFirst(
            RegExp(r'/+$'),
            '',
          );
  final m = RegExp(r'\d+').firstMatch(target);
  final rawId = (m?.group(0) ?? target).trim();
  if (rawId.isEmpty) throw StateError('invalid target');

  final id = 'nhentai$rawId';
  final directory = _safeId(id);

  final cookie = (auth?['cookie'] ?? auth?['cookies'] ?? '').toString().trim();
  final headers = <String, String>{
    'user-agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'referer': '$baseUrl/',
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
    'accept-encoding': 'gzip',
    if (cookie.isNotEmpty) 'cookie': cookie,
  };

  final httpClient = HttpClient();
  try {
  ctx.setMessage('fetch comic info');
  ctx.throwIfStopped();
  final apiRes = await _httpGetBytesWithRetry(
    Uri.parse('$baseUrl/api/gallery/$rawId'),
    headers: headers,
    timeout: const Duration(seconds: 20),
    retries: 2,
    maxBytes: 3 * 1024 * 1024,
    stopCheck: ctx.stopCheck,
    client: httpClient,
  );

  Object? decoded;
  final body = apiRes.bodyText();
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    final head = _snippet(body);
    throw StateError(
      head.isEmpty
          ? 'nhentai api returned non-json (${apiRes.statusCode}) @ ${apiRes.uri}: $e'
          : 'nhentai api returned non-json (${apiRes.statusCode}) @ ${apiRes.uri}: $head',
    );
  }
  if (decoded is! Map) throw StateError('invalid nhentai api response');
  final galleryData = Map<String, dynamic>.from(decoded);

  final mediaId = (galleryData['media_id'] ?? '').toString().trim();
  if (mediaId.isEmpty) throw StateError('missing media_id');

  final titleObj = galleryData['title'];
  final title = titleObj is Map
      ? (titleObj['pretty'] ??
              titleObj['english'] ??
              titleObj['japanese'] ??
              '')
          .toString()
          .trim()
      : '';

  final tags = <String>[];
  final tagsRaw = galleryData['tags'];
  if (tagsRaw is List) {
    for (final t in tagsRaw) {
      if (t is! Map) continue;
      final name = (t['name'] ?? '').toString().trim();
      if (name.isNotEmpty) tags.add(name);
    }
  }

  final images = galleryData['images'];
  final pages = images is Map ? images['pages'] : null;
  if (pages is! List) throw StateError('missing images.pages');

  String extFromType(String t, {String fallback = 'jpg'}) {
    return switch (t) {
      'j' => 'jpg',
      'p' => 'png',
      'g' => 'gif',
      'w' => 'webp',
      _ => fallback,
    };
  }

  String cover = '';
  try {
    final coverObj = images is Map ? images['cover'] : null;
    final t = coverObj is Map ? (coverObj['t'] ?? '').toString() : '';
    final ext = extFromType(t, fallback: 'jpg');
    cover = 'https://t.nhentai.net/galleries/$mediaId/cover.$ext';
  } catch (_) {
    cover = '';
  }

  final imageUrls = <String>[];
  for (final raw in pages) {
    if (raw is! Map) continue;
    final t = (raw['t'] ?? '').toString();
    final extension = extFromType(t, fallback: 'jpg');
    final n = imageUrls.length + 1;
    imageUrls.add('https://i.nhentai.net/galleries/$mediaId/$n.$extension');
  }

  final comicDir = workDir..createSync(recursive: true);
  final pagesDir = Directory(p.join(comicDir.path, 'pages'))
    ..createSync(recursive: true);

  final total = (cover.isEmpty ? 0 : 1) + imageUrls.length;
  ctx.setTotal(total);
  ctx.ensureProgressAtLeast(_countDownloadedProgress(comicDir));

  final fileConcurrent = _concurrencyPolicy.fileConcurrent('nhentai');
  final jobs = <Future<void> Function()>[];

  if (cover.isNotEmpty) {
    final coverFile = File(p.join(comicDir.path, 'cover.jpg'));
    if (!_nonEmptyFileExists(coverFile)) {
      jobs.add(() async {
        ctx.setMessage('download cover');
        await _downloadToFile(
          Uri.parse(cover),
          coverFile,
          headers: headers,
          timeout: const Duration(minutes: 2),
          maxBytes: 20 * 1024 * 1024,
          retries: _retryPolicy.fileRetries('nhentai'),
          stopCheck: ctx.stopCheck,
          client: httpClient,
        );
        ctx.advance();
      });
    }
  }

  for (var i = 0; i < imageUrls.length; i++) {
    final idx = i + 1;
    if (_pageFileExists(pagesDir, idx)) continue;
    final u = imageUrls[i];
    jobs.add(() async {
      ctx.setMessage('download pages ($idx/${imageUrls.length})');
      final uri = Uri.parse(u);
      final ext = _guessExtFromUrl(uri);
      await _downloadToFile(
        uri,
        File(p.join(pagesDir.path, '$idx.$ext')),
        headers: headers,
        timeout: const Duration(minutes: 5),
        maxBytes: 50 * 1024 * 1024,
        retries: _retryPolicy.fileRetries('nhentai'),
        stopCheck: ctx.stopCheck,
        client: httpClient,
      );
      ctx.advance();
    });
  }

  var closed = false;
  void abort() {
    if (closed) return;
    closed = true;
    httpClient.close(force: true);
  }

  await _forEachConcurrent(
    jobs,
    fileConcurrent,
    (job) => job(),
    stopCheck: ctx.stopCheck,
    onError: abort,
  );

  final downloadedJson = <String, dynamic>{
    'comicID': id,
    'title': title.isEmpty ? id : title,
    'size': null,
    'cover': cover,
    'tags': tags,
  };

  return _DownloadedComicData(
    id: id,
    title: downloadedJson['title'] as String,
    subtitle: '',
    type: 5,
    tags: tags,
    directory: directory,
    downloadedJson: downloadedJson,
  );
  } finally {
    httpClient.close(force: true);
  }
}

Handler buildHandler({
  required String storageDir,
  String? apiKey,
  bool enableUserdata = false,
  int fileRetriesDefault = 2,
  Map<String, int> fileRetriesBySource = const {},
  int fileConcurrentDefault = 6,
  Map<String, int> fileConcurrentBySource = const {},
}) {
  _retryPolicy = _RetryPolicy(
    fileRetriesDefault: fileRetriesDefault,
    fileRetriesBySource: {
      ..._retryPolicy.fileRetriesBySource,
      ...fileRetriesBySource,
    },
  );
  _concurrencyPolicy = _ConcurrencyPolicy(
    fileConcurrentDefault: fileConcurrentDefault,
    fileConcurrentBySource: {
      ..._concurrencyPolicy.fileConcurrentBySource,
      ...fileConcurrentBySource,
    },
  );

  final storage = Directory(storageDir);
  storage.createSync(recursive: true);

  final dbFile = File(p.join(storage.path, 'library.db'));
  final db = sqlite3.open(dbFile.path);
  _initDb(db);

  final taskRunner = _TaskRunner(db: db, storage: storage);
  taskRunner.markStaleRunningTasksFailed();
  taskRunner.enqueueQueuedFromDb();

  final extracting = <String, Future<void>>{};

  const defaultFavoriteFolder = '默认';

  bool isValidFolderName(String name) {
    final v = name.trim();
    if (v.isEmpty) return false;
    if (v.length > 64) return false;
    if (v.contains('/') || v.contains('\\')) return false;
    if (v.contains('..')) return false;
    return true;
  }

  void ensureFavoriteFolder(String name) {
    final v = name.trim();
    if (!isValidFolderName(v)) return;
    final row = db.select(
      'select name from favorite_folders where name = ?',
      [v],
    ).firstOrNull;
    if (row != null) return;
    final maxOrder = db
        .select(
            'select coalesce(max(order_value), 0) as m from favorite_folders')
        .first['m'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      insert into favorite_folders (name, order_value, created_at, updated_at)
      values (?, ?, ?, ?)
      ''',
      [v, maxOrder + 1, now, now],
    );
  }

  ensureFavoriteFolder(defaultFavoriteFolder);

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
            if (child is File && isPageFile(p.basename(child.path))) {
              return true;
            }
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

  Future<Response> ingestComicZip({
    required Map<String, dynamic> meta,
    required String zipPath,
    String? coverOverridePath,
  }) async {
    final id = (meta['id'] ?? '').toString();
    if (id.isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing meta.id'});
    }

    final comicDir = Directory(p.join(storage.path, 'comics', _safeId(id)));
    comicDir.createSync(recursive: true);

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
    if (coverOverridePath != null) {
      final out = File(p.join(comicDir.path, 'cover.jpg'));
      if (p.normalize(coverOverridePath) != p.normalize(out.path)) {
        try {
          if (out.existsSync()) out.deleteSync();
          await File(coverOverridePath).openRead().pipe(out.openWrite());
        } catch (_) {
          // ignore
        }
      }
      if (out.existsSync()) {
        coverPath = out.path;
      }
    }

    if (coverPath == null) {
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
        'build': _picaServerBuild,
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
    if (!file.existsSync()) {
      return _json(404, {'ok': false, 'error': 'not found'});
    }

    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    return Response.ok(file.openRead(), headers: {'content-type': mime});
  });

  if (enableUserdata) {
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
  } else {
    api.post('/v1/userdata', (Request req) {
      return _json(410, {'ok': false, 'error': 'userdata disabled'});
    });
    api.get('/v1/userdata', (Request req) {
      return _json(410, {'ok': false, 'error': 'userdata disabled'});
    });
  }

  api.post('/v1/comics/fetch', (Request req) async {
    final body = await req.readAsString();
    if (body.trim().isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing body'});
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return _json(400, {'ok': false, 'error': 'invalid json'});
    }
    if (decoded is! Map) {
      return _json(400, {'ok': false, 'error': 'invalid json'});
    }
    final json = Map<String, dynamic>.from(decoded);

    final zipUrl = (json['zipUrl'] ?? '').toString().trim();
    if (zipUrl.isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing zipUrl'});
    }

    final metaRaw = json['meta'];
    if (metaRaw is! Map) {
      return _json(400, {'ok': false, 'error': 'missing meta'});
    }
    final meta = Map<String, dynamic>.from(metaRaw);

    Map<String, String>? headers;
    final headersRaw = json['headers'];
    if (headersRaw is Map) {
      final tmp = <String, String>{};
      for (final e in headersRaw.entries) {
        final k = e.key.toString().trim();
        final v = (e.value ?? '').toString();
        if (k.isEmpty) continue;
        if (k.length > 128) continue;
        if (v.length > 4096) continue;
        tmp[k] = v;
      }
      if (tmp.isNotEmpty) headers = tmp;
    }

    Uri uri;
    try {
      uri = Uri.parse(zipUrl);
    } catch (_) {
      return _json(400, {'ok': false, 'error': 'invalid zipUrl'});
    }

    final tmpDir = Directory.systemTemp.createTempSync('pica_server_fetch_');
    final outZip = File(p.join(tmpDir.path, 'comic.zip'));
    try {
      await _downloadToFile(
        uri,
        outZip,
        headers: headers,
        maxBytes: 4 * 1024 * 1024 * 1024,
        retries: _retryPolicy.fileRetriesDefault,
      );
      return await ingestComicZip(meta: meta, zipPath: outZip.path);
    } catch (e) {
      return _json(500, {'ok': false, 'error': 'fetch failed: $e'});
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // ignore
      }
    }
  });

  Future<Map<String, dynamic>?> readJsonMap(Request req) async {
    final body = await req.readAsString();
    if (body.trim().isEmpty) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  bool isValidSource(String source) {
    return const {
      'picacg',
      'ehentai',
      'jm',
      'hitomi',
      'htmanga',
      'nhentai',
    }.contains(source);
  }

  api.put('/v1/auth/<source>', (Request req, String source) async {
    source = source.trim();
    if (!isValidSource(source)) {
      return _json(400, {'ok': false, 'error': 'invalid source'});
    }
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      '''
      insert or replace into auth_sessions (source, data_json, updated_at)
      values (?, ?, ?)
      ''',
      [source, jsonEncode(json), now],
    );
    return _json(200, {'ok': true});
  });

  api.get('/v1/auth/<source>', (Request req, String source) {
    source = source.trim();
    if (!isValidSource(source)) {
      return _json(400, {'ok': false, 'error': 'invalid source'});
    }
    final row = db.select(
      'select updated_at from auth_sessions where source = ?',
      [source],
    ).firstOrNull;
    if (row == null) {
      return _json(200, {'ok': true, 'source': source, 'exists': false});
    }
    return _json(200, {
      'ok': true,
      'source': source,
      'exists': true,
      'updatedAt': row['updated_at'],
    });
  });

  api.get('/v1/auth', (Request req) {
    final rows = db.select(
      'select source, updated_at from auth_sessions order by source asc',
    );
    return _json(200, {
      'ok': true,
      'items': rows
          .map((r) => {
                'source': r['source'],
                'updatedAt': r['updated_at'],
              })
          .toList(),
    });
  });

  api.post('/v1/tasks/download', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});

    final source = (json['source'] ?? '').toString().trim();
    final target = (json['target'] ?? '').toString().trim();
    if (!isValidSource(source)) {
      return _json(400, {'ok': false, 'error': 'invalid source'});
    }
    if (target.isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing target'});
    }

    final epsRaw = json['eps'];
    if (epsRaw is List) {
      final eps = <int>[];
      for (final e in epsRaw) {
        final v = int.tryParse(e.toString());
        if (v == null) continue;
        if (v < 0) continue;
        eps.add(v);
      }
      json['eps'] = eps;
    }

    try {
      final taskId = taskRunner.createDownloadTask(json);
      return _json(200, {'ok': true, 'taskId': taskId});
    } catch (e) {
      final canonicalId = _canonicalComicId(source: source, target: target);
      final msg = e.toString();
      if (msg.contains('already downloaded')) {
        return _json(409, {
          'ok': false,
          'error': 'already downloaded',
          'comicId': canonicalId,
        });
      }
      if (msg.contains('task already exists')) {
        return _json(409, {
          'ok': false,
          'error': 'task already exists',
        });
      }
      return _json(500, {'ok': false, 'error': 'create task failed: $e'});
    }
  });

  api.get('/v1/tasks/config', (Request req) {
    return _json(200, {
      'ok': true,
      'maxConcurrent': taskRunner.maxConcurrent,
      'fileConcurrent': _concurrencyPolicy.fileConcurrentDefault,
    });
  });

  api.put('/v1/tasks/config', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});

    var changed = false;

    final rawMax = json['maxConcurrent'];
    final vMax = int.tryParse((rawMax ?? '').toString());
    if (vMax != null) {
      taskRunner.setMaxConcurrent(vMax);
      changed = true;
    }

    final rawFile = json['fileConcurrent'];
    final vFile = int.tryParse((rawFile ?? '').toString());
    if (vFile != null) {
      final next = vFile.clamp(1, 16);
      _concurrencyPolicy = _ConcurrencyPolicy(
        fileConcurrentDefault: next,
        fileConcurrentBySource: _concurrencyPolicy.fileConcurrentBySource,
      );
      changed = true;
    }

    if (!changed) {
      return _json(400, {
        'ok': false,
        'error': 'missing maxConcurrent/fileConcurrent',
      });
    }

    return _json(200, {
      'ok': true,
      'maxConcurrent': taskRunner.maxConcurrent,
      'fileConcurrent': _concurrencyPolicy.fileConcurrentDefault,
    });
  });

  api.post('/v1/tasks/<id>/pause', (Request req, String id) {
    taskRunner.pauseTask(id);
    return _json(200, {'ok': true});
  });

  api.post('/v1/tasks/<id>/resume', (Request req, String id) {
    taskRunner.resumeTask(id);
    return _json(200, {'ok': true});
  });

  api.post('/v1/tasks/<id>/cancel', (Request req, String id) {
    taskRunner.cancelTask(id);
    return _json(200, {'ok': true});
  });

  api.post('/v1/tasks/<id>/retry', (Request req, String id) {
    taskRunner.retryTask(id);
    return _json(200, {'ok': true});
  });

  api.delete('/v1/tasks/<id>', (Request req, String id) {
    final ok = taskRunner.deleteTask(id);
    if (!ok) {
      return _json(409, {'ok': false, 'error': 'task is running'});
    }
    return _json(200, {'ok': true});
  });

  api.get('/v1/tasks', (Request req) {
    final limit = int.tryParse(req.url.queryParameters['limit'] ?? '50') ?? 50;
    final n = limit.clamp(1, 200).toInt();
    final rows = db.select(
      '''
      select id, type, source, target, status, progress, total, message, comic_id, created_at, updated_at
      from tasks
      order by created_at desc
      limit ?
      ''',
      [n],
    );
    return _json(200, {
      'ok': true,
      'tasks': rows
          .map((r) => {
                'id': r['id'],
                'type': r['type'],
                'source': r['source'],
                'target': r['target'],
                'status': r['status'],
                'progress': r['progress'],
                'total': r['total'],
                'message': r['message'],
                'comicId': r['comic_id'],
                'createdAt': r['created_at'],
                'updatedAt': r['updated_at'],
              })
          .toList(),
    });
  });

  api.get('/v1/tasks/<id>', (Request req, String id) {
    final row = db.select(
      '''
      select id, type, source, target, params_json, status, progress, total, message, comic_id, created_at, updated_at
      from tasks
      where id = ?
      ''',
      [id],
    ).firstOrNull;
    if (row == null) return _json(404, {'ok': false, 'error': 'not found'});
    Object? params;
    try {
      params = jsonDecode((row['params_json'] as String));
    } catch (_) {
      params = null;
    }
    return _json(200, {
      'ok': true,
      'task': {
        'id': row['id'],
        'type': row['type'],
        'source': row['source'],
        'target': row['target'],
        'params': params,
        'status': row['status'],
        'progress': row['progress'],
        'total': row['total'],
        'message': row['message'],
        'comicId': row['comic_id'],
        'createdAt': row['created_at'],
        'updatedAt': row['updated_at'],
      }
    });
  });

  api.get('/v1/favorites/folders', (Request req) {
    ensureFavoriteFolder(defaultFavoriteFolder);
    final rows = db.select(
      'select name, order_value from favorite_folders order by order_value desc',
    );
    final folders = rows
        .map((r) => {
              'name': r['name'],
              'orderValue': r['order_value'],
            })
        .toList();
    return _json(200, {'ok': true, 'folders': folders});
  });

  api.post('/v1/favorites/folders', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});
    final name = (json['name'] ?? '').toString().trim();
    if (!isValidFolderName(name)) {
      return _json(400, {'ok': false, 'error': 'invalid name'});
    }
    ensureFavoriteFolder(defaultFavoriteFolder);
    ensureFavoriteFolder(name);
    return _json(200, {'ok': true});
  });

  api.patch('/v1/favorites/folders/order', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});
    final namesRaw = json['names'];
    if (namesRaw is! List) {
      return _json(400, {'ok': false, 'error': 'missing names'});
    }
    ensureFavoriteFolder(defaultFavoriteFolder);
    final names = namesRaw
        .map((e) => e.toString().trim())
        .where(isValidFolderName)
        .toList();
    if (names.isEmpty) return _json(200, {'ok': true});

    final existing = db
        .select('select name from favorite_folders')
        .map((r) => r['name'].toString())
        .toSet();
    final ordered = names.where(existing.contains).toList();
    if (ordered.isEmpty) return _json(200, {'ok': true});

    final maxOrder = db
        .select(
            'select coalesce(max(order_value), 0) as m from favorite_folders')
        .first['m'] as int;
    final base = maxOrder + ordered.length;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < ordered.length; i++) {
      db.execute(
        'update favorite_folders set order_value = ?, updated_at = ? where name = ?',
        [base - i, now, ordered[i]],
      );
    }
    return _json(200, {'ok': true});
  });

  api.patch('/v1/favorites/folders/rename', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});
    final from = (json['from'] ?? '').toString().trim();
    final to = (json['to'] ?? '').toString().trim();
    if (!isValidFolderName(from) || !isValidFolderName(to)) {
      return _json(400, {'ok': false, 'error': 'invalid name'});
    }
    if (from == defaultFavoriteFolder) {
      return _json(400, {'ok': false, 'error': 'cannot rename default'});
    }
    ensureFavoriteFolder(defaultFavoriteFolder);
    final exists = db.select(
      'select name from favorite_folders where name = ?',
      [from],
    ).firstOrNull;
    if (exists == null) return _json(404, {'ok': false, 'error': 'not found'});
    final toExists = db.select(
      'select name from favorite_folders where name = ?',
      [to],
    ).firstOrNull;
    if (toExists != null) {
      return _json(409, {'ok': false, 'error': 'already exists'});
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    db.execute(
      'update favorite_folders set name = ?, updated_at = ? where name = ?',
      [to, now, from],
    );
    db.execute(
      'update favorites set folder = ?, updated_at = ? where folder = ?',
      [to, now, from],
    );
    return _json(200, {'ok': true});
  });

  api.delete('/v1/favorites/folders/<name>', (Request req, String name) {
    final folder = Uri.decodeComponent(name).trim();
    if (!isValidFolderName(folder)) {
      return _json(400, {'ok': false, 'error': 'invalid name'});
    }
    if (folder == defaultFavoriteFolder) {
      return _json(400, {'ok': false, 'error': 'cannot delete default'});
    }
    ensureFavoriteFolder(defaultFavoriteFolder);
    final exists = db.select(
      'select name from favorite_folders where name = ?',
      [folder],
    ).firstOrNull;
    if (exists == null) return _json(404, {'ok': false, 'error': 'not found'});

    final moveTo = (req.url.queryParameters['moveTo'] ?? defaultFavoriteFolder)
        .toString()
        .trim();
    if (!isValidFolderName(moveTo)) {
      return _json(400, {'ok': false, 'error': 'invalid moveTo'});
    }
    ensureFavoriteFolder(moveTo);

    final maxOrderRow = db.select(
      'select coalesce(max(order_value), 0) as m from favorites where folder = ?',
      [moveTo],
    );
    var base = maxOrderRow.first['m'] as int;

    final items = db.select(
      '''
      select source_key, target
      from favorites
      where folder = ?
      order by order_value desc
      ''',
      [folder],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      base += 1;
      db.execute(
        '''
        update favorites
        set folder = ?, order_value = ?, updated_at = ?
        where source_key = ? and target = ?
        ''',
        [moveTo, base, now, item['source_key'], item['target']],
      );
    }

    db.execute('delete from favorite_folders where name = ?', [folder]);
    return _json(200, {'ok': true});
  });

  api.get('/v1/favorites', (Request req) {
    ensureFavoriteFolder(defaultFavoriteFolder);
    final folder = (req.url.queryParameters['folder'] ?? defaultFavoriteFolder)
        .toString()
        .trim();
    if (!isValidFolderName(folder)) {
      return _json(400, {'ok': false, 'error': 'invalid folder'});
    }
    final rows = db.select(
      '''
      select source_key, target, folder, title, subtitle, cover, tags, order_value, added_at, updated_at
      from favorites
      where folder = ?
      order by order_value desc
      ''',
      [folder],
    );
    final favorites = rows
        .map((r) => {
              'sourceKey': r['source_key'],
              'target': r['target'],
              'folder': r['folder'],
              'title': r['title'],
              'subtitle': r['subtitle'],
              'cover': r['cover'],
              'tags': _tryDecodeJson(r['tags']) ?? [],
              'orderValue': r['order_value'],
              'addedAt': r['added_at'],
              'updatedAt': r['updated_at'],
            })
        .toList();
    return _json(200, {'ok': true, 'folder': folder, 'favorites': favorites});
  });

  api.get('/v1/favorites/contains', (Request req) {
    final sourceKey = (req.url.queryParameters['sourceKey'] ?? '').toString();
    final target = (req.url.queryParameters['target'] ?? '').toString();
    if (sourceKey.trim().isEmpty || target.trim().isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing params'});
    }
    final row = db.select(
      'select folder from favorites where source_key = ? and target = ?',
      [sourceKey, target],
    ).firstOrNull;
    return _json(200, {
      'ok': true,
      'exists': row != null,
      'folder': row?['folder'],
    });
  });

  api.post('/v1/favorites', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});

    final sourceKey = (json['sourceKey'] ?? '').toString();
    final target = (json['target'] ?? '').toString();
    if (sourceKey.trim().isEmpty || target.trim().isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing id'});
    }

    final folderRaw =
        (json['folder'] ?? defaultFavoriteFolder).toString().trim();
    final folder =
        isValidFolderName(folderRaw) ? folderRaw : defaultFavoriteFolder;
    ensureFavoriteFolder(defaultFavoriteFolder);
    ensureFavoriteFolder(folder);

    final title = (json['title'] ?? '').toString();
    final subtitle = (json['subtitle'] ?? '').toString();
    final cover = (json['cover'] ?? '').toString();
    final tags = jsonEncode(json['tags'] ?? []);

    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = db.select(
      'select folder from favorites where source_key = ? and target = ?',
      [sourceKey, target],
    ).firstOrNull;

    if (existing == null) {
      final maxOrder = db.select(
        'select coalesce(max(order_value), 0) as m from favorites where folder = ?',
        [folder],
      ).first['m'] as int;
      db.execute(
        '''
        insert into favorites
        (source_key, target, folder, title, subtitle, cover, tags, order_value, added_at, updated_at)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          sourceKey,
          target,
          folder,
          title,
          subtitle,
          cover,
          tags,
          maxOrder + 1,
          now,
          now
        ],
      );
      return _json(200, {'ok': true});
    }

    final oldFolder = (existing['folder'] ?? '').toString();
    if (oldFolder != folder) {
      final maxOrder = db.select(
        'select coalesce(max(order_value), 0) as m from favorites where folder = ?',
        [folder],
      ).first['m'] as int;
      db.execute(
        '''
        update favorites
        set folder = ?, title = ?, subtitle = ?, cover = ?, tags = ?, order_value = ?, updated_at = ?
        where source_key = ? and target = ?
        ''',
        [
          folder,
          title,
          subtitle,
          cover,
          tags,
          maxOrder + 1,
          now,
          sourceKey,
          target
        ],
      );
      return _json(200, {'ok': true});
    }

    db.execute(
      '''
      update favorites
      set title = ?, subtitle = ?, cover = ?, tags = ?, updated_at = ?
      where source_key = ? and target = ?
      ''',
      [title, subtitle, cover, tags, now, sourceKey, target],
    );
    return _json(200, {'ok': true});
  });

  api.delete('/v1/favorites', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});
    final sourceKey = (json['sourceKey'] ?? '').toString();
    final target = (json['target'] ?? '').toString();
    if (sourceKey.trim().isEmpty || target.trim().isEmpty) {
      return _json(400, {'ok': false, 'error': 'missing id'});
    }
    db.execute(
      'delete from favorites where source_key = ? and target = ?',
      [sourceKey, target],
    );
    return _json(200, {'ok': true});
  });

  api.patch('/v1/favorites/move', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});

    final folderRaw = (json['folder'] ?? '').toString().trim();
    if (!isValidFolderName(folderRaw)) {
      return _json(400, {'ok': false, 'error': 'invalid folder'});
    }
    ensureFavoriteFolder(defaultFavoriteFolder);
    ensureFavoriteFolder(folderRaw);

    final itemsRaw = json['items'];
    if (itemsRaw is! List) {
      return _json(400, {'ok': false, 'error': 'missing items'});
    }

    final maxOrder = db.select(
      'select coalesce(max(order_value), 0) as m from favorites where folder = ?',
      [folderRaw],
    ).first['m'] as int;
    var base = maxOrder;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final raw in itemsRaw) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final sourceKey = (item['sourceKey'] ?? '').toString();
      final target = (item['target'] ?? '').toString();
      if (sourceKey.trim().isEmpty || target.trim().isEmpty) continue;
      base += 1;
      db.execute(
        '''
        update favorites
        set folder = ?, order_value = ?, updated_at = ?
        where source_key = ? and target = ?
        ''',
        [folderRaw, base, now, sourceKey, target],
      );
    }

    return _json(200, {'ok': true});
  });

  api.patch('/v1/favorites/order', (Request req) async {
    final json = await readJsonMap(req);
    if (json == null) return _json(400, {'ok': false, 'error': 'invalid json'});
    final folder = (json['folder'] ?? '').toString().trim();
    if (!isValidFolderName(folder)) {
      return _json(400, {'ok': false, 'error': 'invalid folder'});
    }
    final itemsRaw = json['items'];
    if (itemsRaw is! List) {
      return _json(400, {'ok': false, 'error': 'missing items'});
    }

    final maxOrder = db.select(
      'select coalesce(max(order_value), 0) as m from favorites where folder = ?',
      [folder],
    ).first['m'] as int;
    final base = maxOrder + itemsRaw.length;
    final now = DateTime.now().millisecondsSinceEpoch;

    var i = 0;
    for (final raw in itemsRaw) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final sourceKey = (item['sourceKey'] ?? '').toString();
      final target = (item['target'] ?? '').toString();
      if (sourceKey.trim().isEmpty || target.trim().isEmpty) continue;
      db.execute(
        '''
        update favorites
        set order_value = ?, updated_at = ?
        where folder = ? and source_key = ? and target = ?
        ''',
        [base - i, now, folder, sourceKey, target],
      );
      i++;
    }
    return _json(200, {'ok': true});
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

    String? coverOverridePath;
    final coverPart = parts.files['cover'];
    if (coverPart != null) {
      final coverPath = p.join(comicDir.path, 'cover.jpg');
      await coverPart.saveTo(coverPath);
      coverOverridePath = coverPath;
    }

    return ingestComicZip(
      meta: meta,
      zipPath: zipPath,
      coverOverridePath: coverOverridePath,
    );
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
    if (coverPath == null) {
      return _json(404, {'ok': false, 'error': 'no cover'});
    }
    final file = File(coverPath);
    if (!file.existsSync()) {
      return _json(404, {'ok': false, 'error': 'file missing'});
    }
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

  db.execute('''
    create table if not exists auth_sessions (
      source text primary key,
      data_json text not null,
      updated_at int not null
    );
  ''');

  db.execute('''
    create table if not exists tasks (
      id text primary key,
      type text not null,
      source text not null,
      target text not null,
      params_json text not null,
      status text not null,
      progress int not null,
      total int not null,
      message text,
      comic_id text,
      created_at int not null,
      updated_at int not null
    );
  ''');

  db.execute('''
    create table if not exists favorite_folders (
      name text primary key,
      order_value int not null,
      created_at int not null,
      updated_at int not null
    );
  ''');

  db.execute('''
    create table if not exists favorites (
      source_key text not null,
      target text not null,
      folder text not null,
      title text not null,
      subtitle text not null,
      cover text not null,
      tags text not null,
      order_value int not null,
      added_at int not null,
      updated_at int not null,
      primary key (source_key, target)
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
