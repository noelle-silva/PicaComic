import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/local_comic_upload.dart';
import 'package:pica_comic/tools/translations.dart';

/// 本地文件夹漫画上传：选择文件夹（支持多选）→ 逐本选封面/填信息 → 上传到服务器。
///
/// 多本时可通过「上一本 / 下一本」切换编辑，可单本上传，或点击右上角「全部上传」；
/// 提交后立即出队（不阻塞界面），由后台上传队列按服务器「并行上传数」并行处理。
class UploadLocalComicPage extends StatefulWidget {
  const UploadLocalComicPage({super.key});

  @override
  State<UploadLocalComicPage> createState() => _UploadLocalComicPageState();
}

class _UploadLocalComicPageState extends State<UploadLocalComicPage> {
  final titleController = TextEditingController();
  final subtitleController = TextEditingController();
  final tagsController = TextEditingController();

  final _drafts = <LocalComicDraft>[];
  int _currentIndex = 0;

  bool scanning = false;

  LocalComicDraft? get _currentDraft =>
      _drafts.isEmpty ? null : _drafts[_currentIndex];

  @override
  void dispose() {
    titleController.dispose();
    subtitleController.dispose();
    tagsController.dispose();
    super.dispose();
  }

  /// 选择（或追加）文件夹：支持一次多选，跳过已在队列中的文件夹。
  Future<void> pickFolders() async {
    if (scanning) return;
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    final paths = await pickLocalComicFolders();
    if (paths.isEmpty || !mounted) return;
    setState(() => scanning = true);
    final added = <LocalComicDraft>[];
    var skipped = 0;
    for (final path in paths) {
      if (_drafts.any((d) => d.folderPath == path)) {
        skipped++;
        continue;
      }
      try {
        added.add(await createLocalComicDraft(path));
      } on LocalComicException {
        skipped++;
      } catch (_) {
        skipped++;
      }
    }
    if (!mounted) return;
    final wasEmpty = _drafts.isEmpty;
    setState(() {
      scanning = false;
      _drafts.addAll(added);
      if (wasEmpty && _drafts.isNotEmpty) {
        _currentIndex = 0;
      }
    });
    if (added.isEmpty) {
      showToast(message: "未找到图片".tl);
    } else if (skipped > 0) {
      showToast(
        message: "已添加 @a 本，跳过 @b 个文件夹".tlParams({
          "a": added.length.toString(),
          "b": skipped.toString(),
        }),
      );
    }
    if (wasEmpty && _drafts.isNotEmpty) {
      _syncForm();
    }
  }

  /// 把表单内容写回草稿。
  void _collectForm(LocalComicDraft draft) {
    draft.title = titleController.text.trim();
    draft.subtitle = subtitleController.text.trim();
    draft.tags = tagsController.text
        .split(RegExp(r'[,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 用当前草稿内容填充表单；队列为空时清空表单。
  void _syncForm() {
    if (!mounted) return;
    final draft = _currentDraft;
    if (draft == null) {
      titleController.clear();
      subtitleController.clear();
      tagsController.clear();
      return;
    }
    titleController.text = draft.title;
    subtitleController.text = draft.subtitle;
    tagsController.text = draft.tags.join(', ');
  }

  void goPrevious() {
    if (_currentIndex <= 0) return;
    _collectForm(_currentDraft!);
    setState(() => _currentIndex--);
    _syncForm();
  }

  void goNext() {
    if (_currentIndex >= _drafts.length - 1) return;
    _collectForm(_currentDraft!);
    setState(() => _currentIndex++);
    _syncForm();
  }

  void removeCurrent() {
    if (_drafts.isEmpty) return;
    _removeDraft(_drafts[_currentIndex]);
    setState(() {});
    _syncForm();
  }

  /// 从队列移除一本并修正当前下标（纯数据操作，不触发重建）。
  void _removeDraft(LocalComicDraft draft) {
    final index = _drafts.indexOf(draft);
    if (index < 0) return;
    _drafts.removeAt(index);
    if (_drafts.isEmpty) {
      _currentIndex = 0;
    } else if (_currentIndex >= _drafts.length) {
      _currentIndex = _drafts.length - 1;
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
  }

  /// 单本上传：提交当前编辑中的这本到后台上传队列（立即出队，不阻塞界面）。
  void uploadCurrent() {
    final draft = _currentDraft;
    if (draft == null) return;
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    _collectForm(draft);
    if (draft.title.isEmpty) {
      showToast(message: "请填写标题".tl);
      return;
    }
    LocalComicUploadQueue.instance.submit(draft);
    setState(() => _removeDraft(draft));
    _syncForm();
    showToast(message: "《@a》已加入上传队列".tlParams({"a": draft.title}));
  }

  /// 全部上传：提交队列中所有本到后台上传队列（立即清空，不阻塞界面）。
  void uploadAll() {
    if (_drafts.length <= 1) return;
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    _collectForm(_currentDraft!);
    final count = _drafts.length;
    final drafts = List<LocalComicDraft>.of(_drafts);
    for (final draft in drafts) {
      LocalComicUploadQueue.instance.submit(draft);
    }
    setState(() {
      _drafts.clear();
      _currentIndex = 0;
    });
    _syncForm();
    showToast(message: "已加入上传队列（@a 本）".tlParams({"a": count.toString()}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("上传本地漫画".tl),
        actions: [
          if (_drafts.length > 1)
            TextButton.icon(
              onPressed: uploadAll,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: Text("全部上传".tl),
            ),
        ],
      ),
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (scanning) {
      return const Center(child: CircularProgressIndicator());
    }
    final draft = _currentDraft;
    if (draft == null) {
      return buildEmpty();
    }
    return buildQueue(draft);
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
            "一个文件夹 = 一本漫画，图片平铺在文件夹内（支持多选）".tl,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: pickFolders,
            icon: const Icon(Icons.folder_open),
            label: Text("选择文件夹".tl),
          ),
        ],
      ),
    );
  }

  Widget buildQueue(LocalComicDraft draft) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_drafts.length > 1) ...[
          buildQueueNav(),
          const SizedBox(height: 12),
        ],
        buildFolderCard(draft),
        const SizedBox(height: 16),
        Text("选择封面".tl),
        const SizedBox(height: 8),
        buildCoverGrid(draft),
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

  Widget buildQueueNav() {
    return Row(
      children: [
        IconButton(
          onPressed: _currentIndex <= 0 ? null : goPrevious,
          icon: const Icon(Icons.chevron_left),
          tooltip: "上一本".tl,
        ),
        Expanded(
          child: Text(
            "第 @a / 共 @b 本".tlParams({
              "a": (_currentIndex + 1).toString(),
              "b": _drafts.length.toString(),
            }),
            textAlign: TextAlign.center,
          ),
        ),
        IconButton(
          onPressed: _currentIndex >= _drafts.length - 1 ? null : goNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: "下一本".tl,
        ),
      ],
    );
  }

  Widget buildFolderCard(LocalComicDraft draft) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.folder_open),
        title: Text(
          draft.folderPath,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle:
            Text("共 @a 张图片".tlParams({"a": draft.images.length.toString()})),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: pickFolders,
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: "添加文件夹".tl,
            ),
            IconButton(
              onPressed: removeCurrent,
              icon: const Icon(Icons.delete_outline),
              tooltip: "移除这本".tl,
            ),
          ],
        ),
      ),
    );
  }

  Widget buildCoverGrid(LocalComicDraft draft) {
    return SizedBox(
      height: 280,
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 96,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
        ),
        itemCount: draft.images.length,
        itemBuilder: (context, index) {
          final selected = draft.coverIndex == index;
          final color = Theme.of(context).colorScheme.primary;
          return GestureDetector(
            onTap: () {
              setState(() {
                draft.coverIndex = index;
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
                    draft.images[index],
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
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        label: Text("标题".tl),
      ),
    );
  }

  Widget buildSubtitleField() {
    return TextField(
      controller: subtitleController,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        label: Text("副标题/作者".tl),
      ),
    );
  }

  Widget buildTagsField() {
    return TextField(
      controller: tagsController,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        label: Text("标签".tl),
        hintText: "多个标签用逗号分隔".tl,
      ),
    );
  }

  Widget buildUploadButton() {
    return FilledButton.icon(
      onPressed: uploadCurrent,
      icon: const Icon(Icons.cloud_upload),
      label: Text(_drafts.length > 1 ? "上传这一本".tl : "上传到服务器".tl),
    );
  }
}
