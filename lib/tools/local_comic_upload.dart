import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/io_extensions.dart';
import 'package:zip_flutter/zip_flutter.dart';

/// 本地文件夹漫画上传：扫描、规约化打包、构造元数据并发起服务器上传。
///
/// 与服务器读取规约的对应关系（事实源，详见任务 021 design.md）：
/// - zip 条目为 `1/<n>.<ext>`：单集语义，服务器按 `pages/1/` 读取；
/// - meta.type = other(6) 且 json.chapters 为 Map → 服务器判定有分集；
/// - id 形如 `picacg-<hash>`：含 `-` 使客户端从服务器下载回本地时
///   还原为 Custom 模型，并满足阅读链路对内置源 key 的查找。
class LocalComicDraft {
  LocalComicDraft({
    required this.folderPath,
    required this.images,
    required this.title,
    this.subtitle = '',
    this.tags = const [],
    this.coverIndex = 0,
  });

  /// 源文件夹绝对路径。
  final String folderPath;

  /// 自然排序后的图片文件。
  final List<File> images;

  /// 标题（默认文件夹名，界面可编辑）。
  String title;

  String subtitle;

  List<String> tags;

  /// 封面在 [images] 中的下标。
  int coverIndex;

  /// 路径派生的稳定标识（同一文件夹重复上传视为同一本）。
  String get comicId =>
      sha1.convert(utf8.encode(folderPath)).toString().substring(0, 16);

  /// 上传 id；`picacg-` 前缀为客户端模型分派的必要契约（见类注释）。
  String get id => 'picacg-$comicId';

  File get coverFile => images[coverIndex];

  /// 下载到客户端时的目录名。
  String get directory => sanitizeFileName(title);
}

enum LocalComicUploadStage { packing, uploading }

class LocalComicException implements Exception {
  const LocalComicException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

/// 打开系统目录选择器；用户取消时返回 null（仅桌面端可用）。
Future<String?> pickLocalComicFolder() => getDirectoryPath();

/// 扫描文件夹第一层的图片并建立草稿；没有图片时抛 [LocalComicException]。
Future<LocalComicDraft> createLocalComicDraft(String folderPath) async {
  final dir = Directory(folderPath);
  if (!dir.existsSync()) {
    throw const LocalComicException('文件夹不存在');
  }
  final images = dir
      .listSync()
      .whereType<File>()
      .where(_isImageFile)
      .toList()
    ..sort((a, b) => _compareNatural(_baseName(a.path), _baseName(b.path)));
  if (images.isEmpty) {
    throw const LocalComicException('未找到图片');
  }
  return LocalComicDraft(
    folderPath: folderPath,
    images: images,
    title: _baseName(folderPath),
  );
}

/// 规约化打包并上传草稿；返回服务器任务 id。
Future<String> uploadLocalComicDraft(
  LocalComicDraft draft, {
  void Function(LocalComicUploadStage stage)? onStage,
}) async {
  if (draft.title.trim().isEmpty) {
    throw const LocalComicException('标题不能为空');
  }
  final temp = await getTemporaryDirectory();
  final zipPath = '${temp.path}${pathSep}local_comic_${draft.comicId}.zip';
  final zipFile = File(zipPath);
  if (zipFile.existsSync()) {
    zipFile.deleteSync();
  }
  try {
    onStage?.call(LocalComicUploadStage.packing);
    final sizeMb = await _packLocalComic(draft, zipPath);
    onStage?.call(LocalComicUploadStage.uploading);
    return await PicaServer.instance.uploadComicArchive(
      id: draft.id,
      title: draft.title,
      subtitle: draft.subtitle,
      type: DownloadType.other.index,
      tags: draft.tags,
      directory: draft.directory,
      json: _buildDownloadedJson(draft, sizeMb),
      zipPath: zipPath,
      coverPath: draft.coverFile.path,
    );
  } finally {
    try {
      if (zipFile.existsSync()) {
        zipFile.deleteSync();
      }
    } catch (_) {
      // ignore
    }
  }
}

/// 在 Isolate 中把图片按 `1/<n>.<ext>` 规约化写入 zip；返回总大小（MB）。
Future<double> _packLocalComic(LocalComicDraft draft, String zipPath) async {
  final entries = <List<String>>[];
  for (var i = 0; i < draft.images.length; i++) {
    final path = draft.images[i].path;
    entries.add([path, '1/$i${_extensionOf(_baseName(path))}']);
  }
  final totalBytes = await Isolate.run(() {
    var total = 0;
    final zip = ZipFile.open(zipPath);
    try {
      for (final entry in entries) {
        final file = File(entry[0]);
        total += file.lengthSync();
        if (Platform.isWindows) {
          zip.addFileFromBytes(entry[1], file.readAsBytesSync());
        } else {
          zip.addFile(entry[1], file.path);
        }
      }
    } finally {
      zip.close();
    }
    return total;
  });
  return totalBytes / 1024 / 1024;
}

/// 构造服务器 meta.json：采用 CustomDownloadedItem 结构（下载回本地与
/// 阅读链路的还原契约），chapters 为 Map 使服务器按单集处理。
Map<String, dynamic> _buildDownloadedJson(
  LocalComicDraft draft,
  double sizeMb,
) {
  return {
    'comicSize': sizeMb,
    'downloadedEps': [0],
    'chapters': {'0': '全一话'},
    'id': draft.id,
    'name': draft.title,
    'subTitle': draft.subtitle,
    'tags': draft.tags,
    'sourceKey': 'picacg',
    'sourceName': '本地导入',
    'cover': PicaServer.instance.comicCoverUrl(draft.id),
    'comicId': draft.comicId,
  };
}

bool _isImageFile(File file) {
  final name = _baseName(file.path);
  if (name.startsWith('.')) {
    return false;
  }
  final ext = _extensionOf(name);
  return ext.isNotEmpty && _imageExtensions.contains(ext.toLowerCase());
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

String _baseName(String path) {
  final index = path.lastIndexOf(RegExp(r'[/\\]'));
  return index < 0 ? path : path.substring(index + 1);
}

/// 自然排序：数字块按数值比较（`1 (2)` 排在 `1 (10)` 之前）。
int _compareNatural(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);
    if (_isDigit(ca) && _isDigit(cb)) {
      var ni = i;
      while (ni < a.length && _isDigit(a.codeUnitAt(ni))) {
        ni++;
      }
      var nj = j;
      while (nj < b.length && _isDigit(b.codeUnitAt(nj))) {
        nj++;
      }
      final na = BigInt.parse(a.substring(i, ni));
      final nb = BigInt.parse(b.substring(j, nj));
      if (na != nb) {
        return na.compareTo(nb);
      }
      if (ni - i != nj - j) {
        return (ni - i).compareTo(nj - j);
      }
      i = ni;
      j = nj;
    } else {
      final la = String.fromCharCode(ca).toLowerCase();
      final lb = String.fromCharCode(cb).toLowerCase();
      if (la != lb) {
        return la.compareTo(lb);
      }
      i++;
      j++;
    }
  }
  return (a.length - i).compareTo(b.length - j);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
