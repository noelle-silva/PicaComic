import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
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

  int get uploadSendTimeoutSeconds {
    final raw = appdata.settings.elementAtOrNull(92) ?? '1800';
    final v = int.tryParse(raw.trim()) ?? 1800;
    return v.clamp(60, 24 * 60 * 60);
  }

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

  Future<String> uploadDownloadedComic(DownloadedItem item) async {
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
    try {
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
        'zip': await MultipartFile.fromFile(
          zipPath,
          filename: '${item.id}.zip',
        ),
        if (coverFile.existsSync())
          'cover': await MultipartFile.fromFile(
            coverFile.path,
            filename: 'cover.jpg',
          ),
      });

      final res = await dio.post(
        '/api/v1/tasks/upload',
        data: form,
        options: Options(
          validateStatus: (_) => true,
          sendTimeout: Duration(seconds: uploadSendTimeoutSeconds),
        ),
      );
      final data = res.data;
      if (data is! Map) throw Exception('invalid response');
      if (data['ok'] != true) {
        final err = (data['error'] ?? 'request failed').toString();
        if (err == 'task already exists') {
          throw Exception("任务已存在".tl);
        }
        throw Exception(err);
      }
      final taskId = (data['taskId'] ?? '').toString();
      if (taskId.isEmpty) throw Exception('missing taskId');
      return taskId;
    } finally {
      try {
        if (File(zipPath).existsSync()) {
          File(zipPath).deleteSync();
        }
      } catch (_) {
        // ignore
      }
    }
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

  /// 读取服务器保存的登录态内容；不存在时返回 null。
  Future<Map<String, dynamic>?> getAuthSessionData(String source) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/auth/${Uri.encodeComponent(source)}/data',
    );
    final data = res.data;
    if (data is! Map) return null;
    if (data['exists'] != true) return null;
    final session = data['data'];
    if (session is! Map) return null;
    return Map<String, dynamic>.from(session);
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

  /// 查询漫画在服务器资源库中的存在性、漫画 id 与活跃任务标记。
  Future<ServerComicPresence> getComicPresence({
    required String source,
    required String target,
  }) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/comics/contains',
      queryParameters: {'source': source, 'target': target},
    );
    final data = res.data;
    if (data is! Map) {
      return const ServerComicPresence(exists: false);
    }
    final comicId = data['comicId']?.toString();
    return ServerComicPresence(
      exists: data['exists'] == true,
      comicId: comicId == null || comicId.isEmpty ? null : comicId,
      active: data['active'] == true,
    );
  }

  Future<void> addFavorite(ServerFavoriteItem item) async {
    final dio = _dio();
    await dio.post('/api/v1/favorites', data: item.toCreateMap());  }

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

  Future<List<ServerResourceFavoriteFolder>>
      listResourceFavoriteFolders() async {
    final dio = _dio();
    final res = await dio.get('/api/v1/resource-favorites/folders');
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['folders'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) =>
            ServerResourceFavoriteFolder.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> createResourceFavoriteFolder(String name) async {
    final dio = _dio();
    await dio.post('/api/v1/resource-favorites/folders', data: {'name': name});
  }

  Future<void> renameResourceFavoriteFolder(String from, String to) async {
    final dio = _dio();
    await dio.patch('/api/v1/resource-favorites/folders/rename', data: {
      'from': from,
      'to': to,
    });
  }

  Future<void> reorderResourceFavoriteFolders(List<String> names) async {
    final dio = _dio();
    await dio.patch('/api/v1/resource-favorites/folders/order',
        data: {'names': names});
  }

  Future<void> deleteResourceFavoriteFolder(String name,
      {required String moveTo}) async {
    final dio = _dio();
    await dio.delete(
      '/api/v1/resource-favorites/folders/${Uri.encodeComponent(name)}',
      queryParameters: {'moveTo': moveTo},
    );
  }

  Future<List<ServerResourceFavoriteItem>> listResourceFavorites(
      String folder) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/resource-favorites',
      queryParameters: {'folder': folder},
    );
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['favorites'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) =>
            ServerResourceFavoriteItem.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ServerResourceFavoriteContains> containsResourceFavorite(
      String id) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/resource-favorites/contains',
      queryParameters: {'id': id},
    );
    final data = res.data;
    if (data is! Map) {
      return const ServerResourceFavoriteContains(exists: false, folder: null);
    }
    return ServerResourceFavoriteContains(
      exists: data['exists'] == true,
      folder: data['folder']?.toString(),
    );
  }

  Future<void> addResourceFavorite({
    required String id,
    required String folder,
  }) async {
    final dio = _dio();
    await dio.post('/api/v1/resource-favorites', data: {
      'id': id,
      'folder': folder,
    });
  }

  Future<void> removeResourceFavorite(String id) async {
    final dio = _dio();
    await dio.delete('/api/v1/resource-favorites', data: {'id': id});
  }

  Future<void> moveResourceFavorites({
    required String folder,
    required List<String> ids,
  }) async {
    final dio = _dio();
    await dio.patch('/api/v1/resource-favorites/move', data: {
      'folder': folder,
      'items': ids.map((e) => {'id': e}).toList(),
    });
  }

  Future<void> reorderResourceFavorites({
    required String folder,
    required List<String> ids,
  }) async {
    final dio = _dio();
    await dio.patch('/api/v1/resource-favorites/order', data: {
      'folder': folder,
      'items': ids.map((e) => {'id': e}).toList(),
    });
  }

  Future<List<ServerSubscription>> listSubscriptions() async {
    final dio = _dio();
    final res = await dio.get('/api/v1/subscriptions');
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['subscriptions'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ServerSubscription.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<bool> containsSubscription({
    required String source,
    required String target,
  }) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/subscriptions/contains',
      queryParameters: {'source': source, 'target': target},
    );
    final data = res.data;
    if (data is! Map) return false;
    return data['exists'] == true;
  }

  /// 查询订阅详情（未订阅返回 null）。
  Future<ServerSubscription?> getSubscription({
    required String source,
    required String target,
  }) async {
    final dio = _dio();
    final res = await dio.get(
      '/api/v1/subscriptions/contains',
      queryParameters: {'source': source, 'target': target},
    );
    final data = res.data;
    if (data is! Map || data['exists'] != true) return null;
    final sub = data['subscription'];
    if (sub is! Map) return null;
    return ServerSubscription.fromMap(Map<String, dynamic>.from(sub));
  }

  Future<void> createSubscription({
    required String source,
    required String target,
    required String title,
    required String subtitle,
    required String cover,
    required List<String> tags,
    required bool autoDownload,
    int? intervalMinutes,
  }) async {
    final dio = _dio();
    await dio.post('/api/v1/subscriptions', data: {
      'source': source,
      'target': target,
      'title': title,
      'subtitle': subtitle,
      'cover': cover,
      'tags': tags,
      'level': autoDownload ? 'download' : 'update',
      if (intervalMinutes != null) 'intervalMinutes': intervalMinutes,
    });
  }

  /// 更新订阅；[clearInterval] 为 true 时恢复使用全局默认频率。
  Future<void> updateSubscription({
    required String source,
    required String target,
    bool? autoDownload,
    int? intervalMinutes,
    bool clearInterval = false,
  }) async {
    final dio = _dio();
    await dio.patch('/api/v1/subscriptions', data: {
      'source': source,
      'target': target,
      if (autoDownload != null) 'level': autoDownload ? 'download' : 'update',
      if (clearInterval) 'intervalMinutes': null,
      if (!clearInterval && intervalMinutes != null)
        'intervalMinutes': intervalMinutes,
    });
  }

  Future<void> removeSubscription({
    required String source,
    required String target,
  }) async {
    final dio = _dio();
    await dio.delete('/api/v1/subscriptions', data: {
      'source': source,
      'target': target,
    });
  }

  /// 手动立即检查（同步执行）；返回检查结果。
  Future<ServerSubscriptionCheckResult?> checkSubscriptionNow({
    required String source,
    required String target,
  }) async {
    final dio = _dio();
    final res = await dio.post('/api/v1/subscriptions/check', data: {
      'source': source,
      'target': target,
    });
    final data = res.data;
    if (data is! Map) return null;
    final result = data['result'];
    if (result is! Map) return null;
    return ServerSubscriptionCheckResult.fromMap(
        Map<String, dynamic>.from(result));
  }

  Future<List<ServerSubscriptionCheck>> listSubscriptionHistory({
    required String source,
    required String target,
    int limit = 100,
  }) async {
    final dio = _dio();
    final res = await dio.get('/api/v1/subscriptions/history',
        queryParameters: {
          'source': source,
          'target': target,
          'limit': limit.toString(),
        });
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['checks'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) =>
            ServerSubscriptionCheck.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<ServerSubscriptionDownload>> listSubscriptionDownloads(
      {int limit = 100}) async {
    final dio = _dio();
    final res = await dio.get('/api/v1/subscriptions/downloads',
        queryParameters: {'limit': limit.toString()});
    final data = res.data;
    if (data is! Map) return const [];
    final list = data['downloads'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) =>
            ServerSubscriptionDownload.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<int> getSubscriptionDefaultIntervalMinutes() async {
    final dio = _dio();
    final res = await dio.get('/api/v1/subscriptions/config');
    final data = res.data;
    if (data is! Map) return 0;
    return int.tryParse((data['defaultIntervalMinutes'] ?? '').toString()) ?? 0;
  }

  Future<int> setSubscriptionDefaultIntervalMinutes(int minutes) async {
    final dio = _dio();
    final res = await dio.put('/api/v1/subscriptions/config',
        data: {'defaultIntervalMinutes': minutes});
    final data = res.data;
    if (data is! Map) return minutes;
    return int.tryParse((data['defaultIntervalMinutes'] ?? '').toString()) ??
        minutes;
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

class ServerComic with HistoryMixin {
  final String id;

  @override
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

  @override
  String get target => '$kServerComicPrefix$id';

  @override
  String get cover => coverUrl ?? '';

  @override
  String? get subTitle => subtitle;

  @override
  HistoryType get historyType => HistoryType.picaServer;
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

/// 漫画在服务器资源库中的存在性信息。
class ServerComicPresence {
  final bool exists;

  /// 服务器上的漫画 id（存在时有值）。
  final String? comicId;

  /// 该漫画是否有活跃任务（排队/下载/暂停/上传）。
  final bool active;

  const ServerComicPresence({
    required this.exists,
    this.comicId,
    this.active = false,
  });
}

/// 漫画在服务器上的下载状态。
enum ServerDownloadState {
  /// 无法确定（服务器未配置/查询失败）。
  unknown,

  /// 服务器上没有这本书。
  none,

  /// 服务器上有进行中的任务。
  downloading,

  /// 服务器上有资源但存在缺失的集。
  partial,

  /// 全部集已下载（无分集语义的源=存在即完整）。
  complete,
}

/// 漫画在服务器上的状态（未知时字段为 null）。
class ComicServerStatus {
  final ServerDownloadState downloadState;

  final bool? favorite;

  /// 是否已加入服务器资源收藏。
  final bool? resourceFavorite;

  /// 是否已订阅（服务器自动追更）。
  final bool? subscribed;

  /// 服务器上的漫画 id（已存在时有值）。
  final String? comicId;

  /// 服务器已下载的集下标（0 基；无分集语义时为空）。
  final List<int> downloadedEps;

  const ComicServerStatus({
    this.downloadState = ServerDownloadState.unknown,
    this.favorite,
    this.resourceFavorite,
    this.subscribed,
    this.comicId,
    this.downloadedEps = const [],
  });

  static const unknown = ComicServerStatus();

  ComicServerStatus copyWith({
    ServerDownloadState? downloadState,
    bool? favorite,
    bool? resourceFavorite,
    bool? subscribed,
    String? comicId,
    List<int>? downloadedEps,
  }) {
    return ComicServerStatus(
      downloadState: downloadState ?? this.downloadState,
      favorite: favorite ?? this.favorite,
      resourceFavorite: resourceFavorite ?? this.resourceFavorite,
      subscribed: subscribed ?? this.subscribed,
      comicId: comicId ?? this.comicId,
      downloadedEps: downloadedEps ?? this.downloadedEps,
    );
  }
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

/// 服务器资源收藏的文件夹。
class ServerResourceFavoriteFolder {
  final String name;
  final int? orderValue;

  const ServerResourceFavoriteFolder({required this.name, this.orderValue});

  factory ServerResourceFavoriteFolder.fromMap(Map<String, dynamic> map) {
    return ServerResourceFavoriteFolder(
      name: (map['name'] ?? '').toString(),
      orderValue: int.tryParse((map['orderValue'] ?? '').toString()),
    );
  }
}

/// 漫画在服务器资源收藏中的存在性信息。
class ServerResourceFavoriteContains {
  final bool exists;
  final String? folder;

  const ServerResourceFavoriteContains({required this.exists, this.folder});
}

/// 服务器资源收藏条目（展示信息实时来自服务器漫画库）。
class ServerResourceFavoriteItem {
  final String id;
  final String folder;
  final String title;
  final String subtitle;
  final int type;
  final List<String> tags;
  final String directory;
  final int? time;
  final int? size;
  final String? coverUrl;
  final int? orderValue;
  final int? addedAt;
  final int? updatedAt;

  const ServerResourceFavoriteItem({
    required this.id,
    required this.folder,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.tags,
    required this.directory,
    this.time,
    this.size,
    this.coverUrl,
    this.orderValue,
    this.addedAt,
    this.updatedAt,
  });

  factory ServerResourceFavoriteItem.fromMap(Map<String, dynamic> map) {
    return ServerResourceFavoriteItem(
      id: (map['id'] ?? '').toString(),
      folder: (map['folder'] ?? '').toString(),
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
      orderValue: int.tryParse((map['orderValue'] ?? '').toString()),
      addedAt: int.tryParse((map['addedAt'] ?? '').toString()),
      updatedAt: int.tryParse((map['updatedAt'] ?? '').toString()),
    );
  }
}

/// 服务器漫画订阅。
class ServerSubscription {
  final String source;
  final String target;
  final String title;
  final String subtitle;
  final String cover;
  final List<String> tags;

  /// 'update'（仅订阅更新）或 'download'（订阅+下载）。
  final String level;
  final int? intervalMinutes;
  final int effectiveIntervalMinutes;
  final bool enabled;
  final int? lastCheckAt;
  final int? nextCheckAt;
  final String? lastError;
  final int? lastUpdatedAt;
  final int? createdAt;
  final int? updatedAt;

  const ServerSubscription({
    required this.source,
    required this.target,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.tags,
    required this.level,
    required this.effectiveIntervalMinutes,
    required this.enabled,
    this.intervalMinutes,
    this.lastCheckAt,
    this.nextCheckAt,
    this.lastError,
    this.lastUpdatedAt,
    this.createdAt,
    this.updatedAt,
  });

  bool get autoDownload => level == 'download';

  factory ServerSubscription.fromMap(Map<String, dynamic> map) {
    return ServerSubscription(
      source: (map['source'] ?? '').toString(),
      target: (map['target'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      subtitle: (map['subtitle'] ?? '').toString(),
      cover: (map['cover'] ?? '').toString(),
      tags: (map['tags'] is List)
          ? List<String>.from((map['tags'] as List).map((e) => e.toString()))
          : const [],
      level: (map['level'] ?? 'update').toString(),
      intervalMinutes: int.tryParse((map['intervalMinutes'] ?? '').toString()),
      effectiveIntervalMinutes:
          int.tryParse((map['effectiveIntervalMinutes'] ?? '').toString()) ?? 0,
      enabled: map['enabled'] != false,
      lastCheckAt: int.tryParse((map['lastCheckAt'] ?? '').toString()),
      nextCheckAt: int.tryParse((map['nextCheckAt'] ?? '').toString()),
      lastError: map['lastError']?.toString(),
      lastUpdatedAt: int.tryParse((map['lastUpdatedAt'] ?? '').toString()),
      createdAt: int.tryParse((map['createdAt'] ?? '').toString()),
      updatedAt: int.tryParse((map['updatedAt'] ?? '').toString()),
    );
  }
}

/// 订阅更新历史记录（发现更新或检查失败）。
class ServerSubscriptionCheck {
  final int? checkedAt;

  /// 'updated' | 'failed'
  final String status;
  final String? message;
  final List<String> newItems;
  final int? totalItems;

  const ServerSubscriptionCheck({
    this.checkedAt,
    required this.status,
    this.message,
    this.newItems = const [],
    this.totalItems,
  });

  factory ServerSubscriptionCheck.fromMap(Map<String, dynamic> map) {
    return ServerSubscriptionCheck(
      checkedAt: int.tryParse((map['checkedAt'] ?? '').toString()),
      status: (map['status'] ?? '').toString(),
      message: map['message']?.toString(),
      newItems: (map['newItems'] is List)
          ? List<String>.from(
              (map['newItems'] as List).map((e) => e.toString()))
          : const [],
      totalItems: int.tryParse((map['totalItems'] ?? '').toString()),
    );
  }
}

/// 手动立即检查的结果。
class ServerSubscriptionCheckResult {
  /// 'updated' | 'none' | 'failed' | 'busy'
  final String status;
  final List<String> newItems;
  final int? totalItems;
  final String? latestItem;

  /// 最近更新的一话及更新时间（倒序，最新在前；非分集源为空）。
  final List<ServerSubscriptionRecentItem> recentItems;
  final bool firstCheck;
  final String? message;
  final int? checkedAt;

  const ServerSubscriptionCheckResult({
    required this.status,
    this.newItems = const [],
    this.totalItems,
    this.latestItem,
    this.recentItems = const [],
    this.firstCheck = false,
    this.message,
    this.checkedAt,
  });

  factory ServerSubscriptionCheckResult.fromMap(Map<String, dynamic> map) {
    return ServerSubscriptionCheckResult(
      status: (map['status'] ?? '').toString(),
      newItems: (map['newItems'] is List)
          ? List<String>.from(
              (map['newItems'] as List).map((e) => e.toString()))
          : const [],
      totalItems: int.tryParse((map['totalItems'] ?? '').toString()),
      latestItem: map['latestItem']?.toString(),
      recentItems: (map['recentItems'] is List)
          ? (map['recentItems'] as List)
              .whereType<Map>()
              .map((e) => ServerSubscriptionRecentItem.fromMap(
                  Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      firstCheck: map['firstCheck'] == true,
      message: map['message']?.toString(),
      checkedAt: int.tryParse((map['checkedAt'] ?? '').toString()),
    );
  }
}

/// 最近更新的一话（名称 + 源站更新时间）。
class ServerSubscriptionRecentItem {
  final String name;
  final int? updatedAt;

  const ServerSubscriptionRecentItem({required this.name, this.updatedAt});

  factory ServerSubscriptionRecentItem.fromMap(Map<String, dynamic> map) {
    return ServerSubscriptionRecentItem(
      name: (map['name'] ?? '').toString(),
      updatedAt: int.tryParse((map['updatedAt'] ?? '').toString()),
    );
  }
}

/// 订阅自动下载历史记录。
class ServerSubscriptionDownload {
  final int? id;
  final String source;
  final String target;
  final String? taskId;
  final String title;
  final String subtitle;
  final String cover;
  final List<String> newItems;
  final String status;
  final String? message;
  final int? progress;
  final int? total;
  final int? createdAt;
  final int? updatedAt;

  const ServerSubscriptionDownload({
    this.id,
    required this.source,
    required this.target,
    this.taskId,
    required this.title,
    required this.subtitle,
    required this.cover,
    this.newItems = const [],
    required this.status,
    this.message,
    this.progress,
    this.total,
    this.createdAt,
    this.updatedAt,
  });

  factory ServerSubscriptionDownload.fromMap(Map<String, dynamic> map) {
    return ServerSubscriptionDownload(
      id: int.tryParse((map['id'] ?? '').toString()),
      source: (map['source'] ?? '').toString(),
      target: (map['target'] ?? '').toString(),
      taskId: map['taskId']?.toString(),
      title: (map['title'] ?? '').toString(),
      subtitle: (map['subtitle'] ?? '').toString(),
      cover: (map['cover'] ?? '').toString(),
      newItems: (map['newItems'] is List)
          ? List<String>.from(
              (map['newItems'] as List).map((e) => e.toString()))
          : const [],
      status: (map['status'] ?? '').toString(),
      message: map['message']?.toString(),
      progress: int.tryParse((map['progress'] ?? '').toString()),
      total: int.tryParse((map['total'] ?? '').toString()),
      createdAt: int.tryParse((map['createdAt'] ?? '').toString()),
      updatedAt: int.tryParse((map['updatedAt'] ?? '').toString()),
    );
  }
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
      params: map['params'] is Map
          ? Map<String, dynamic>.from(map['params'])
          : null,
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
