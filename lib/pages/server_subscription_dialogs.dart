import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/tools/translations.dart';

/// 订阅编辑对话框的结果。
class SubscriptionEditResult {
  /// true = 取消订阅；false = 保存设置。
  final bool remove;
  final bool autoDownload;
  final int? intervalMinutes;

  const SubscriptionEditResult.save({
    required this.autoDownload,
    required this.intervalMinutes,
  }) : remove = false;

  const SubscriptionEditResult.remove()
      : remove = true,
        autoDownload = true,
        intervalMinutes = null;
}

const _presetIntervals = <int?>[null, 360, 720, 1440, 4320, 10080];

/// 检查频率文案：跟随默认 / N天 / N小时 / N分钟。
String subscriptionIntervalLabel(int? minutes) {
  if (minutes == null) return "跟随默认".tl;
  if (minutes % 1440 == 0) return "${minutes ~/ 1440}天".tl;
  if (minutes % 60 == 0) return "${minutes ~/ 60}小时".tl;
  return "$minutes分钟".tl;
}

/// 订阅设置对话框（详情页 / 订阅管理页共用）；取消返回 null。
///
/// [allowRemove] 为 true 时显示"取消订阅"入口。
Future<SubscriptionEditResult?> showSubscriptionEditDialog(
  BuildContext context, {
  required bool autoDownload,
  required int? intervalMinutes,
  bool allowRemove = false,
}) async {
  var levelIndex = autoDownload ? 1 : 0;
  final intervalOptions = <int?>[..._presetIntervals];
  if (intervalMinutes != null && !intervalOptions.contains(intervalMinutes)) {
    intervalOptions.insert(1, intervalMinutes);
  }
  var intervalIndex = intervalOptions.indexOf(intervalMinutes);
  if (intervalIndex < 0) intervalIndex = 0;

  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          title: Text("订阅设置".tl),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text("订阅级别".tl),
                  const Spacer(),
                  Select(
                    outline: true,
                    width: 190,
                    values: ["仅订阅更新".tl, "订阅 + 下载".tl],
                    initialValue: levelIndex,
                    onChange: (i) => setState(() => levelIndex = i),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text("检查频率".tl),
                  const Spacer(),
                  Select(
                    outline: true,
                    width: 190,
                    values: intervalOptions.map(subscriptionIntervalLabel).toList(),
                    initialValue: intervalIndex,
                    onChange: (i) => setState(() => intervalIndex = i),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                "仅订阅更新：发现更新只记录；订阅 + 下载：发现更新自动下载。".tl,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            if (allowRemove)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop('remove'),
                child: Text(
                  "取消订阅".tl,
                  style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text("取消".tl),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('save'),
              child: Text("保存".tl),
            ),
          ],
        );
      });
    },
  );
  if (action == null) return null;
  if (action == 'remove') return const SubscriptionEditResult.remove();
  return SubscriptionEditResult.save(
    autoDownload: levelIndex == 1,
    intervalMinutes: intervalOptions[intervalIndex],
  );
}
