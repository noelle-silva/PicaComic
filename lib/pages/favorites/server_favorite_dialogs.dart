import 'package:flutter/material.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/translations.dart';

/// 选择收藏夹对话框中"创建收藏夹"的哨兵值。
const _kCreateFolderSentinel = '__create__';

/// 服务器收藏文件夹名称输入对话框；返回去空格后的名称，取消返回 null。
Future<String?> promptServerFavoriteFolderName(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  final controller = TextEditingController(text: initial ?? '');
  final focusNode = FocusNode()..requestFocus();
  final res = await showDialog<String>(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: Text(title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: "名称".tl,
              ),
              onEditingComplete: () {
                final v = controller.text.trim();
                Navigator.of(context).pop(v.isEmpty ? null : v);
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: Center(
              child: FilledButton(
                onPressed: () {
                  final v = controller.text.trim();
                  Navigator.of(context).pop(v.isEmpty ? null : v);
                },
                child: Text("提交".tl),
              ),
            ),
          ),
        ],
      );
    },
  );
  focusNode.dispose();
  controller.dispose();
  return res?.trim();
}

/// 选择服务器收藏夹（含新建）。
///
/// [loadFolders] 返回现有文件夹名，[createFolder] 创建新文件夹。
/// 返回选中的（或新建的）文件夹名；取消返回 null。
Future<String?> pickServerFavoriteFolder(
  BuildContext context, {
  required Future<List<String>> Function() loadFolders,
  required Future<void> Function(String name) createFolder,
}) async {
  final folders =
      (await loadFolders()).where((e) => e.trim().isNotEmpty).toList();

  if (!context.mounted) return null;
  final picked = await showDialog<String>(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: Text("选择收藏夹".tl),
        children: [
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text("暂无收藏夹".tl),
            ),
          for (final name in folders)
            ListTile(
              title: Text(name),
              onTap: () => Navigator.of(context).pop(name),
            ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: Text("创建收藏夹".tl),
            onTap: () => Navigator.of(context).pop(_kCreateFolderSentinel),
          ),
        ],
      );
    },
  );

  if (picked == null || !context.mounted) return null;
  if (picked != _kCreateFolderSentinel) return picked;

  final name = await promptServerFavoriteFolderName(context, title: "创建收藏夹");
  if (name == null || name.isEmpty || !context.mounted) return null;
  await createFolder(name);
  return name;
}

/// 从给定文件夹名中单选；取消返回 null。
Future<String?> pickFolderFromNames(
  BuildContext context, {
  required List<String> names,
  required String title,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: Text(title),
        children: [
          for (final name in names)
            ListTile(
              title: Text(name),
              onTap: () => Navigator.of(context).pop(name),
            ),
        ],
      );
    },
  );
}

/// 选择服务器资源收藏夹（含新建）；返回选中的文件夹名，取消返回 null。
Future<String?> pickServerResourceFavoriteFolder(BuildContext context) {
  return pickServerFavoriteFolder(
    context,
    loadFolders: () async =>
        (await PicaServer.instance.listResourceFavoriteFolders())
            .map((e) => e.name)
            .toList(),
    createFolder: (name) =>
        PicaServer.instance.createResourceFavoriteFolder(name),
  );
}
