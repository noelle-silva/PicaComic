import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';

class PicaServer {
  PicaServer._();

  static final PicaServer instance = PicaServer._();

  String get baseUrl => appdata.settings.elementAtOrNull(90) ?? '';

  String get _normalizedBaseUrl {
    var v = baseUrl.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  String get apiKey => appdata.implicitData.elementAtOrNull(4) ?? '';

  bool get enabled => _normalizedBaseUrl.isNotEmpty;

  Dio _dio() {
    final options = BaseOptions(
      baseUrl: _normalizedBaseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
      headers: apiKey.isEmpty ? null : {'X-Api-Key': apiKey},
    );
    return logDio(options);
  }

  Future<bool> health() async {
    if (!enabled) return false;
    try {
      final res = await _dio().get('/api/v1/health');
      return res.statusCode == 200 &&
          (res.data is Map ? res.data['ok'] == true : true);
    } catch (_) {
      return false;
    }
  }

  Future<void> uploadUserData() async {
    final dio = _dio();
    final outPath = '${App.cachePath}/userdata.picadata';
    if (await File(outPath).exists()) {
      await File(outPath).delete();
    }
    appdata.settings[46] =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    await appdata.updateSettings(false);
    await exportDataToFile(false, outPath);

    final form = FormData.fromMap({
      'file':
          await MultipartFile.fromFile(outPath, filename: 'userdata.picadata'),
    });

    await dio.post('/api/v1/userdata', data: form);
  }

  Future<void> downloadUserDataAndImport() async {
    final dio = _dio();
    final temp = await getTemporaryDirectory();
    final outPath = '${temp.path}${pathSep}userdata.picadata';
    if (await File(outPath).exists()) {
      await File(outPath).delete();
    }
    await dio.download('/api/v1/userdata', outPath);
    await importData(outPath);
  }

  Future<List<ServerComic>> listComics() async {
    final dio = _dio();
    final res = await dio.get('/api/v1/comics');
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['comics'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ServerComic.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ServerComic?> getComic(String id) async {
    final dio = _dio();
    final res = await dio.get('/api/v1/comics/$id');
    final data = res.data;
    if (data is! Map) return null;
    final comic = data['comic'];
    if (comic is! Map) return null;
    return ServerComic.fromMap(Map<String, dynamic>.from(comic));
  }

  Future<void> uploadDownloadedComic(DownloadedItem item) async {
    final dio = _dio();
    await DownloadManager().init();

    final directory = item.directory ?? DownloadManager().getDirectory(item.id);
    final comicDir = Directory('${DownloadManager().path}$pathSep$directory');
    if (!comicDir.existsSync()) {
      throw Exception('comic directory not found');
    }

    final temp = await getTemporaryDirectory();
    final zipPath = '${temp.path}${pathSep}pica_server_${item.id}.zip';
    if (File(zipPath).existsSync()) {
      File(zipPath).deleteSync();
    }
    await _zipDirectory(comicDir, zipPath);

    final coverPath = '${comicDir.path}${pathSep}cover.jpg';
    final coverFile = File(coverPath);

    final meta = <String, dynamic>{
      'id': item.id,
      'title': item.name,
      'subtitle': item.subTitle,
      'type': item.type.index,
      'tags': item.tags,
      'directory': directory,
      'json': item.toJson(),
    };

    final form = FormData.fromMap({
      'meta': jsonEncode(meta),
      'zip': await MultipartFile.fromFile(zipPath, filename: '${item.id}.zip'),
      if (coverFile.existsSync())
        'cover':
            await MultipartFile.fromFile(coverFile.path, filename: 'cover.jpg'),
    });

    await dio.post('/api/v1/comics', data: form);
  }

  Future<void> putAuthSession(String source, Map<String, dynamic> data) async {
    final dio = _dio();
    await dio.put('/api/v1/auth/${Uri.encodeComponent(source)}', data: data);
  }

  Future<Map<String, dynamic>> getAuthSessionInfo(String source) async {
    final dio = _dio();
    final res = await dio.get('/api/v1/auth/${Uri.encodeComponent(source)}');
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    return Map<String, dynamic>.from(data);
  }

  Future<String> createDownloadTask({
    required String source,
    required String target,
    List<int>? eps,
    String? title,
    String? coverUrl,
  }) async {
    final dio = _dio();
    final payload = <String, dynamic>{
      'source': source,
      'target': target,
      if (eps != null) 'eps': eps,
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      if (coverUrl != null && coverUrl.trim().isNotEmpty)
        'coverUrl': coverUrl.trim(),
    };
    final res = await dio.post(
      '/api/v1/tasks/download',
      data: payload,
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      final err = (data['error'] ?? 'request failed').toString();
      if (err == 'already downloaded') {
        throw Exception("已经下载".tl);
      }
      if (err == 'task already exists') {
        throw Exception("任务已存在".tl);
      }
      throw Exception(err);
    }
    final taskId = (data['taskId'] ?? '').toString();
    if (taskId.isEmpty) throw Exception('missing taskId');
    return taskId;
  }

  Future<int> getMaxConcurrent() async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/tasks/config',
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
    return int.tryParse((data['maxConcurrent'] ?? '1').toString()) ?? 1;
  }

  Future<int> setMaxConcurrent(int value) async {
    final dio = _dio();
    final res = await dio.put(
      '/api/v1/tasks/config',
      data: {'maxConcurrent': value},
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
    return int.tryParse((data['maxConcurrent'] ?? '').toString()) ?? value;
  }

  Future<void> pauseTask(String id) async {
    final dio = _dio();
    final res = await dio.post(
      '/api/v1/tasks/${Uri.encodeComponent(id)}/pause',
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
  }

  Future<void> resumeTask(String id) async {
    final dio = _dio();
    final res = await dio.post(
      '/api/v1/tasks/${Uri.encodeComponent(id)}/resume',
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
  }

  Future<void> cancelTask(String id) async {
    final dio = _dio();
    final res = await dio.post(
      '/api/v1/tasks/${Uri.encodeComponent(id)}/cancel',
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
  }

  Future<void> retryTask(String id) async {
    final dio = _dio();
    final res = await dio.post(
      '/api/v1/tasks/${Uri.encodeComponent(id)}/retry',
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
  }

  Future<void> deleteTask(String id) async {
    final dio = _dio();
    final res = await dio.delete(
      '/api/v1/tasks/${Uri.encodeComponent(id)}',
      options: Options(validateStatus: (_) => true),
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
  }

  Future<List<ServerTask>> listTasks({int limit = 50}) async {
    final dio = _dio();
    final n = limit.clamp(1, 200).toInt();
    final res = await dio.get(
      '/api/v1/tasks',
      queryParameters: {'limit': n},
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
    final list = data['tasks'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ServerTask.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ServerTask> getTaskDetail(String id) async {
    final dio = _dio();
    final res = await dio.get('/api/v1/tasks/${Uri.encodeComponent(id)}');
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) {
      throw Exception((data['error'] ?? 'request failed').toString());
    }
    final task = data['task'];
    if (task is! Map) throw Exception('invalid response');
    return ServerTask.fromMap(Map<String, dynamic>.from(task));
  }

  Future<Map<String, dynamic>> getTask(String id) async {
    final task = await getTaskDetail(id);
    return {
      'ok': true,
      'task': task.toMap(),
    };
  }

  Future<File> downloadComicZip(String id, String outPath) async {
    final dio = _dio();
    if (File(outPath).existsSync()) {
      File(outPath).deleteSync();
    }
    await dio.download('/api/v1/comics/$id/zip', outPath);
    return File(outPath);
  }

  Map<String, String> imageHeaders() {
    if (apiKey.isEmpty) return {};
    return {'X-Api-Key': apiKey};
  }

  Future<ServerReadInfo> getReadInfo(String id) async {
    final dio = _dio();
    final res = await dio.get('/api/v1/comics/${Uri.encodeComponent(id)}/read');
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) throw Exception(data['error'] ?? 'request failed');
    return ServerReadInfo.fromMap(Map<String, dynamic>.from(data));
  }

  Future<List<String>> listPages(String id, int ep) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/comics/${Uri.encodeComponent(id)}/pages',
      queryParameters: {'ep': ep},
    );
    final data = res.data;
    if (data is! Map) throw Exception('invalid response');
    if (data['ok'] != true) throw Exception(data['error'] ?? 'request failed');
    final pages = data['pages'];
    if (pages is! List) return const [];
    return pages.map((e) => e.toString()).toList();
  }

  Future<void> deleteComic(String id) async {
    final dio = _dio();
    await dio.delete('/api/v1/comics/${Uri.encodeComponent(id)}');
  }

  Future<List<ServerFavoriteFolder>> listFavoriteFolders() async {
    final dio = _dio();
    final res = await dio.get('/api/v1/favorites/folders');
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['folders'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ServerFavoriteFolder.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> createFavoriteFolder(String name) async {
    final dio = _dio();
    await dio.post('/api/v1/favorites/folders', data: {'name': name});
  }

  Future<void> renameFavoriteFolder(String from, String to) async {
    final dio = _dio();
    await dio.patch('/api/v1/favorites/folders/rename', data: {
      'from': from,
      'to': to,
    });
  }

  Future<void> reorderFavoriteFolders(List<String> names) async {
    final dio = _dio();
    await dio.patch('/api/v1/favorites/folders/order', data: {'names': names});
  }

  Future<void> deleteFavoriteFolder(String name,
      {required String moveTo}) async {
    final dio = _dio();
    await dio.delete(
      '/api/v1/favorites/folders/${Uri.encodeComponent(name)}',
      queryParameters: {'moveTo': moveTo},
    );
  }

  Future<List<ServerFavoriteItem>> listFavorites(String folder) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/favorites',
      queryParameters: {'folder': folder},
    );
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['favorites'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ServerFavoriteItem.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ServerFavoriteContains> containsFavorite({
    required String sourceKey,
    required String target,
  }) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/favorites/contains',
      queryParameters: {'sourceKey': sourceKey, 'target': target},
    );
    final data = res.data;
    if (data is! Map) {
      return const ServerFavoriteContains(exists: false, folder: null);
    }
    return ServerFavoriteContains(
      exists: data['exists'] == true,
      folder: data['folder']?.toString(),
    );
  }

  Future<void> addFavorite(ServerFavoriteItem item) async {
    final dio = _dio();
    await dio.post('/api/v1/favorites', data: item.toCreateMap());
  }

  Future<void> removeFavorite({
    required String sourceKey,
    required String target,
  }) async {
    final dio = _dio();
    await dio.delete('/api/v1/favorites', data: {
      'sourceKey': sourceKey,
      'target': target,
    });
  }

  Future<void> moveFavorites({
    required String folder,
    required List<ServerFavoriteKey> items,
  }) async {
    final dio = _dio();
    await dio.patch('/api/v1/favorites/move', data: {
      'folder': folder,
      'items': items.map((e) => e.toMap()).toList(),
    });
  }

  Future<void> reorderFavorites({
    required String folder,
    required List<ServerFavoriteKey> items,
  }) async {
    final dio = _dio();
    await dio.patch('/api/v1/favorites/order', data: {
      'folder': folder,
      'items': items.map((e) => e.toMap()).toList(),
    });
  }
}

class ServerReadInfo {
  final bool hasEps;
  final List<ServerEp> eps;

  const ServerReadInfo({
    required this.hasEps,
    required this.eps,
  });

  factory ServerReadInfo.fromMap(Map<String, dynamic> map) {
    final hasEps = map['hasEps'] == true;
    final epsRaw = map['eps'];
    final eps = (epsRaw is List)
        ? epsRaw
            .whereType<Map>()
            .map((e) => ServerEp.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : const <ServerEp>[];
    return ServerReadInfo(hasEps: hasEps, eps: eps);
  }
}

class ServerEp {
  final int ep;
  final String title;

  const ServerEp({required this.ep, required this.title});

  factory ServerEp.fromMap(Map<String, dynamic> map) {
    return ServerEp(
      ep: int.tryParse((map['ep'] ?? '').toString()) ?? 0,
      title: (map['title'] ?? '').toString(),
    );
  }
}

class ServerComic {
  final String id;
  final String title;
  final String subtitle;
  final int type;
  final List<String> tags;
  final String directory;
  final int? time;
  final int? size;
  final String? coverUrl;
  final String? zipUrl;
  final Map<String, dynamic>? meta;

  const ServerComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.tags,
    required this.directory,
    this.time,
    this.size,
    this.coverUrl,
    this.zipUrl,
    this.meta,
  });

  factory ServerComic.fromMap(Map<String, dynamic> map) {
    return ServerComic(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      subtitle: (map['subtitle'] ?? '').toString(),
      type: int.tryParse((map['type'] ?? '').toString()) ?? -1,
      tags: (map['tags'] is List)
          ? List<String>.from((map['tags'] as List).map((e) => e.toString()))
          : const [],
      directory: (map['directory'] ?? '').toString(),
      time: int.tryParse((map['time'] ?? '').toString()),
      size: int.tryParse((map['size'] ?? '').toString()),
      coverUrl: map['coverUrl']?.toString(),
      zipUrl: map['zipUrl']?.toString(),
      meta: map['meta'] is Map ? Map<String, dynamic>.from(map['meta']) : null,
    );
  }

  DownloadedItem? toDownloadedItem() {
    final m = meta;
    if (m == null) return null;
    final jsonObj = m['json'];
    if (jsonObj is! Map) return null;
    try {
      final jsonStr = jsonEncode(jsonObj);
      return getDownloadedComicFromJson(id, jsonStr, DateTime.now(), directory);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'PicaServer',
          'failed to build DownloadedItem: $e\n$s');
      return null;
    }
  }
}

class ServerFavoriteFolder {
  final String name;
  final int? orderValue;

  const ServerFavoriteFolder({required this.name, this.orderValue});

  factory ServerFavoriteFolder.fromMap(Map<String, dynamic> map) {
    return ServerFavoriteFolder(
      name: (map['name'] ?? '').toString(),
      orderValue: int.tryParse((map['orderValue'] ?? '').toString()),
    );
  }
}

class ServerFavoriteKey {
  final String sourceKey;
  final String target;

  const ServerFavoriteKey({required this.sourceKey, required this.target});

  Map<String, dynamic> toMap() => {
        'sourceKey': sourceKey,
        'target': target,
      };
}

class ServerFavoriteContains {
  final bool exists;
  final String? folder;

  const ServerFavoriteContains({required this.exists, required this.folder});
}

class ServerFavoriteItem {
  final String sourceKey;
  final String target;
  final String folder;
  final String title;
  final String subtitle;
  final String cover;
  final List<String> tags;
  final int? orderValue;
  final int? addedAt;
  final int? updatedAt;

  const ServerFavoriteItem({
    required this.sourceKey,
    required this.target,
    required this.folder,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.tags,
    this.orderValue,
    this.addedAt,
    this.updatedAt,
  });

  factory ServerFavoriteItem.fromMap(Map<String, dynamic> map) {
    return ServerFavoriteItem(
      sourceKey: (map['sourceKey'] ?? '').toString(),
      target: (map['target'] ?? '').toString(),
      folder: (map['folder'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      subtitle: (map['subtitle'] ?? '').toString(),
      cover: (map['cover'] ?? '').toString(),
      tags: (map['tags'] is List)
          ? List<String>.from((map['tags'] as List).map((e) => e.toString()))
          : const [],
      orderValue: int.tryParse((map['orderValue'] ?? '').toString()),
      addedAt: int.tryParse((map['addedAt'] ?? '').toString()),
      updatedAt: int.tryParse((map['updatedAt'] ?? '').toString()),
    );
  }

  ServerFavoriteKey get key =>
      ServerFavoriteKey(sourceKey: sourceKey, target: target);

  Map<String, dynamic> toCreateMap() => {
        'sourceKey': sourceKey,
        'target': target,
        'folder': folder,
        'title': title,
        'subtitle': subtitle,
        'cover': cover,
        'tags': tags,
      };
}

class ServerTask {
  final String id;
  final String type;
  final String source;
  final String target;
  final String? title;
  final String? coverUrl;
  final String status;
  final int progress;
  final int total;
  final String? message;
  final String? comicId;
  final int? createdAt;
  final int? updatedAt;
  final Map<String, dynamic>? params;

  const ServerTask({
    required this.id,
    required this.type,
    required this.source,
    required this.target,
    this.title,
    this.coverUrl,
    required this.status,
    required this.progress,
    required this.total,
    this.message,
    this.comicId,
    this.createdAt,
    this.updatedAt,
    this.params,
  });

  factory ServerTask.fromMap(Map<String, dynamic> map) {
    return ServerTask(
      id: (map['id'] ?? '').toString(),
      type: (map['type'] ?? '').toString(),
      source: (map['source'] ?? '').toString(),
      target: (map['target'] ?? '').toString(),
      title: map['title']?.toString(),
      coverUrl: map['coverUrl']?.toString(),
      status: (map['status'] ?? '').toString(),
      progress: int.tryParse((map['progress'] ?? '').toString()) ?? 0,
      total: int.tryParse((map['total'] ?? '').toString()) ?? 0,
      message: map['message']?.toString(),
      comicId: map['comicId']?.toString(),
      createdAt: int.tryParse((map['createdAt'] ?? '').toString()),
      updatedAt: int.tryParse((map['updatedAt'] ?? '').toString()),
      params: map['params'] is Map ? Map<String, dynamic>.from(map['params']) : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type,
        'source': source,
        'target': target,
        'title': title,
        'coverUrl': coverUrl,
        'status': status,
        'progress': progress,
        'total': total,
        'message': message,
        'comicId': comicId,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'params': params,
      };
}

Future<void> _zipDirectory(Directory sourceDir, String outZipPath) async {
  await Future<void>.delayed(Duration.zero);
  final sourcePath = sourceDir.path;
  final zipPath = outZipPath;
  await Isolate.run(() {
    final zip = ZipFile.open(zipPath);
    try {
      void walk(String current) {
        for (final entry in Directory(current).listSync()) {
          if (entry is Directory) {
            walk(entry.path);
          } else if (entry is File) {
            final rel = entry.path.substring(sourcePath.length);
            final normalized =
                rel.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
            if (Platform.isWindows) {
              zip.addFileFromBytes(normalized, entry.readAsBytesSync());
            } else {
              zip.addFile(normalized, entry.path);
            }
          }
        }
      }

      walk(sourcePath);
    } finally {
      zip.close();
    }
  });
}
