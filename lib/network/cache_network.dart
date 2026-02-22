import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';
import 'app_dio.dart';

bool _looksLikeGzip(Uint8List data) {
  return data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b;
}

Uint8List _maybeGunzip(Uint8List data) {
  if (_looksLikeGzip(data)) {
    try {
      return Uint8List.fromList(gzip.decode(data));
    } catch (_) {
      // 解压失败按原样返回，交给上层处理
    }
  }
  return data;
}

String _decodePossiblyCompressedUtf8(Uint8List data,
    {bool allowMalformed = true}) {
  final bytes = _maybeGunzip(data);
  return utf8.decode(bytes, allowMalformed: allowMalformed);
}

///缓存网络请求, 仅提供get方法, 其它的没有意义
class CachedNetwork {
  Future<CachedNetworkRes<String>> get(String url, BaseOptions options,
      {CacheExpiredTime expiredTime = CacheExpiredTime.short,
      CookieJarSql? cookieJar,
      bool log = true,
      bool http2 = false}) async {
    await setNetworkProxy();
    var fileName = md5.convert(const Utf8Encoder().convert(url)).toString();
    if (fileName.length > 20) {
      fileName = fileName.substring(0, 21);
    }
    final key = url;
    if (expiredTime != CacheExpiredTime.no) {
      var cache = await CacheManager().findCache(key);
      if (cache != null) {
        try {
          var file = File(cache);
          final bytes = await file.readAsBytes();
          return CachedNetworkRes(
              _decodePossiblyCompressedUtf8(bytes), 200, url);
        } catch (_) {
          await CacheManager().delete(key);
        }
      }
    }
    options.responseType = ResponseType.bytes;
    var dio = log ? logDio(options, http2) : Dio(options);
    if (cookieJar != null) {
      dio.interceptors.add(CookieManagerSql(cookieJar));
    }

    var res = await dio.get<Uint8List>(url);
    if (res.data == null && !url.contains("random")) {
      throw Exception("Empty data");
    }
    final body = _decodePossiblyCompressedUtf8(res.data!);
    if (expiredTime != CacheExpiredTime.no) {
      await CacheManager().writeCache(
          key, Uint8List.fromList(utf8.encode(body)), expiredTime.time);
    }
    return CachedNetworkRes(
        body, res.statusCode, res.realUri.toString(), res.headers.map);
  }

  void delete(String url) async {
    await CacheManager().delete(url);
  }
}

enum CacheExpiredTime {
  no(-1),
  short(86400000),
  long(604800000),
  persistent(0);

  ///过期时间, 单位为微秒
  final int time;

  const CacheExpiredTime(this.time);
}

class CachedNetworkRes<T> {
  T data;
  int? statusCode;
  Map<String, List<String>> headers;
  String url;

  CachedNetworkRes(this.data, this.statusCode, this.url,
      [this.headers = const {}]);
}
