import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/local_comic_upload.dart';
import 'package:pica_comic/tools/translations.dart';

/// 本地文件夹漫画上传：选择文件夹 → 选封面/填信息 → 规约化打包上传到服务器。
///
/// 一次处理一本，上传完成后可继续选择下一本。
class UploadLocalComicPage extends StatefulWidget {
  const UploadLocalComicPage({super.key});

  @override
  State<UploadLocalComicPage> createState() => _UploadLocalComicPageState();
}

class _UploadLocalComicPageState extends State<UploadLocalComicPage> {
  final titleController = TextEditingController();
  final subtitleController = TextEditingController();
  final tagsController = TextEditingController();

  LocalComicDraft? draft;
  bool scanning = false;
  bool uploading = false;
  String? stageText;

  @override
  void dispose() {
    titleController.dispose();
    subtitleController.dispose();
    tagsController.dispose();
    super.dispose();
  }

  Future<void> pickFolder() async {
    if (uploading) return;
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    final path = await pickLocalComicFolder();
    if (path == null || !mounted) return;
    setState(() => scanning = true);
    try {
      final result = await createLocalComicDraft(path);
      if (!mounted) return;
      titleController.text = result.title;
      subtitleController.clear();
      tagsController.clear();
      setState(() {
        draft = result;
        scanning = false;
      });
    } on LocalComicException catch (e) {
      if (!mounted) return;
      setState(() => scanning = false);
      showToast(message: e.message.tl);
    } catch (e) {
      if (!mounted) return;
      setState(() => scanning = false);
      showToast(message: "扫描失败".tl);
    }
  }

  Future<void> upload() async {
    final d = draft;
    if (d == null || uploading) return;
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    final title = titleController.text.trim();
    if (title.isEmpty) {
      showToast(message: "请填写标题".tl);
      return;
    }
    d.title = title;
    d.subtitle = subtitleController.text.trim();
    d.tags = tagsController.text
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    setState(() {
      uploading = true;
      stageText = "正在打包".tl;
    });
    try {
      await uploadLocalComicDraft(d, onStage: (stage) {
        if (!mounted) return;
        setState(() {
          stageText = stage == LocalComicUploadStage.packing
              ? "正在打包".tl
              : "正在上传".tl;
        });
      });
      showToast(message: "已创建上传任务".tl);
      if (!mounted) return;
      titleController.clear();
      subtitleController.clear();
      tagsController.clear();
      setState(() {
        uploading = false;
        stageText = null;
        draft = null;
      });
    } catch (e) {
      showToast(message: "${"上传失败".tl}: $e");
      if (!mounted) return;
      setState(() {
        uploading = false;
        stageText = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("上传本地漫画".tl),
      ),
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (scanning) {
      return const Center(child: CircularProgressIndicator());
    }
    final d = draft;
    if (d == null) {
      return buildEmpty();
    }
    return buildDraft(d);
  }

  Widget buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_open, size: 64),
          const SizedBox(height: 16),
          Text("选择漫画文件夹上传到服务器".tl),
          const SizedBox(height: 4),
          Text(
            "一个文件夹 = 一本漫画，图片平铺在文件夹内".tl,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: pickFolder,
            icon: const Icon(Icons.folder_open),
            label: Text("选择文件夹".tl),
          ),
        ],
      ),
    );
  }

  Widget buildDraft(LocalComicDraft d) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        buildFolderCard(d),
        const SizedBox(height: 16),
        Text("选择封面".tl),
        const SizedBox(height: 8),
        buildCoverGrid(d),
        const SizedBox(height: 16),
        buildTitleField(),
        const SizedBox(height: 12),
        buildSubtitleField(),
        const SizedBox(height: 12),
        buildTagsField(),
        const SizedBox(height: 20),
        buildUploadButton(),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget buildFolderCard(LocalComicDraft d) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.folder_open),
        title: Text(
          d.folderPath,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text("共 @a 张图片".tlParams({"a": d.images.length.toString()})),
        trailing: TextButton(
          onPressed: uploading ? null : pickFolder,
          child: Text("重新选择".tl),
        ),
      ),
    );
  }

  Widget buildCoverGrid(LocalComicDraft d) {
    return SizedBox(
      height: 280,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 96,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
        ),
        itemCount: d.images.length,
        itemBuilder: (context, index) {
          final selected = d.coverIndex == index;
          final color = Theme.of(context).colorScheme.primary;
          return GestureDetector(
            onTap: uploading
                ? null
                : () {
                    setState(() {
                      d.coverIndex = index;
                    });
                  },
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? color : Colors.transparent,
                  width: 3,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    d.images[index],
                    fit: BoxFit.cover,
                    cacheWidth: 192,
                    errorBuilder: (context, error, stackTrace) =>
                        const ColoredBox(
                      color: Colors.black12,
                      child: Icon(Icons.broken_image),
                    ),
                  ),
                  if (selected)
                    Align(
                      alignment: Alignment.topRight,
                      child: Icon(
                        Icons.check_circle,
                        size: 18,
                        color: color,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget buildTitleField() {
    return TextField(
      controller: titleController,
      enabled: !uploading,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        label: Text("标题".tl),
      ),
    );
  }

  Widget buildSubtitleField() {
    return TextField(
      controller: subtitleController,
      enabled: !uploading,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        label: Text("副标题/作者".tl),
      ),
    );
  }

  Widget buildTagsField() {
    return TextField(
      controller: tagsController,
      enabled: !uploading,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        label: Text("标签".tl),
        hintText: "多个标签用逗号分隔".tl,
      ),
    );
  }

  Widget buildUploadButton() {
    return FilledButton.icon(
      onPressed: uploading ? null : upload,
      icon: uploading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.cloud_upload),
      label: Text(uploading ? (stageText ?? "上传中".tl) : "上传到服务器".tl),
    );
  }
}
