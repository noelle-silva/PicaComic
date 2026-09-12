import 'dart:async';
import 'dart:io';

import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/comic_source/built_in/jm.dart';
import 'package:pica_comic/comic_source/built_in/nhentai.dart';
import 'package:pica_comic/comic_source/built_in/picacg.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/translations.dart';

class PicaServerAuthSyncResult {
  /// 每个源的处理结果：ok / skipped / failed: <原因>
  final Map<String, String> statusBySource;

  const PicaServerAuthSyncResult(this.statusBySource);

  bool get allOk =>
      statusBySource.values.every((v) => v == 'ok' || v == 'skipped');
}

/// 单个源的登录态同步协议。
///
/// 数据约定（顶层字段）：
/// - 配置字段：服务器下载任务所需的配置/凭证（如 jm 域名、eh cookie、picacg 令牌）。
/// - [authState] == 'logged_in'：登录态字段有效的统一标记，仅真登录时上传。
/// - 登录态字段：`account` / `user` / `name` / `id` / `cookie`（各源按需）。
class _SourceAuthSync {
  const _SourceAuthSync({
    required this.key,
    required this.buildUpload,
    required this.applyDownload,
  });

  final String key;

  /// 组织上传数据；无有效内容时返回 null（跳过上传）。
  final FutureOr<Map<String, dynamic>?> Function() buildUpload;

  /// 应用下载数据：配置字段照常恢复；登录态字段仅在 [authState] 为
  /// 'logged_in' 且关键凭证齐备时恢复，避免把非登录数据误标为已登录。
  final Future<String> Function(Map<String, dynamic> data) applyDownload;
}

const _authStateKey = 'authState';
const _loggedIn = 'logged_in';

class PicaServerAuthSync {
  PicaServerAuthSync._();

  static Future<PicaServerAuthSyncResult> syncAll() async {
    if (!PicaServer.instance.enabled) {
      throw Exception("未配置服务器".tl);
    }
    final res = <String, String>{};
    for (final protocol in _protocols) {
      try {
        final data = await protocol.buildUpload();
        if (data == null) {
          res[protocol.key] = 'skipped';
        } else {
          await PicaServer.instance.putAuthSession(protocol.key, data);
          res[protocol.key] = 'ok';
        }
      } catch (e) {
        res[protocol.key] = 'failed: $e';
      }
    }
    return PicaServerAuthSyncResult(res);
  }

  static Future<PicaServerAuthSyncResult> downloadAll() async {
    if (!PicaServer.instance.enabled) {
      throw Exception("未配置服务器".tl);
    }
    final res = <String, String>{};
    for (final protocol in _protocols) {
      try {
        final data = await PicaServer.instance.getAuthSessionData(protocol.key);
        if (data == null) {
          res[protocol.key] = 'skipped';
        } else {
          res[protocol.key] = await protocol.applyDownload(data);
        }
      } catch (e) {
        res[protocol.key] = 'failed: $e';
      }
    }
    return PicaServerAuthSyncResult(res);
  }

  static const List<_SourceAuthSync> _protocols = [
    _SourceAuthSync(
      key: 'picacg',
      buildUpload: _uploadPicacg,
      applyDownload: _downloadPicacg,
    ),
    _SourceAuthSync(
      key: 'ehentai',
      buildUpload: _uploadEhentai,
      applyDownload: _downloadEhentai,
    ),
    _SourceAuthSync(
      key: 'jm',
      buildUpload: _uploadJm,
      applyDownload: _downloadJm,
    ),
    _SourceAuthSync(
      key: 'hitomi',
      buildUpload: _uploadHitomi,
      applyDownload: _downloadHitomi,
    ),
    _SourceAuthSync(
      key: 'htmanga',
      buildUpload: _uploadHtmanga,
      applyDownload: _downloadHtmanga,
    ),
    _SourceAuthSync(
      key: 'nhentai',
      buildUpload: _uploadNhentai,
      applyDownload: _downloadNhentai,
    ),
  ];
}

// ---------------------------------------------------------------------------
// picacg
// ---------------------------------------------------------------------------

Map<String, dynamic>? _uploadPicacg() {
  final token = (picacg.data['token'] ?? '').toString().trim();
  if (token.isEmpty) return null;
  final data = <String, dynamic>{
    'token': token,
    'appChannel': (picacg.data['appChannel'] ?? '3').toString(),
    'imageQuality': (picacg.data['imageQuality'] ?? 'original').toString(),
    'appUuid': (picacg.data['appUuid'] ?? 'defaultUuid').toString(),
  };
  if (picacg.isLogin) {
    data[_authStateKey] = _loggedIn;
    data['account'] = picacg.data['account'];
    if (picacg.data['user'] != null) {
      data['user'] = picacg.data['user'];
    }
  }
  return data;
}

Future<String> _downloadPicacg(Map<String, dynamic> data) async {
  final token = (data['token'] ?? '').toString().trim();
  if (token.isEmpty) return 'skipped';

  // 服务器任务配置字段：始终恢复
  if (data['appChannel'] != null) {
    picacg.data['appChannel'] = data['appChannel'];
  }
  if (data['imageQuality'] != null) {
    picacg.data['imageQuality'] = data['imageQuality'];
  }
  if (data['appUuid'] != null) {
    picacg.data['appUuid'] = data['appUuid'];
  }

  // 登录态字段：仅真登录数据
  if (data[_authStateKey] == _loggedIn) {
    picacg.data['token'] = data['token'];
    if (data['account'] != null) {
      picacg.data['account'] = data['account'];
    }
    if (data['user'] != null) {
      picacg.data['user'] = data['user'];
      try {
        network.user = Profile.fromJson(data['user']);
      } catch (_) {
        // 资料格式异常时不阻塞令牌与账号的恢复
      }
    }
  }
  await picacg.saveData();
  return 'ok';
}

// ---------------------------------------------------------------------------
// ehentai
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>?> _uploadEhentai() async {
  final eh = EhNetwork();
  await eh.getCookies(true);
  final cookie = eh.cookiesStr.trim();
  if (cookie.isEmpty) return null;
  final data = <String, dynamic>{'cookie': cookie};
  if (_hasEhentaiLogin()) {
    data[_authStateKey] = _loggedIn;
    data['account'] = 'ok';
    final name = ehentai.data['name'];
    if (name != null && name.toString().isNotEmpty) {
      data['name'] = name;
    }
  }
  return data;
}

/// ehentai 的真实登录判定：登录标记 + 会员 cookie（ipb_member_id）同在。
bool _hasEhentaiLogin() {
  if (!ehentai.isLogin) return false;
  final jar = SingleInstanceCookieJar.instance;
  if (jar == null) return false;
  final cookies = jar.loadForRequest(Uri.parse(EhNetwork().ehBaseUrl));
  return cookies.any((c) => c.name == 'ipb_member_id' && c.value.isNotEmpty);
}

Future<String> _downloadEhentai(Map<String, dynamic> data) async {
  final cookie = (data['cookie'] ?? '').toString().trim();
  if (cookie.isEmpty) return 'skipped';
  // 非登录数据（例如仅供服务器下载使用的浏览 cookie）不写回本地
  if (data[_authStateKey] != _loggedIn) return 'skipped';
  final cookies = _parseCookieHeader(cookie);
  if (!cookies.any((c) => c.name == 'ipb_member_id' && c.value.isNotEmpty)) {
    return 'skipped';
  }
  final jar = SingleInstanceCookieJar.instance;
  if (jar == null) return 'skipped';
  final eh = EhNetwork();
  jar.saveFromResponse(Uri.parse(eh.ehBaseUrl), cookies);
  await eh.getCookies(true);
  ehentai.data['account'] = 'ok';
  if (data['name'] != null) {
    ehentai.data['name'] = data['name'];
  }
  await ehentai.saveData();
  return 'ok';
}

// ---------------------------------------------------------------------------
// jm
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>?> _uploadJm() async {
  final apiBaseUrl = JmNetwork().baseUrl.trim();
  final imgBaseUrl = appdata.settings[86].toString().trim();
  final appVersion = appdata.settings[89].toString().trim();
  if (apiBaseUrl.isEmpty || imgBaseUrl.isEmpty || appVersion.isEmpty) {
    return null;
  }
  final data = <String, dynamic>{
    'apiBaseUrl': apiBaseUrl,
    'imgBaseUrl': imgBaseUrl,
    'appVersion': appVersion,
  };
  if (jm.isLogin) {
    data[_authStateKey] = _loggedIn;
    data['account'] = jm.data['account'];
    if (jm.data['id'] != null) {
      data['id'] = jm.data['id'];
    }
    if (jm.data['name'] != null) {
      data['name'] = jm.data['name'];
    }
    final cookie = await _jmSessionCookie(apiBaseUrl);
    if (cookie.isNotEmpty) {
      data['cookie'] = cookie;
    }
  }
  return data;
}

Future<String> _jmSessionCookie(String baseUrl) async {
  try {
    final cookies =
        await JmNetwork().cookieJar.loadForRequest(Uri.parse(baseUrl));
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  } catch (_) {
    return '';
  }
}

Future<String> _downloadJm(Map<String, dynamic> data) async {
  final apiBaseUrl = (data['apiBaseUrl'] ?? '').toString().trim();
  final imgBaseUrl = (data['imgBaseUrl'] ?? '').toString().trim();
  final appVersion = (data['appVersion'] ?? '').toString().trim();
  if (apiBaseUrl.isEmpty && imgBaseUrl.isEmpty && appVersion.isEmpty) {
    return 'skipped';
  }

  // 服务器任务配置字段：始终恢复
  if (apiBaseUrl.isNotEmpty) {
    final host = Uri.tryParse(apiBaseUrl)?.host ?? apiBaseUrl;
    final domains = appdata.appSettings.jmApiDomains;
    var index = domains.indexOf(host);
    if (index < 0) {
      domains.add(host);
      appdata.appSettings.jmApiDomains = domains;
      index = domains.length - 1;
    }
    appdata.settings[17] = index.toString();
  }
  if (imgBaseUrl.isNotEmpty) {
    appdata.settings[86] = imgBaseUrl;
  }
  if (appVersion.isNotEmpty) {
    appdata.settings[89] = appVersion;
  }

  // 登录态字段：仅真登录数据
  if (data[_authStateKey] == _loggedIn) {
    if (data['account'] != null) {
      jm.data['account'] = data['account'];
    }
    if (data['id'] != null) {
      jm.data['id'] = data['id'];
    }
    if (data['name'] != null) {
      jm.data['name'] = data['name'];
    }
    final cookie = (data['cookie'] ?? '').toString().trim();
    if (cookie.isNotEmpty && apiBaseUrl.isNotEmpty) {
      final cookies = _parseCookieHeader(cookie);
      if (cookies.isNotEmpty) {
        await JmNetwork()
            .cookieJar
            .saveFromResponse(Uri.parse(apiBaseUrl), cookies);
      }
    }
    await jm.saveData();
  }
  await appdata.updateSettings();
  return 'ok';
}

// ---------------------------------------------------------------------------
// hitomi（无登录态，仅服务器任务配置）
// ---------------------------------------------------------------------------

Map<String, dynamic>? _uploadHitomi() {
  final baseDomain = appdata.settings[87].toString().trim();
  if (baseDomain.isEmpty) return null;
  return {'baseDomain': baseDomain};
}

Future<String> _downloadHitomi(Map<String, dynamic> data) async {
  final baseDomain = (data['baseDomain'] ?? '').toString().trim();
  if (baseDomain.isEmpty) return 'skipped';
  appdata.settings[87] = baseDomain;
  await appdata.updateSettings();
  return 'ok';
}

// ---------------------------------------------------------------------------
// htmanga
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>?> _uploadHtmanga() async {
  final baseUrl = appdata.settings[31].toString().trim();
  if (baseUrl.isEmpty) return null;
  final data = <String, dynamic>{'baseUrl': baseUrl};
  final cookie = _globalCookieHeader(baseUrl);
  if (cookie.isNotEmpty) {
    data['cookie'] = cookie;
  }
  if (htManga.isLogin) {
    data[_authStateKey] = _loggedIn;
    data['account'] = htManga.data['account'];
    if (htManga.data['name'] != null) {
      data['name'] = htManga.data['name'];
    }
  }
  return data;
}

Future<String> _downloadHtmanga(Map<String, dynamic> data) async {
  final baseUrl = (data['baseUrl'] ?? '').toString().trim();
  if (baseUrl.isEmpty) return 'skipped';

  // 服务器任务配置字段：始终恢复
  appdata.settings[31] = baseUrl;

  // 登录态字段：仅真登录数据
  if (data[_authStateKey] == _loggedIn) {
    final cookie = (data['cookie'] ?? '').toString().trim();
    final jar = SingleInstanceCookieJar.instance;
    if (cookie.isNotEmpty && jar != null) {
      final cookies = _parseCookieHeader(cookie);
      if (cookies.isNotEmpty) {
        jar.saveFromResponse(Uri.parse(baseUrl), cookies);
      }
    }
    if (data['account'] != null) {
      htManga.data['account'] = data['account'];
    }
    if (data['name'] != null) {
      htManga.data['name'] = data['name'];
    }
    await htManga.saveData();
  }
  await appdata.updateSettings();
  return 'ok';
}

// ---------------------------------------------------------------------------
// nhentai
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>?> _uploadNhentai() async {
  final baseUrl = NhentaiNetwork().baseUrl;
  final data = <String, dynamic>{'baseUrl': baseUrl};
  if (nhentai.isLogin) {
    final cookie = _globalCookieHeader(baseUrl);
    if (_hasCookie(cookie, 'sessionid')) {
      data[_authStateKey] = _loggedIn;
      data['account'] = 'ok';
      data['cookie'] = cookie;
    }
  }
  return data;
}

Future<String> _downloadNhentai(Map<String, dynamic> data) async {
  if (data[_authStateKey] != _loggedIn) return 'skipped';
  final baseUrl = (data['baseUrl'] ?? '').toString().trim();
  final cookie = (data['cookie'] ?? '').toString().trim();
  if (baseUrl.isEmpty || cookie.isEmpty) return 'skipped';
  if (!_hasCookie(cookie, 'sessionid')) return 'skipped';
  final jar = SingleInstanceCookieJar.instance;
  if (jar == null) return 'skipped';
  jar.saveFromResponse(Uri.parse(baseUrl), _parseCookieHeader(cookie));
  nhentai.data['account'] = 'ok';
  await nhentai.saveData();
  NhentaiNetwork().logged = true;
  return 'ok';
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

String _globalCookieHeader(String url) {
  final jar = SingleInstanceCookieJar.instance;
  if (jar == null) return '';
  return jar.loadForRequestCookieHeader(Uri.parse(url)).trim();
}

bool _hasCookie(String cookieHeader, String name) {
  return _parseCookieHeader(cookieHeader)
      .any((c) => c.name == name && c.value.isNotEmpty);
}

List<Cookie> _parseCookieHeader(String cookie) {
  var cookies = <Cookie>[];
  for (var part in cookie.split(';')) {
    var p = part.trim();
    if (p.isEmpty) continue;
    var idx = p.indexOf('=');
    if (idx <= 0) continue;
    cookies.add(Cookie(
      p.substring(0, idx).trim(),
      p.substring(idx + 1).trim(),
    ));
  }
  return cookies;
}
