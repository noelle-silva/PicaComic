part of pica_settings;

/// 服务器设置：私人服务器全部配置的统一入口。
///
/// 后续新增的服务器配置都在此页面扩展。
class ServerSettings extends StatefulWidget {
  const ServerSettings({super.key});

  @override
  State<ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<ServerSettings> {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _uploadTimeoutMinutesController;

  bool _testing = false;
  bool _loadingConcurrent = false;
  int? _maxConcurrent;

  @override
  void initState() {
    super.initState();
    final url = (appdata.settings.elementAtOrNull(90) ?? '').trim();
    final apiKey = (appdata.implicitData.elementAtOrNull(4) ?? '').trim();
    final uploadSeconds =
        int.tryParse((appdata.settings.elementAtOrNull(92) ?? '1800').trim()) ??
            1800;
    final uploadMinutes = (uploadSeconds / 60).round().clamp(1, 24 * 60);

    _urlController = TextEditingController(text: url);
    _apiKeyController = TextEditingController(text: apiKey);
    _uploadTimeoutMinutesController =
        TextEditingController(text: uploadMinutes.toString());

    _loadConcurrent();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    _uploadTimeoutMinutesController.dispose();
    super.dispose();
  }

  String _normalizeUrl(String input) {
    var v = input.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  Future<bool> _testConnection() async {
    final base = _normalizeUrl(_urlController.text);
    if (base.isEmpty) return false;
    final apiKey = _apiKeyController.text.trim();
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: base,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          headers: apiKey.isEmpty ? null : {'X-Api-Key': apiKey},
        ),
      );
      final res = await dio.get('/api/v1/health');
      if (res.statusCode != 200) return false;
      if (res.data is Map) return res.data['ok'] == true;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _save() {
    final normalizedUrl = _normalizeUrl(_urlController.text);
    final apiKey = _apiKeyController.text.trim();
    final minutes =
        int.tryParse(_uploadTimeoutMinutesController.text.trim()) ?? 30;
    final clampedMinutes = minutes.clamp(1, 24 * 60);

    appdata.settings[90] = normalizedUrl;
    appdata.settings[92] = (clampedMinutes * 60).toString();
    if (appdata.implicitData.length >= 5) {
      appdata.implicitData[4] = apiKey;
    }
    appdata.updateSettings(false);
    appdata.writeImplicitData();

    showToast(message: "已保存".tl);
    _loadConcurrent();
  }

  /// 读取服务器端的下载并发配置（服务器未配置时清空显示）。
  Future<void> _loadConcurrent() async {
    if (!PicaServer.instance.enabled) {
      if (mounted) {
        setState(() {
          _maxConcurrent = null;
          _loadingConcurrent = false;
        });
      }
      return;
    }
    setState(() => _loadingConcurrent = true);
    try {
      final value = await PicaServer.instance.getMaxConcurrent();
      if (mounted) setState(() => _maxConcurrent = value);
    } catch (_) {
      if (mounted) setState(() => _maxConcurrent = null);
    } finally {
      if (mounted) setState(() => _loadingConcurrent = false);
    }
  }

  Future<void> _editConcurrency() async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    if (_maxConcurrent == null) {
      await _loadConcurrent();
      if (!mounted) return;
    }
    if (_maxConcurrent == null) {
      showToast(message: "无法获取服务器配置".tl);
      return;
    }

    var value = _maxConcurrent!.clamp(1, 20);
    final controller = TextEditingController(text: value.toString());

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text("下载并发".tl),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () {
                  value = (value - 1).clamp(1, 20);
                  controller.text = value.toString();
                },
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                onPressed: () {
                  value = (value + 1).clamp(1, 20);
                  controller.text = value.toString();
                },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text("取消".tl),
            ),
            FilledButton(
              onPressed: () async {
                final parsed = int.tryParse(controller.text) ?? value;
                value = parsed.clamp(1, 20);
                if (!mounted) return;
                final dialog = showLoadingDialog(
                  context,
                  barrierDismissible: false,
                  allowCancel: false,
                  message: "设置中".tl,
                );
                try {
                  final nav = Navigator.of(dialogContext);
                  final newV =
                      await PicaServer.instance.setMaxConcurrent(value);
                  dialog.close();
                  if (!mounted) return;
                  setState(() {
                    _maxConcurrent = newV;
                  });
                  if (dialogContext.mounted) {
                    nav.pop();
                  }
                  showToast(message: "${"已设置并发".tl}: $newV");
                } catch (e) {
                  dialog.close();
                  showToast(message: e.toString());
                }
              },
              child: Text("确定".tl),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  label: Text("URL".tl),
                  hintText: "http://192.168.1.10:8080".tl,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  label: Text("API Key".tl),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _uploadTimeoutMinutesController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  label: Text("上传超时(分钟)".tl),
                  hintText: "30".tl,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "提示: URL 留空将禁用服务器功能; API Key 不会随 WebDAV 同步".tl,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: _testing
                        ? null
                        : () async {
                            setState(() => _testing = true);
                            try {
                              final ok = await _testConnection();
                              showToast(
                                  message: ok ? "连接成功".tl : "连接失败".tl);
                            } finally {
                              if (mounted) setState(() => _testing = false);
                            }
                          },
                    child: Text(_testing ? "测试中".tl : "测试连接".tl),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: _save,
                    child: Text("保存".tl),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.tune),
          title: Text("下载并发".tl),
          subtitle: Text("服务器同时执行的任务数".tl),
          trailing: _loadingConcurrent
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_maxConcurrent?.toString() ?? "—"),
          onTap: _editConcurrency,
        ),
        Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom)),
      ],
    );
  }
}
