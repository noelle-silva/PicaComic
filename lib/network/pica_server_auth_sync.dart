import 'dart:io';

import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/comic_source/built_in/picacg.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/translations.dart';

class PicaServerAuthSyncResult {
  final Map<String, String> statusBySource;

  const PicaServerAuthSyncResult(this.statusBySource);

  bool get allOk =>
      statusBySource.values.every((v) => v == 'ok' || v == 'skipped');
}

class PicaServerAuthSync {
  PicaServerAuthSync._();

  static Future<PicaServerAuthSyncResult> syncAll() async {
    final res = <String, String>{};
    if (!PicaServer.instance.enabled) {
      throw Exception("未配置服务器".tl);
    }

    // picacg
    try {
      final token = (picacg.data['token'] ?? '').toString().trim();
      if (token.isEmpty) {
        res['picacg'] = 'skipped';
      } else {
        await PicaServer.instance.putAuthSession('picacg', {
          'token': token,
          'appChannel': (picacg.data['appChannel'] ?? '3').toString(),
          'imageQuality':
              (picacg.data['imageQuality'] ?? 'original').toString(),
          'appUuid': (picacg.data['appUuid'] ?? 'defaultUuid').toString(),
        });
        res['picacg'] = 'ok';
      }
    } catch (e) {
      res['picacg'] = 'failed: $e';
    }

    // ehentai
    try {
      final eh = EhNetwork();
      await eh.getCookies(true);
      final cookie = eh.cookiesStr.trim();
      if (cookie.isEmpty) {
        res['ehentai'] = 'skipped';
      } else {
        await PicaServer.instance.putAuthSession('ehentai', {'cookie': cookie});
        res['ehentai'] = 'ok';
      }
    } catch (e) {
      res['ehentai'] = 'failed: $e';
    }

    // jm
    try {
      final apiBaseUrl = JmNetwork().baseUrl.trim();
      final imgBaseUrl = appdata.settings[86].toString().trim();
      final appVersion = appdata.settings[89].toString().trim();
      if (apiBaseUrl.isEmpty || imgBaseUrl.isEmpty || appVersion.isEmpty) {
        res['jm'] = 'skipped';
      } else {
        await PicaServer.instance.putAuthSession('jm', {
          'apiBaseUrl': apiBaseUrl,
          'imgBaseUrl': imgBaseUrl,
          'appVersion': appVersion,
        });
        res['jm'] = 'ok';
      }
    } catch (e) {
      res['jm'] = 'failed: $e';
    }

    // hitomi
    try {
      final baseDomain = appdata.settings[87].toString().trim();
      if (baseDomain.isEmpty) {
        res['hitomi'] = 'skipped';
      } else {
        await PicaServer.instance
            .putAuthSession('hitomi', {'baseDomain': baseDomain});
        res['hitomi'] = 'ok';
      }
    } catch (e) {
      res['hitomi'] = 'failed: $e';
    }

    // htmanga
    try {
      final baseUrl = appdata.settings[31].toString().trim();
      if (baseUrl.isEmpty) {
        res['htmanga'] = 'skipped';
      } else {
        String cookie = '';
        final jar = SingleInstanceCookieJar.instance;
        if (jar != null) {
          cookie = jar.loadForRequestCookieHeader(Uri.parse(baseUrl)).trim();
        }
        await PicaServer.instance.putAuthSession('htmanga', {
          'baseUrl': baseUrl,
          if (cookie.isNotEmpty) 'cookie': cookie,
        });
        res['htmanga'] = 'ok';
      }
    } catch (e) {
      res['htmanga'] = 'failed: $e';
    }

    // nhentai (no auth required for download)
    try {
      await PicaServer.instance.putAuthSession('nhentai', {
        'baseUrl': 'https://nhentai.net',
      });
      res['nhentai'] = 'ok';
    } catch (e) {
      res['nhentai'] = 'failed: $e';
    }

    return PicaServerAuthSyncResult(res);
  }

  /// 从服务器下载各源登录态并写回本地（与 [syncAll] 反向对称）。
  static Future<PicaServerAuthSyncResult> downloadAll() async {
    final res = <String, String>{};
    if (!PicaServer.instance.enabled) {
      throw Exception("未配置服务器".tl);
    }

    // picacg
    try {
      final data = await PicaServer.instance.getAuthSessionData('picacg');
      final token = (data?['token'] ?? '').toString().trim();
      if (token.isEmpty) {
        res['picacg'] = 'skipped';
      } else {
        picacg.data['token'] = data!['token'];
        if (data['appChannel'] != null) {
          picacg.data['appChannel'] = data['appChannel'];
        }
        if (data['imageQuality'] != null) {
          picacg.data['imageQuality'] = data['imageQuality'];
        }
        if (data['appUuid'] != null) {
          picacg.data['appUuid'] = data['appUuid'];
        }
        await picacg.saveData();
        res['picacg'] = 'ok';
      }
    } catch (e) {
      res['picacg'] = 'failed: $e';
    }

    // ehentai
    try {
      final data = await PicaServer.instance.getAuthSessionData('ehentai');
      final cookie = (data?['cookie'] ?? '').toString().trim();
      final jar = SingleInstanceCookieJar.instance;
      if (cookie.isEmpty || jar == null) {
        res['ehentai'] = 'skipped';
      } else {
        final eh = EhNetwork();
        final cookies = _parseCookieHeader(cookie);
        if (cookies.isEmpty) {
          res['ehentai'] = 'skipped';
        } else {
          jar.saveFromResponse(Uri.parse(eh.ehBaseUrl), cookies);
          await eh.getCookies(true);
          ehentai.data['account'] = 'ok';
          await ehentai.saveData();
          res['ehentai'] = 'ok';
        }
      }
    } catch (e) {
      res['ehentai'] = 'failed: $e';
    }

    // jm
    try {
      final data = await PicaServer.instance.getAuthSessionData('jm');
      if (data == null) {
        res['jm'] = 'skipped';
      } else {
        final apiBaseUrl = (data['apiBaseUrl'] ?? '').toString().trim();
        final imgBaseUrl = (data['imgBaseUrl'] ?? '').toString().trim();
        final appVersion = (data['appVersion'] ?? '').toString().trim();
        if (apiBaseUrl.isEmpty && imgBaseUrl.isEmpty && appVersion.isEmpty) {
          res['jm'] = 'skipped';
        } else {
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
          await appdata.updateSettings();
          res['jm'] = 'ok';
        }
      }
    } catch (e) {
      res['jm'] = 'failed: $e';
    }

    // hitomi
    try {
      final data = await PicaServer.instance.getAuthSessionData('hitomi');
      final baseDomain = (data?['baseDomain'] ?? '').toString().trim();
      if (baseDomain.isEmpty) {
        res['hitomi'] = 'skipped';
      } else {
        appdata.settings[87] = baseDomain;
        await appdata.updateSettings();
        res['hitomi'] = 'ok';
      }
    } catch (e) {
      res['hitomi'] = 'failed: $e';
    }

    // htmanga
    try {
      final data = await PicaServer.instance.getAuthSessionData('htmanga');
      final baseUrl = (data?['baseUrl'] ?? '').toString().trim();
      if (baseUrl.isEmpty) {
        res['htmanga'] = 'skipped';
      } else {
        appdata.settings[31] = baseUrl;
        final cookie = (data!['cookie'] ?? '').toString().trim();
        final jar = SingleInstanceCookieJar.instance;
        if (cookie.isNotEmpty && jar != null) {
          final cookies = _parseCookieHeader(cookie);
          if (cookies.isNotEmpty) {
            jar.saveFromResponse(Uri.parse(baseUrl), cookies);
          }
        }
        await appdata.updateSettings();
        res['htmanga'] = 'ok';
      }
    } catch (e) {
      res['htmanga'] = 'failed: $e';
    }

    // nhentai 无登录态
    res['nhentai'] = 'skipped';

    return PicaServerAuthSyncResult(res);
  }

  static List<Cookie> _parseCookieHeader(String cookie) {
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
}
