import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const MdReaderApp());

class MdReaderApp extends StatelessWidget {
  const MdReaderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '简阅 MD',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315db5)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f9fc),
    ),
    home: const ReaderPage(),
  );
}

class DocFile {
  const DocFile({
    required this.name,
    required this.path,
    required this.uri,
    required this.mime,
  });
  final String name;
  final String path;
  final String uri;
  final String mime;

  factory DocFile.fromMap(Map<dynamic, dynamic> map) => DocFile(
    name: map['name'] as String,
    path: map['path'] as String,
    uri: map['uri'] as String,
    mime: map['mime'] as String? ?? '',
  );
}

class Heading {
  const Heading({required this.id, required this.title, required this.level});
  final String id;
  final String title;
  final int level;

  factory Heading.fromMap(Map<dynamic, dynamic> map) => Heading(
    id: map['id'] as String,
    title: map['title'] as String,
    level: (map['level'] as num).toInt(),
  );
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  static const _documents = MethodChannel('md_reader/documents');
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final WebViewController _web;
  List<DocFile> _allFiles = [];
  List<DocFile> _markdownFiles = [];
  List<Heading> _headings = [];
  DocFile? _current;
  String? _folderUri;
  String? _pendingHtml;
  bool _webReady = false;
  bool _busy = false;
  int _loadId = 0;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel('Reader', onMessageReceived: _onWebMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _webReady = true;
            _sendPendingHtml();
          },
          onNavigationRequest: (request) {
            if (request.url.startsWith('file:///android_asset/')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadFlutterAsset('assets/reader.html');
    _restoreFolder();
  }

  Future<void> _restoreFolder() async {
    try {
      final fileUri = await _documents.invokeMethod<String>('savedFile');
      if (fileUri != null) {
        final name =
            await _documents.invokeMethod<String>('fileName', {
              'uri': fileUri,
            }) ??
            '文档.md';
        final file = DocFile(
          name: name,
          path: name,
          uri: fileUri,
          mime: 'text/markdown',
        );
        setState(() {
          _allFiles = [file];
          _markdownFiles = [file];
        });
        await _openDocument(file);
        return;
      }
      final uri = await _documents.invokeMethod<String>('savedFolder');
      if (uri != null) await _openFolder(uri);
    } catch (_) {
      // A saved grant may have been removed by Android.
    }
  }

  Future<void> _pickFolder() async {
    try {
      final uri = await _documents.invokeMethod<String>('pickFolder');
      if (uri != null) await _openFolder(uri);
    } catch (error) {
      _showError('无法打开文件夹：$error');
    }
  }

  Future<void> _openFolder(String uri) async {
    setState(() => _busy = true);
    try {
      final raw = await _documents.invokeMethod<List<dynamic>>('listFolder', {
        'uri': uri,
      });
      final all = (raw ?? [])
          .map((item) => DocFile.fromMap(item as Map))
          .toList();
      final docs =
          all.where((file) {
            final lower = file.name.toLowerCase();
            return lower.endsWith('.md') || lower.endsWith('.markdown');
          }).toList()..sort(
            (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          );
      if (!mounted) return;
      setState(() {
        _folderUri = uri;
        _allFiles = all;
        _markdownFiles = docs;
        _current = null;
        _headings = [];
      });
      if (docs.isNotEmpty) await _openDocument(docs.first);
    } catch (error) {
      _showError('读取文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFile() async {
    try {
      final uri = await _documents.invokeMethod<String>('pickFile');
      if (uri == null) return;
      final name =
          await _documents.invokeMethod<String>('fileName', {'uri': uri}) ??
          '文档.md';
      final file = DocFile(
        name: name,
        path: name,
        uri: uri,
        mime: 'text/markdown',
      );
      setState(() {
        _folderUri = null;
        _allFiles = [file];
        _markdownFiles = [file];
      });
      await _openDocument(file);
    } catch (error) {
      _showError('无法打开文件：$error');
    }
  }

  Future<void> _openDocument(DocFile file) async {
    final loadId = ++_loadId;
    setState(() {
      _current = file;
      _headings = [];
      _busy = true;
    });
    try {
      final bytes = await _documents.invokeMethod<Uint8List>('readFile', {
        'uri': file.uri,
      });
      if (bytes == null) throw const FormatException('文件内容为空');
      var source = utf8.decode(bytes, allowMalformed: true);
      if (source.startsWith('\uFEFF')) source = source.substring(1);
      var html = md.markdownToHtml(
        source,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      );
      html = _sanitizeHtml(html);
      html = await _inlineLocalImages(html, file);
      if (!mounted || loadId != _loadId) return;
      _pendingHtml = html;
      await _sendPendingHtml();
    } catch (error) {
      _showError('读取文档失败：$error');
    } finally {
      if (mounted && loadId == _loadId) setState(() => _busy = false);
    }
  }

  String _sanitizeHtml(String html) {
    const allowed = {
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'p',
      'br',
      'hr',
      'ul',
      'ol',
      'li',
      'blockquote',
      'pre',
      'code',
      'em',
      'strong',
      'del',
      's',
      'a',
      'img',
      'table',
      'thead',
      'tbody',
      'tr',
      'th',
      'td',
      'input',
      'sup',
      'sub',
    };
    final fragment = html_parser.parseFragment(html);
    void clean(dom.Node node) {
      if (node is dom.Element) {
        if (!allowed.contains(node.localName)) {
          node.replaceWith(dom.Text(node.text));
          return;
        }
        final attrs = Map<String, String>.from(node.attributes);
        node.attributes.clear();
        if (node.localName == 'code' &&
            attrs['class']?.startsWith('language-') == true) {
          node.attributes['class'] = attrs['class']!;
        }
        if (node.localName == 'a') {
          final href = attrs['href'];
          final uri = href == null ? null : Uri.tryParse(href);
          if (uri != null &&
              (uri.scheme.isEmpty ||
                  {'http', 'https', 'mailto'}.contains(uri.scheme))) {
            node.attributes['href'] = href!;
          }
        }
        if (node.localName == 'img') {
          final src = attrs['src'];
          final uri = src == null ? null : Uri.tryParse(src);
          if (uri != null &&
              (uri.scheme.isEmpty || {'http', 'https'}.contains(uri.scheme))) {
            node.attributes['src'] = src!;
          }
          if (attrs['alt'] != null) node.attributes['alt'] = attrs['alt']!;
        }
        if (node.localName == 'input' && attrs['type'] == 'checkbox') {
          node.attributes['type'] = 'checkbox';
          node.attributes['disabled'] = '';
          if (attrs.containsKey('checked')) node.attributes['checked'] = '';
        }
      } else if (node is dom.Comment) {
        node.remove();
        return;
      }
      for (final child in List<dom.Node>.from(node.nodes)) {
        clean(child);
      }
    }

    clean(fragment);
    return fragment.outerHtml;
  }

  Future<String> _inlineLocalImages(String html, DocFile file) async {
    final matches = RegExp(
      r'<img\b[^>]*\bsrc="([^"]+)"[^>]*>',
    ).allMatches(html).toList();
    if (matches.isEmpty || _folderUri == null) return html;
    var output = html;
    for (final match in matches.reversed) {
      final source = match.group(1)!;
      final target = _resolveRelative(file.path, source);
      final image = _allFiles
          .where((entry) => entry.path == target)
          .firstOrNull;
      if (image == null) continue;
      try {
        final bytes = await _documents.invokeMethod<Uint8List>('readFile', {
          'uri': image.uri,
        });
        if (bytes == null) continue;
        final mime = image.mime.startsWith('image/')
            ? image.mime
            : _imageMime(image.name);
        final replacement = match
            .group(0)!
            .replaceFirst(source, 'data:$mime;base64,${base64Encode(bytes)}');
        output = output.replaceRange(match.start, match.end, replacement);
      } catch (_) {
        // Leave the source unchanged when an image cannot be read.
      }
    }
    return output;
  }

  String _imageMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    return 'image/jpeg';
  }

  String? _resolveRelative(String basePath, String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.hasScheme || link.startsWith('/')) return null;
    final base = basePath.split('/')..removeLast();
    for (final part in uri.pathSegments) {
      if (part == '.' || part.isEmpty) continue;
      if (part == '..') {
        if (base.isEmpty) return null;
        base.removeLast();
      } else {
        base.add(part);
      }
    }
    return base.join('/');
  }

  Future<void> _sendPendingHtml() async {
    final html = _pendingHtml;
    if (!_webReady || html == null) return;
    _pendingHtml = null;
    await _web.runJavaScript('renderMarkdown(${jsonEncode(html)});');
  }

  void _onWebMessage(JavaScriptMessage message) {
    try {
      final payload = jsonDecode(message.message) as Map<String, dynamic>;
      if (payload['type'] == 'headings') {
        final headings = (payload['headings'] as List)
            .map((item) => Heading.fromMap(item as Map))
            .toList();
        if (mounted) setState(() => _headings = headings);
      } else if (payload['type'] == 'link') {
        _openLink(payload['href'] as String);
      }
    } catch (_) {
      // Ignore malformed messages from page content.
    }
  }

  Future<void> _openLink(String href) async {
    if (href.startsWith('#')) {
      final id = href.substring(1);
      await _web.runJavaScript(
        'document.getElementById(${jsonEncode(id)})?.scrollIntoView({behavior:"smooth"});',
      );
      return;
    }
    final current = _current;
    if (current != null) {
      final path = _resolveRelative(current.path, href);
      final file = _markdownFiles
          .where((entry) => entry.path == path)
          .firstOrNull;
      if (file != null) {
        await _openDocument(file);
        return;
      }
    }
    final uri = Uri.tryParse(href);
    if (uri != null && {'https', 'http', 'mailto'}.contains(uri.scheme)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _fileList() => ListView.builder(
    itemCount: _markdownFiles.length,
    itemBuilder: (context, index) {
      final file = _markdownFiles[index];
      return ListTile(
        dense: true,
        selected: file.uri == _current?.uri,
        leading: const Icon(Icons.description_outlined, size: 19),
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: file.path == file.name
            ? null
            : Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () {
          if (Scaffold.of(context).isDrawerOpen) Navigator.pop(context);
          _openDocument(file);
        },
      );
    },
  );

  Widget _headingList() => ListView.builder(
    itemCount: _headings.length,
    itemBuilder: (context, index) {
      final heading = _headings[index];
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(
          left: 12.0 + (heading.level - 1) * 12,
          right: 8,
        ),
        title: Text(
          heading.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () {
          if (Scaffold.of(context).isEndDrawerOpen) Navigator.pop(context);
          _web.runJavaScript('jumpToHeading(${jsonEncode(heading.id)});');
        },
      );
    },
  );

  Widget _panel(String title, Widget content) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      const Divider(height: 1),
      Expanded(child: content),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      return Scaffold(
        key: _scaffoldKey,
        drawer: wide
            ? null
            : Drawer(child: SafeArea(child: _panel('文件', _fileList()))),
        endDrawer: wide
            ? null
            : Drawer(child: SafeArea(child: _panel('目录', _headingList()))),
        appBar: AppBar(
          title: Text(
            _current?.name ?? '简阅 MD',
            overflow: TextOverflow.ellipsis,
          ),
          leading: wide
              ? null
              : IconButton(
                  tooltip: '文件列表',
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          actions: [
            IconButton(
              tooltip: '选择文件夹',
              icon: const Icon(Icons.folder_open),
              onPressed: _pickFolder,
            ),
            IconButton(
              tooltip: '选择文件',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: _pickFile,
            ),
            if (!wide)
              IconButton(
                tooltip: '标题目录',
                icon: const Icon(Icons.toc),
                onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              ),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Row(
                children: [
                  if (wide)
                    SizedBox(width: 235, child: _panel('文件', _fileList())),
                  if (wide) const VerticalDivider(width: 1),
                  Expanded(
                    child: _current == null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.article_outlined,
                                  size: 52,
                                  color: Colors.blueGrey,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _folderUri == null
                              ? '选择文件夹或 MD 文件开始阅读'
                              : '此文件夹没有 MD 文件',
                                ),
                              ],
                            ),
                          )
                        : WebViewWidget(controller: _web),
                  ),
                  if (wide) const VerticalDivider(width: 1),
                  if (wide)
                    SizedBox(width: 235, child: _panel('目录', _headingList())),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
