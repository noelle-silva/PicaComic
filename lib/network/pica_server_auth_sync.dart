import 'package:pica_comic/base.dart';
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
}
