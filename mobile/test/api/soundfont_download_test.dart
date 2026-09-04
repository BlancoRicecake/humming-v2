// Resumable soundfont download (audit A16b) — EngineApi.downloadSoundfontToFile.
//
// A catalog font is 200-400MB; before this, a drop at 90% threw the bytes away
// and started over. The client now sends `Range: bytes=<already have>-` and
// appends. Exercised against a fake HttpClientAdapter that implements ranges
// the way the backend's FileResponse does (verified: it answers 206 with a
// Content-Range, and 416 when the range starts past the end).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/api/engine_api.dart';

/// Serves [body] with Range support, and can cut the connection after N bytes
/// to simulate a dropped download.
class _RangeAdapter implements HttpClientAdapter {
  _RangeAdapter(this.body, {this.failAfter, this.ignoreRange = false});

  final Uint8List body;

  /// Model a server (or proxy) that drops the Range header: 200 + full body.
  final bool ignoreRange;

  /// Bytes to emit before throwing (null = serve the whole thing).
  int? failAfter;
  final List<String?> seenRanges = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final range = options.headers['range'] as String?;
    seenRanges.add(range);
    var start = 0;
    if (range != null && !ignoreRange) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) start = int.parse(m.group(1)!);
    }
    if (start >= body.length) {
      return ResponseBody.fromBytes(<int>[], 416);
    }
    final slice = body.sublist(start);
    final limit = failAfter;
    final headers = <String, List<String>>{
      'content-length': ['${slice.length}'],
      if (start > 0) 'content-range': ['bytes $start-${body.length - 1}/${body.length}'],
    };
    final ctl = StreamController<Uint8List>();
    scheduleMicrotask(() async {
      const chunk = 64;
      for (var i = 0; i < slice.length; i += chunk) {
        if (limit != null && i >= limit) {
          ctl.addError(const SocketException('connection dropped'));
          await ctl.close();
          return;
        }
        ctl.add(Uint8List.sublistView(
            slice, i, i + chunk > slice.length ? slice.length : i + chunk));
      }
      await ctl.close();
    });
    return ResponseBody(ctl.stream, start > 0 ? 206 : 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _payload(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sf2dl');
    path = '${tmp.path}/font.sf2.part';
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  EngineApi apiWith(_RangeAdapter a) {
    final api = EngineApi(baseUrl: 'http://localhost');
    api.dio.httpClientAdapter = a;
    return api;
  }

  test('a fresh download writes the whole file and sends no Range', () async {
    final body = _payload(1000);
    final a = _RangeAdapter(body);
    await apiWith(a).downloadSoundfontToFile('x', path, expectedBytes: 1000);

    expect(await File(path).readAsBytes(), body);
    expect(a.seenRanges, [null]);
  });

  test('an interrupted download resumes from what is already on disk', () async {
    final body = _payload(1000);
    // First attempt dies partway through and leaves the bytes behind.
    final first = _RangeAdapter(body, failAfter: 256);
    await expectLater(
      apiWith(first).downloadSoundfontToFile('x', path, expectedBytes: 1000),
      throwsA(anything),
    );
    final partial = await File(path).length();
    expect(partial, greaterThan(0));
    expect(partial, lessThan(1000));

    // Second attempt asks for the rest and appends it.
    final second = _RangeAdapter(body);
    await apiWith(second).downloadSoundfontToFile('x', path, expectedBytes: 1000);

    expect(second.seenRanges, ['bytes=$partial-']);
    expect(await File(path).readAsBytes(), body,
        reason: 'resumed file must be byte-identical, not double-written');
  });

  test('progress reports absolute bytes and the full total while resuming',
      () async {
    final body = _payload(1000);
    await File(path).writeAsBytes(body.sublist(0, 400));
    final seen = <List<int>>[];
    await apiWith(_RangeAdapter(body)).downloadSoundfontToFile(
      'x', path,
      expectedBytes: 1000,
      onProgress: (r, t) => seen.add([r, t]),
    );
    expect(seen.first[0], greaterThan(400), reason: 'counts the bytes already held');
    expect(seen.last, [1000, 1000]);
  });

  test('a server that ignores Range restarts cleanly instead of appending',
      () async {
    final body = _payload(1000);
    await File(path).writeAsBytes(body.sublist(0, 400));
    // 200 + the whole body even though a Range was sent — e.g. a proxy that
    // strips the header. The client must truncate, not append.
    final a = _RangeAdapter(body, ignoreRange: true);
    await apiWith(a).downloadSoundfontToFile('x', path, expectedBytes: 1000);

    expect(a.seenRanges, ['bytes=400-']);

    expect(await File(path).length(), 1000);
    expect(await File(path).readAsBytes(), body);
  });

  test('a complete file is not re-fetched', () async {
    final body = _payload(1000);
    await File(path).writeAsBytes(body);
    final a = _RangeAdapter(body);
    await apiWith(a).downloadSoundfontToFile('x', path, expectedBytes: 1000);
    expect(a.seenRanges, isEmpty, reason: 'no request at all');
  });

  test('a stale part longer than the server file is discarded (416)', () async {
    final body = _payload(1000);
    await File(path).writeAsBytes(_payload(1500));
    // expectedBytes unknown (0) so the early return cannot help — the server
    // answers 416 and the client starts over.
    final a = _RangeAdapter(body);
    await apiWith(a).downloadSoundfontToFile('x', path);
    expect(await File(path).readAsBytes(), body);
    expect(a.seenRanges.length, 2); // ranged attempt, then a fresh one
  });
}
