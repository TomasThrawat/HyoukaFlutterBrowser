import 'dart:async';

import 'package:adblocker_webview/adblocker_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const homeUrl = 'https://www.google.com/';
const _historyKey = 'browser_history';
const _maxHistoryItems = 100;
const _downloadChannel = MethodChannel('hyouka.browser/native_downloads');
const _adBlockKey = 'ad_block_enabled';

Uri resolveBrowserInput(String value) {
  final input = value.trim();
  if (input.isEmpty) {
    return Uri.parse(homeUrl);
  }

  final hasHttpScheme =
      input.startsWith('http://') || input.startsWith('https://');
  if (hasHttpScheme) {
    return Uri.parse(input);
  }

  final looksLikeDomain = input.contains('.') && !input.contains(' ');
  if (looksLikeDomain) {
    return Uri.parse('https://$input');
  }

  return Uri.parse(
    'https://www.google.com/search?q=' + Uri.encodeComponent(input),
  );
}

List<String> addHistoryEntry(
  List<String> current,
  String url, {
  int limit = _maxHistoryItems,
}) {
  final value = url.trim();
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    return List<String>.from(current);
  }

  final result = List<String>.from(current)
    ..remove(value)
    ..insert(0, value);

  if (result.length > limit) {
    result.removeRange(limit, result.length);
  }

  return result;
}

String downloadFileName(Uri uri) {
  final segment =
      uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.trim();
  final raw = segment.isEmpty ? 'page.html' : segment;
  final sanitized = raw
      .replaceAll(RegExp(r'[<>:"/\\\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  if (sanitized.isNotEmpty) {
    return sanitized;
  }

  return 'hyouka_download_' +
      DateTime.now().millisecondsSinceEpoch.toString() +
      '.bin';
}

class DownloadItem {
  DownloadItem({
    required this.url,
    required this.fileName,
    required this.nativeId,
  });

  final String url;
  final String fileName;
  final int nativeId;
  double progress = 0;
  String status = 'Queued';
  String? error;
  int receivedBytes = 0;
  int totalBytes = 0;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AdBlockerWebviewController.instance.initialize(
    FilterConfig(
      filterTypes: [FilterType.easyList, FilterType.adGuard],
    ),
  );

  runApp(const BrowserApp());
}

class BrowserApp extends StatelessWidget {
  const BrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hyouka Browser',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          surfaceContainer: Color(0xFF050505),
          primary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const BrowserPage(),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final controller = AdBlockerWebviewController.instance;
  final address = TextEditingController(text: homeUrl);
  final focus = FocusNode();
  final prefs = SharedPreferencesAsync();

  final List<String> _history = <String>[];
  final List<DownloadItem> _downloads = <DownloadItem>[];

  Timer? _downloadPoller;
  int progress = 0;
  bool canBack = false;
  bool canForward = false;
  bool _adBlockEnabled = true;
  bool _googleFallbackUsed = false;
  String? _pendingGoogleSearch;

  @override
  void initState() {
    super.initState();
    controller.resetStatistics();
    _loadHistory();
    _loadAdBlockPreference();
  }

  Future<void> _loadAdBlockPreference() async {
    final saved = await prefs.getBool(_adBlockKey);
    if (!mounted || saved == null) {
      return;
    }
    setState(() {
      _adBlockEnabled = saved;
    });
  }

  Future<void> _toggleAdBlock() async {
    final next = !_adBlockEnabled;
    setState(() {
      _adBlockEnabled = next;
    });
    await prefs.setBool(_adBlockKey, next);
    await controller.reload();
  }

  Future<void> _loadHistory() async {
    final saved = await prefs.getStringList(_historyKey);
    if (!mounted || saved == null) {
      return;
    }

    setState(() {
      _history
        ..clear()
        ..addAll(saved.take(_maxHistoryItems));
    });
  }

  Future<void> _recordHistory(String url) async {
    final updated = addHistoryEntry(_history, url);
    if (!mounted) {
      return;
    }

    setState(() {
      _history
        ..clear()
        ..addAll(updated);
    });

    await prefs.setStringList(_historyKey, _history);
  }

  Future<void> _clearHistory() async {
    setState(_history.clear);
    await prefs.remove(_historyKey);
  }

  Future<void> _syncNavigation() async {
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();

    if (!mounted) {
      return;
    }

    setState(() {
      canBack = back;
      canForward = forward;
    });
  }

  Future<void> _search(String value) async {
    final input = value.trim();
    if (input.isEmpty) {
      return;
    }

    final target = resolveBrowserInput(input);
    focus.unfocus();

    if (target.host == 'www.google.com' && target.path == '/search') {
      _pendingGoogleSearch = target.queryParameters['q'];
      _googleFallbackUsed = false;
    } else {
      _pendingGoogleSearch = null;
      _googleFallbackUsed = false;
    }

    await controller.loadUrl(target.toString());
    await _syncNavigation();
  }

  Future<void> _handleLoadFinished(Uri url) async {
    if (url.host == 'www.google.com' &&
        url.path == '/search' &&
        !_googleFallbackUsed) {
      final title = (await controller.getTitle() ?? '').toLowerCase();
      final challenge = title.contains('unusual traffic') ||
          title.contains('about this page') ||
          title.contains('معلومات عن هذه الصفحة') ||
          title.contains('حركة مرور غير معتادة');

      if (challenge) {
        final query = _pendingGoogleSearch ?? url.queryParameters['q'];
        if (query != null && query.isNotEmpty && mounted) {
          _googleFallbackUsed = true;
          _pendingGoogleSearch = null;
          final fallback =
              'https://www.bing.com/search?q=' + Uri.encodeQueryComponent(query);
          await controller.loadUrl(fallback);
          _showMessage('Google طلب تحقق للشبكة، تم تحويل البحث تلقائياً.');
          return;
        }
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      progress = 100;
      address.text = url.toString();
    });
    _recordHistory(url.toString());
    _syncNavigation();
  }

  Future<void> _reload() async {
    await controller.reload();
    await _syncNavigation();
  }

  Future<void> _goBack() async {
    if (!canBack) {
      return;
    }

    await controller.goBack();
    await _syncNavigation();
  }

  Future<void> _goForward() async {
    if (!canForward) {
      return;
    }

    await controller.goForward();
    await _syncNavigation();
  }

  Future<void> _downloadCurrentPage() async {
    final input = address.text.trim();
    final uri = Uri.tryParse(input);

    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _showMessage('Enter a valid HTTP or HTTPS address first.');
      return;
    }

    try {
      final fileName = downloadFileName(uri);
      final nativeId = await _downloadChannel.invokeMethod<int>(
        'startDownload',
        <String, dynamic>{
          'url': input,
          'fileName': fileName,
        },
      );

      if (!mounted || nativeId == null) {
        return;
      }

      final item = DownloadItem(
        url: input,
        fileName: fileName,
        nativeId: nativeId,
      );

      setState(() {
        _downloads.insert(0, item);
      });
      _ensureDownloadPolling();
    } on PlatformException catch (error) {
      _showMessage(
        'Download could not start: ' + (error.message ?? 'unknown error'),
      );
    }
  }

  void _ensureDownloadPolling() {
    if (_downloadPoller != null) {
      return;
    }

    _downloadPoller = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _pollDownloads(),
    );
  }

  Future<void> _pollDownloads() async {
    final active = _downloads
        .where(
          (item) => item.status == 'Queued' || item.status == 'Downloading',
        )
        .toList();

    if (active.isEmpty) {
      _downloadPoller?.cancel();
      _downloadPoller = null;
      return;
    }

    for (final item in active) {
      try {
        final data = await _downloadChannel.invokeMapMethod<String, dynamic>(
          'getDownloadStatus',
          item.nativeId,
        );

        if (!mounted || data == null) {
          continue;
        }

        final nextStatus = data['status']?.toString() ?? 'Downloading';
        final received = (data['receivedBytes'] as num?)?.toInt() ?? 0;
        final total = (data['totalBytes'] as num?)?.toInt() ?? 0;
        final nextProgress = total > 0
            ? (received / total * 100).clamp(0, 100).toDouble()
            : item.progress;

        setState(() {
          item.status = nextStatus;
          item.receivedBytes = received;
          item.totalBytes = total;
          item.progress = nextStatus == 'Completed' ? 100 : nextProgress;
          item.error = data['reason']?.toString();
        });
      } on PlatformException catch (error) {
        if (!mounted) {
          return;
        }

        setState(() {
          item.status = 'Failed';
          item.error = error.message ?? 'Download status unavailable';
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.8,
            child: Column(
              children: [
                ListTile(
                  title: const Text(
                    'History',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  trailing: _history.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () async {
                            await _clearHistory();
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: const Text('Clear'),
                        ),
                ),
                const Divider(height: 1, color: Colors.white12),
                Expanded(
                  child: _history.isEmpty
                      ? const Center(
                          child: Text(
                            'No history yet.',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _history.length,
                          itemBuilder: (context, index) {
                            final url = _history[index];
                            return ListTile(
                              leading: const Icon(
                                Icons.history_rounded,
                                color: Colors.white60,
                              ),
                              title: Text(
                                url,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                _search(url);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDownloads() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.8,
            child: Column(
              children: [
                const ListTile(
                  title: Text(
                    'Downloads',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Divider(height: 1, color: Colors.white12),
                Expanded(
                  child: _downloads.isEmpty
                      ? const Center(
                          child: Text(
                            'No downloads yet.',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _downloads.length,
                          itemBuilder: (context, index) {
                            final item = _downloads[index];
                            final percent = item.progress.round();

                            return ListTile(
                              leading: item.status == 'Downloading'
                                  ? SizedBox(
                                      width: 34,
                                      height: 34,
                                      child: CircularProgressIndicator(
                                        value: item.totalBytes > 0
                                            ? item.progress / 100
                                            : null,
                                        strokeWidth: 3,
                                      ),
                                    )
                                  : Icon(
                                      item.status == 'Completed'
                                          ? Icons.download_done_rounded
                                          : Icons.download_rounded,
                                      color: item.status == 'Failed'
                                          ? Colors.redAccent
                                          : Colors.white,
                                    ),
                              title: Text(
                                item.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.status == 'Downloading'
                                        ? 'Downloading • $percent%'
                                        : item.status,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                    ),
                                  ),
                                  if (item.status == 'Downloading')
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: LinearProgressIndicator(
                                        value: item.totalBytes > 0
                                            ? item.progress / 100
                                            : null,
                                        minHeight: 3,
                                        backgroundColor: Colors.white12,
                                      ),
                                    ),
                                  if (item.status == 'Failed' &&
                                      item.error != null)
                                    Text(
                                      item.error!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.redAccent,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _downloadButton() {
    DownloadItem? active;
    for (final item in _downloads) {
      if (item.status == 'Queued' || item.status == 'Downloading') {
        active = item;
        break;
      }
    }

    if (active == null) {
      return IconButton(
        tooltip: 'Download',
        onPressed: _downloadCurrentPage,
        icon: const Icon(Icons.download_rounded),
      );
    }

    final percent = active.progress.round();

    return IconButton(
      tooltip: 'Downloads',
      onPressed: _showDownloads,
      icon: SizedBox(
        width: 34,
        height: 34,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: active.totalBytes > 0 ? active.progress / 100 : null,
              strokeWidth: 2.5,
            ),
            Text(
              '$percent%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _downloadPoller?.cancel();
    address.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: AdBlockerWebview(
                  url: Uri.parse(homeUrl),
                  shouldBlockAds: _adBlockEnabled,
                  adBlockerWebviewController: controller,
                  userAgent:
                      'Mozilla/5.0 (Linux; Android 12; CPH2095) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) '
                      'Chrome/140.0.0.0 Mobile Safari/537.36',
                  onLoadStart: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      progress = 0;
                      address.text = url.toString();
                    });
                  },
                  onLoadFinished: _handleLoadFinished,
                  onUrlChanged: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      address.text = url.toString();
                    });
                    _syncNavigation();
                  },
                  onProgress: (value) {
                    if (!mounted) {
                      return;
                    }
                    setState(() => progress = value);
                  },
                ),
              ),
            ),
            if (progress > 0 && progress < 100)
              LinearProgressIndicator(
                value: progress / 100,
                minHeight: 2,
                backgroundColor: Colors.black,
              )
            else
              const SizedBox(height: 2),
            Material(
              color: Colors.black,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: address,
                        focusNode: focus,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.search,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLines: 1,
                        style: const TextStyle(color: Colors.white),
                        onSubmitted: _search,
                        decoration: InputDecoration(
                          hintText: 'Search or enter address',
                          hintStyle: const TextStyle(color: Colors.white38),
                          filled: true,
                          fillColor: Colors.black,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            color: Colors.white54,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide:
                                const BorderSide(color: Colors.white24),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(18),
                            borderSide:
                                const BorderSide(color: Colors.white54),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'History',
                      onPressed: _showHistory,
                      icon: const Icon(Icons.history_rounded),
                    ),
                    _downloadButton(),
                    IconButton(
                      tooltip: _adBlockEnabled
                          ? 'Disable ad blocker'
                          : 'Enable ad blocker',
                      onPressed: _toggleAdBlock,
                      icon: Icon(
                        _adBlockEnabled
                            ? Icons.shield_rounded
                            : Icons.shield_outlined,
                        color:
                            _adBlockEnabled ? Colors.white : Colors.white38,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }}
