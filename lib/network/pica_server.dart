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
