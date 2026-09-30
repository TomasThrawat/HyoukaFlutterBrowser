import 'package:adblocker_webview/adblocker_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_downloader/flutter_file_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

const homeUrl = 'https://www.google.com/';
const _historyKey = 'browser_history';
const _maxHistoryItems = 100;

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
    'https://www.google.com/search?q=${Uri.encodeComponent(input)}',
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
  if (uri.pathSegments.isNotEmpty) {
    final last = uri.pathSegments.last.trim();
    if (last.isNotEmpty && last != '/') {
      return last;
    }
  }

  return 'hyouka_download_${DateTime.now().millisecondsSinceEpoch}.html';
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

class _DownloadEntry {
  _DownloadEntry({
    required this.id,
    required this.url,
    required this.fileName,
  });

  final String id;
  final String url;
  String fileName;
  double progress = 0;
  String status = 'Queued';
  String? error;
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
  final List<_DownloadEntry> _downloads = <_DownloadEntry>[];

  int progress = 0;
  bool canBack = false;
  bool canForward = false;

  @override
  void initState() {
    super.initState();
    controller.resetStatistics();
    _loadHistory();
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

    await controller.loadUrl(target.toString());
    await _syncNavigation();
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

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final entry = _DownloadEntry(
      id: id,
      url: input,
      fileName: downloadFileName(uri),
    );

    setState(() {
      _downloads.insert(0, entry);
    });

    await FileDownloader.downloadFile(
      url: input,
      name: entry.fileName,
      onProgress: (fileName, value) {
        if (!mounted) {
          return;
        }

        setState(() {
          entry.fileName = fileName ?? entry.fileName;
          entry.progress = value.clamp(0, 100).toDouble();
          entry.status = entry.progress >= 100 ? 'Finishing' : 'Downloading';
        });
      },
      onDownloadCompleted: (path) {
        if (!mounted) {
          return;
        }

        setState(() {
          entry.progress = 100;
          entry.status = 'Completed';
          entry.error = path;
        });
      },
      onDownloadError: (error) {
        if (!mounted) {
          return;
        }

        setState(() {
          entry.status = 'Failed';
          entry.error = error;
        });
      },
    );
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
                                        value: item.progress / 100,
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
                                        value: item.progress / 100,
                                        minHeight: 3,
                                        backgroundColor: Colors.white12,
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
    _DownloadEntry? active;
    for (final item in _downloads) {
      if (item.status == 'Downloading' || item.status == 'Finishing') {
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
              value: active.progress / 100,
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
            if (progress > 0 && progress < 100)
              LinearProgressIndicator(
                value: progress / 100,
                minHeight: 2,
                backgroundColor: Colors.black,
              )
            else
              const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    onPressed: canBack ? _goBack : null,
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: canBack ? Colors.white : Colors.white24,
                  ),
                  IconButton(
                    tooltip: 'Forward',
                    onPressed: canForward ? _goForward : null,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    color: canForward ? Colors.white : Colors.white24,
                  ),
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
                          horizontal: 16,
                          vertical: 12,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: Colors.white54,
                        ),
                        suffixIcon: IconButton(
                          tooltip: 'Search',
                          onPressed: _searchFromField,
                          icon: const Icon(
                            Icons.arrow_upward_rounded,
                            color: Colors.white,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: Colors.white54),
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
                    tooltip: 'Refresh',
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: AdBlockerWebview(
                  url: Uri.parse(homeUrl),
                  shouldBlockAds: true,
                  adBlockerWebviewController: controller,
                  onLoadStart: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      progress = 0;
                      address.text = url.toString();
                    });
                  },
                  onLoadFinished: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      progress = 100;
                      address.text = url.toString();
                    });
                    _recordHistory(url.toString());
                    _syncNavigation();
                  },
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
          ],
        ),
      ),
    );
  }

  Future<void> _searchFromField() => _search(address.text);
}
