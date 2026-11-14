import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class Dev { String name; DateTime seen; Dev(this.name, this.seen); }

class Item {
  final String id, kind, fromName; final String? name, text, path; final int size; final Set<String> to; final DateTime t = DateTime.now();
  Item(this.id, this.kind, this.fromName, this.to, {this.name, this.text, this.path, this.size = 0});
  Map<String, dynamic> json() => {'id': id, 'kind': kind, 'name': name, 'size': size, 'text': text, 'from_name': fromName, 't': t.millisecondsSinceEpoch / 1000};
}

class LanServer {
  final String page, host; final String pin; final Directory inbox, tmp; final void Function(String) log;
  final int maxBytes = 20 * 1024 * 1024 * 1024;
  final _devs = <String, Dev>{}; final _items = <String, Item>{};
  HttpServer? _srv; Timer? _timer; int _n = 0;
  LanServer(this.page, this.host, this.pin, this.inbox, this.tmp, this.log);

  String _id() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_n++}';

  Future<void> start(int port) async {
    _srv = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _srv!.listen((r) async { try { await _handle(r); } catch (_) { try { await r.response.close(); } catch (_) {} } });
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _items.removeWhere((k, v) {
      final old = DateTime.now().difference(v.t).inHours >= 1; if (old) _rm(v); return old; }));
  }

  Future<void> stop() async { _timer?.cancel(); await _srv?.close(force: true); _srv = null; try { tmp.deleteSync(recursive: true); } catch (_) {} }

  void _rm(Item i) { if (i.path != null) { try { File(i.path!).parent.deleteSync(recursive: true); } catch (_) {} } }

  Future<void> _out(HttpRequest r, int code, Object body, [String type = 'application/json']) async {
    final b = utf8.encode(body is String ? body : jsonEncode(body));
    r.response..statusCode = code..headers.set('Content-Type', type)..headers.set('Cache-Control', 'no-store')..contentLength = b.length..add(b);
    await r.response.close();
  }

  bool _ok(HttpRequest r) => pin.isEmpty || (r.headers.value('x-pin') ?? r.uri.queryParameters['pin'] ?? '') == pin;

  String _clean(String? raw) {
    var n = raw ?? ''; try { n = Uri.decodeComponent(n); } catch (_) {}
    n = n.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_').replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    return n.isEmpty ? 'file' : n;
  }

  File _unique(String name) {
    var f = File('${inbox.path}/$name'); var i = 1;
    final dot = name.lastIndexOf('.'); final b = dot > 0 ? name.substring(0, dot) : name; final e = dot > 0 ? name.substring(dot) : '';
    while (f.existsSync()) { f = File('${inbox.path}/$b ($i)$e'); i++; }
    return f;
  }

  Set<String> _targets(String to, String me) => to == 'all'
      ? {..._devs.keys.where((k) => k != me), 'host'}
      : to.split(',').where((t) => t.isNotEmpty && t != me).toSet();

  Future<void> _handle(HttpRequest r) async {
    final p = r.uri.path, q = r.uri.queryParameters;
    if (r.method == 'GET' && p == '/') return _out(r, 200, page, 'text/html; charset=utf-8');
    if (!_ok(r)) return _out(r, 401, {'error': 'pin'});
    if (r.method == 'GET' && p == '/api/state') {
      final me = q['id'] ?? ''; var nm = q['name'] ?? 'Device'; if (nm.length > 40) nm = nm.substring(0, 40);
      final now = DateTime.now();
      if (me.isNotEmpty) _devs[me] = Dev(nm, now);
      _devs.removeWhere((_, d) => now.difference(d.seen).inSeconds > 8);
      final devs = [{'id': 'host', 'name': host, 'host': true}, ..._devs.entries.where((e) => e.key != me).map((e) => {'id': e.key, 'name': e.value.name})];
      final inbox = _items.values.where((i) => i.to.contains(me)).map((i) => i.json()).toList()
        ..sort((a, b) => (b['t'] as double).compareTo(a['t'] as double));
      return _out(r, 200, {'devices': devs, 'inbox': inbox});
    }
    if (r.method == 'GET' && p.startsWith('/dl/')) {
      final it = _items[p.substring(4)];
      if (it == null || it.kind != 'file') return _out(r, 404, {'error': 'gone'});
      r.response..statusCode = 200..headers.set('Content-Type', 'application/octet-stream')
        ..headers.set('Content-Disposition', "attachment; filename*=UTF-8''${Uri.encodeComponent(it.name!)}")..contentLength = it.size;
      await r.response.addStream(File(it.path!).openRead()); await r.response.close(); return;
    }
    if (r.method != 'POST') return _out(r, 404, {'error': 'not found'});
    if (p == '/api/send') {
      if (r.contentLength > maxBytes) return _out(r, 413, {'error': 'too large'});
      final me = r.headers.value('x-from') ?? '', tg = _targets(r.headers.value('x-to') ?? 'all', me), name = _clean(r.headers.value('x-name'));
      final id = _id(); final d = await Directory('${tmp.path}/$id').create(); final f = File('${d.path}/$name');
      final sink = f.openWrite(); await sink.addStream(r); await sink.close();
      if (tg.remove('host')) { final dest = _unique(name); await f.copy(dest.path); log('File: ${dest.path}'); }
      if (tg.isNotEmpty) {
        var from = r.headers.value('x-fromname') ?? '?'; try { from = Uri.decodeComponent(from); } catch (_) {}
        _items[id] = Item(id, 'file', from, tg, name: name, path: f.path, size: await f.length());
      } else { await d.delete(recursive: true); }
      return _out(r, 200, {'ok': true});
    }
    if (r.contentLength > (1 << 20)) return _out(r, 400, {'error': 'bad body'});
    final b = jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
    if (p == '/api/text') {
      final text = '${b['text'] ?? ''}'; final tg = _targets('${b['to'] ?? 'all'}', '${b['from'] ?? ''}');
      if (tg.remove('host')) { File('${inbox.path}/texts.txt').writeAsStringSync('$text\n---\n', mode: FileMode.append, encoding: utf8); log('Text saved to texts.txt'); }
      if (tg.isNotEmpty && text.isNotEmpty) { final id = _id(); _items[id] = Item(id, 'text', '${b['name'] ?? '?'}', tg, text: text); }
      return _out(r, 200, {'ok': true});
    }
    if (p == '/api/dismiss') {
      final it = _items['${b['item']}'];
      if (it != null) { it.to.remove('${b['id']}'); if (it.to.isEmpty) { _items.remove(it.id); _rm(it); } }
      return _out(r, 200, {'ok': true});
    }
    return _out(r, 404, {'error': 'not found'});
  }
}

void main() => runApp(const App());
final ar = Platform.localeName.startsWith('ar');
String t(String en, String a) => ar ? a : en;

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'LanHop', debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6BCB), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF0B6BCB), useMaterial3: true, brightness: Brightness.dark),
        builder: (c, w) => Directionality(textDirection: ar ? TextDirection.rtl : TextDirection.ltr, child: w!),
        home: const Home());
}

class Home extends StatefulWidget { const Home({super.key}); @override State<Home> createState() => _HomeState(); }

class _HomeState extends State<Home> {
  static const port = 8765;
  LanServer? srv; List<String> ips = []; final logs = <String>[]; final pin = TextEditingController(); String dir = '';

  Future<Directory> _inbox() async {
    Directory? base;
    try { base = Platform.isAndroid ? await getExternalStorageDirectory() : await getDownloadsDirectory(); } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    return Directory('${base.path}/LanHop').create(recursive: true);
  }

  Future<void> toggle(bool on) async {
    if (!on) { await srv?.stop(); setState(() => srv = null); return; }
    try {
      final inbox = await _inbox(); final tmp = await Directory.systemTemp.createTemp('lanhop');
      final page = await rootBundle.loadString('assets/index.html');
      final s = LanServer(page, Platform.localHostname, pin.text.trim(), inbox, tmp, (m) { if (mounted) setState(() => logs.insert(0, m)); });
      await s.start(port);
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      setState(() { srv = s; dir = inbox.path; ips = [for (final i in ifs) for (final a in i.addresses) if (!a.isLoopback) a.address]; });
    } catch (e) { setState(() => logs.insert(0, 'Error: $e')); }
  }

  @override
  Widget build(BuildContext c) {
    final on = srv != null;
    return Scaffold(
      appBar: AppBar(title: const Text('LanHop')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SwitchListTile(title: Text(t('Share on this Wi-Fi', 'المشاركة على هذه الشبكة')), value: on, onChanged: toggle),
        TextField(controller: pin, enabled: !on, decoration: InputDecoration(labelText: t('PIN (optional)', 'رمز PIN (اختياري)'), border: const OutlineInputBorder())),
        if (on) ...[
          const SizedBox(height: 16),
          Text(t('On other devices open:', 'على الأجهزة الأخرى افتح:')),
          for (final ip in ips) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: SelectableText('http://$ip:$port', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          const SizedBox(height: 8),
          FilledButton(onPressed: () => launchUrl(Uri.parse('http://127.0.0.1:$port'), mode: LaunchMode.externalApplication), child: Text(t('Open here to send', 'افتح هنا للإرسال'))),
          const SizedBox(height: 8),
          Text('${t('Received files', 'الملفات المستلمة')}: $dir', style: const TextStyle(fontSize: 12)),
        ],
        const Divider(height: 32),
        for (final l in logs.take(30)) Text(l, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }
}
