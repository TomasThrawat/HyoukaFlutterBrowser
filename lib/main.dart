import 'dart:async';
import 'dart:convert';

import 'package:adblocker_webview/adblocker_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const homeUrl = 'https://www.google.com/';
const _historyKey = 'browser_history';
const _downloadsKey = 'browser_downloads';
const _maxHistoryItems = 100;
const _downloadChannel = MethodChannel('hyouka.browser/native_downloads');
const _adBlockKey = 'ad_block_enabled';
const _browserUserAgent = 'Mozilla/5.0 (Linux; Android 12; CPH2095) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';

const _extraBlockedDomains = <String>[
  'click.a-ads.com',
  'inthedungeons123.lol',
  'nexus-nexus-ba.github.io',
  'readilyprobablechow.shop',
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'adnxs.com',
  'adsrvr.org',
  'advertising.com',
  'amazon-adsystem.com',
  'criteo.com',
  'taboola.com',
  'outbrain.com',
  'pubmatic.com',
  'rubiconproject.com',
  'openx.net',
  'scorecardresearch.com',
  'quantserve.com',
  'casalemedia.com',
  'demdex.net',
  'mathtag.com',
  'rlcdn.com',
];

Future<void> performSingleWebViewBack({
  required Future<bool> Function() canGoBack,
  required Future<void> Function() goBack,
}) async {
  if (await canGoBack()) {
    await goBack();
  }
}

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

String _normalizeDownloadFileName(String value) {
  var result = value.trim();

  while (result.toLowerCase().endsWith('.kkl')) {
    result = result.substring(0, result.length - 4).trim();
  }

  while (result.toLowerCase().endsWith('.crdownload') ||
      result.toLowerCase().endsWith('.download') ||
      result.toLowerCase().endsWith('.part') ||
      result.toLowerCase().endsWith('.tmp')) {
    final lower = result.toLowerCase();
    final extension = lower.endsWith('.crdownload')
        ? '.crdownload'
        : lower.endsWith('.download')
            ? '.download'
            : lower.endsWith('.part')
                ? '.part'
                : '.tmp';
    result = result.substring(0, result.length - extension.length).trim();
  }

  for (final extension in <String>['.apk', '.zip']) {
    while (result.toLowerCase().endsWith(extension + extension)) {
      result = result.substring(0, result.length - extension.length).trim();
    }
  }

  return result;
}

String _formatDownloadBytes(int bytes) {
  if (bytes < 1024) {
    return bytes.toString() + ' B';
  }

  final kb = bytes / 1024;
  if (kb < 1024) {
    return kb.toStringAsFixed(1) + ' KB';
  }

  final mb = kb / 1024;
  if (mb < 1024) {
    return mb.toStringAsFixed(1) + ' MB';
  }

  final gb = mb / 1024;
  return gb.toStringAsFixed(1) + ' GB';
}

bool isLikelyDownloadUrl(Uri uri) {
    const downloadableExtensions = <String>{
      'apk',
      'zip',
      'rar',
      '7z',
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'csv',
      'txt',
      'mp3',
      'wav',
      'm4a',
      'mp4',
      'mkv',
      'avi',
      'mov',
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
    };

    final lastSegment =
        uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.toLowerCase();
    final extensionIndex = lastSegment.lastIndexOf('.');
    final extension =
        extensionIndex >= 0 ? lastSegment.substring(extensionIndex + 1) : '';
    final hasDownloadQuery = uri.queryParameters.keys.any(
      (key) => key.toLowerCase() == 'download',
    );

  return downloadableExtensions.contains(extension) || hasDownloadQuery;
}


String? contentDispositionFileName(String value) {
  final input = value.trim();
  if (input.isEmpty) {
    return null;
  }

  final extended = RegExp(
    r"filename\*\s*=\s*(?:UTF-8''|utf-8'')([^;]+)",
    caseSensitive: false,
  ).firstMatch(input);
  final basic = RegExp(
    r'filename\s*=\s*"([^"]+)"',
    caseSensitive: false,
  ).firstMatch(input);
  final unquoted = basic == null
      ? RegExp(r'filename\s*=\s*([^;]+)', caseSensitive: false).firstMatch(input)
      : null;

  final raw = extended?.group(1) ?? basic?.group(1) ?? unquoted?.group(1);
  if (raw == null) {
    return null;
  }

  var decoded = raw.trim();
  if (decoded.startsWith('"') && decoded.endsWith('"')) {
    decoded = decoded.substring(1, decoded.length - 1);
  }
  try {
    decoded = Uri.decodeComponent(decoded);
  } catch (_) {}

  final sanitized = decoded
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final normalized = _normalizeDownloadFileName(sanitized);
  return normalized.isEmpty ? null : normalized;
}

String downloadFileNameFromMetadata(
  Uri uri, {
  String? contentDisposition,
  String? mimeType,
}) {
  final fromHeader = contentDisposition == null
      ? null
      : contentDispositionFileName(contentDisposition);
  if (fromHeader != null) {
    return fromHeader;
  }

  final fromUrl = downloadFileName(uri);
  if (!fromUrl.endsWith('.html') && !fromUrl.endsWith('.htm')) {
    return fromUrl;
  }

  const mimeExtensions = <String, String>{
    'application/vnd.android.package-archive': '.apk',
    'application/pdf': '.pdf',
    'application/zip': '.zip',
    'application/x-7z-compressed': '.7z',
    'application/x-rar-compressed': '.rar',
    'text/plain': '.txt',
    'text/csv': '.csv',
    'audio/mpeg': '.mp3',
    'audio/wav': '.wav',
    'audio/x-wav': '.wav',
    'audio/mp4': '.m4a',
    'video/mp4': '.mp4',
    'video/x-matroska': '.mkv',
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/gif': '.gif',
    'image/webp': '.webp',
  };
  final extension = mimeExtensions[mimeType?.toLowerCase().trim()];
  final base = _normalizeDownloadFileName(
    uri.pathSegments.isEmpty ? '' : uri.pathSegments.last,
  );
  if (extension != null && base.isNotEmpty && !base.endsWith('.html')) {
    return base + extension;
  }

  final stamp = DateTime.now().millisecondsSinceEpoch;
  return 'hyouka_download_' + stamp.toString() + (extension ?? '.bin');
}

String friendlyDownloadError(String? reason) {
  final value = reason?.trim() ?? '';
  if (RegExp(r'\b403\b').hasMatch(value)) {
    return 'Access denied (403). The server rejected this download request.';
  }
  return value.isEmpty ? 'Download failed.' : value;
}

String downloadFileName(Uri uri) {
  final segment =
      uri.pathSegments.isEmpty ? '' : uri.pathSegments.last.trim();
  final raw = segment.isEmpty ? 'page.html' : segment;
  final sanitized = raw
      .replaceAll(RegExp(r'[<>:"/\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final normalized = _normalizeDownloadFileName(sanitized);

  if (normalized.isNotEmpty) {
    return normalized;
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

  DownloadItem.fromJson(Map<String, dynamic> json)
      : url = json['url']?.toString() ?? '',
        fileName = json['fileName']?.toString() ?? 'browser_download.bin',
        nativeId = (json['nativeId'] as num?)?.toInt() ?? -1 {
    progress = (json['progress'] as num?)?.toDouble() ?? 0;
    status = json['status']?.toString() ?? 'Queued';
    error = json['error']?.toString();
    receivedBytes = (json['receivedBytes'] as num?)?.toInt() ?? 0;
    totalBytes = (json['totalBytes'] as num?)?.toInt() ?? 0;
  }

  final String url;
  final String fileName;
  final int nativeId;
  double progress = 0;
  String status = 'Queued';
  String? error;
  int receivedBytes = 0;
  int totalBytes = 0;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url,
      'fileName': fileName,
      'nativeId': nativeId,
      'progress': progress,
      'status': status,
      'error': error,
      'receivedBytes': receivedBytes,
      'totalBytes': totalBytes,
    };
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AdBlockerWebviewController.instance.initialize(
    FilterConfig(
      filterTypes: [FilterType.easyList, FilterType.adGuard],
      blockedDomains: _extraBlockedDomains,
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
      title: 'Browser',
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
  final ValueNotifier<int> _downloadRevision = ValueNotifier<int>(0);
  final Set<String> _downloadUrls = <String>{};
  late final Future<void> _downloadsReady;
  bool _downloadPollInProgress = false;
  bool _backStepInProgress = false;
  int progress = 0;
  bool _adBlockEnabled = true;
  String? _lastPageUrl;
  bool _googleFallbackUsed = false;
  String? _pendingGoogleSearch;
  int _blockedResourceCount = 0;
  
  @override
  void initState() {
    super.initState();
    controller.resetStatistics();
    _loadHistory();
    _loadAdBlockPreference();
    _downloadsReady = _loadDownloads();
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

  Future<void> _loadDownloads() async {
    final saved = await prefs.getString(_downloadsKey);
    if (saved == null || saved.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(saved);
      if (decoded is! List) {
        return;
      }

      final restored = <DownloadItem>[];
      for (final value in decoded) {
        if (value is! Map) {
          continue;
        }
        final item = DownloadItem.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (item.url.isEmpty || item.nativeId <= 0) {
          continue;
        }
        restored.add(item);
        if (item.status == 'Queued' || item.status == 'Downloading') {
          _downloadUrls.add(item.url);
        }
      }

      if (!mounted || restored.isEmpty) {
        return;
      }

      setState(() {
        _downloads
          ..clear()
          ..addAll(restored);
      });
      _downloadRevision.value++;
      if (restored.any(
        (item) => item.status == 'Queued' || item.status == 'Downloading',
      )) {
        _ensureDownloadPolling();
        await _pollDownloads();
      }
    } catch (_) {
      // Ignore a corrupted local download history and keep the browser usable.
    }
  }

  Future<void> _saveDownloads() async {
    try {
      await prefs.setString(
        _downloadsKey,
        jsonEncode(
          _downloads
              .map((item) => item.toJson())
              .toList(growable: false),
        ),
      );
    } catch (_) {
      // Download UI should remain usable even if local history cannot be saved.
    }
  }

  Future<void> _toggleAdBlock() async {
    final next = !_adBlockEnabled;
    setState(() {
      _adBlockEnabled = next;
    });
    await prefs.setBool(_adBlockKey, next);
    await controller.reload();
  }

  void _showAdBlockStats() {
    final stats = controller.statistics;
    final entries = stats.blockedDomains.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _adBlockEnabled ? 'Ad blocker: ON' : 'Ad blocker: OFF',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Blocked resources: ' +
                      stats.blockedResourceCount.toString(),
                  style: const TextStyle(color: Colors.white70),
                ),
                Text(
                  'Hidden ad rules: ' + stats.cssRulesAppliedCount.toString(),
                  style: const TextStyle(color: Colors.white70),
                ),
                if (entries.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'Top blocked domains',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...entries.take(5).map(
                    (entry) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        entry.key + '  â¢  ' + entry.value.toString(),
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
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
  }

  Future<void> _handleLoadFinished(String? rawUrl) async {
    final url = Uri.tryParse(rawUrl ?? '');
    if (url == null) {
      return;
    }

    if (url.host == 'www.google.com' &&
        url.path == '/search' &&
        !_googleFallbackUsed) {
      final title = (await controller.getTitle() ?? '').toLowerCase();
      final challenge = title.contains('unusual traffic') ||
          title.contains('about this page') ||
          title.contains('ÙØ¹ÙÙÙØ§Øª Ø¹Ù ÙØ°Ù Ø§ÙØµÙØ­Ø©') ||
          title.contains('Ø­Ø±ÙØ© ÙØ±ÙØ± ØºÙØ± ÙØ¹ØªØ§Ø¯Ø©');

      if (challenge) {
        final query = _pendingGoogleSearch ?? url.queryParameters['q'];
        if (query != null && query.isNotEmpty && mounted) {
          _googleFallbackUsed = true;
          _pendingGoogleSearch = null;
          final fallback =
              'https://www.bing.com/search?q=' + Uri.encodeQueryComponent(query);
          await controller.loadUrl(fallback);
          _showMessage('Google Ø·ÙØ¨ ØªØ­ÙÙ ÙÙØ´Ø¨ÙØ©Ø ØªÙ ØªØ­ÙÙÙ Ø§ÙØ¨Ø­Ø« ØªÙÙØ§Ø¦ÙØ§Ù.');
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
      _blockedResourceCount = controller.statistics.blockedResourceCount;
    });
    _lastPageUrl = url.toString();
    _recordHistory(url.toString());
  }

  Future<void> _reload() async {
    await controller.reload();
  }

  Future<void> _goBackOneStep() async {
    if (_backStepInProgress) {
      return;
    }

    _backStepInProgress = true;
    try {
      await performSingleWebViewBack(
        canGoBack: controller.canGoBack,
        goBack: controller.goBack,
      );
    } finally {
      _backStepInProgress = false;
    }
  }

  Future<void> _handleWebViewDownload(
    String url,
    String userAgent,
    String contentDisposition,
    String mimetype,
    int contentLength,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }

    await _trackDownloadUrl(
      uri,
      fileName: downloadFileNameFromMetadata(
        uri,
        contentDisposition: contentDisposition,
        mimeType: mimetype,
      ),
      referer: _lastPageUrl,
      userAgent: userAgent,
      mimeType: mimetype,
      contentLength: contentLength,
    );
  }

  Future<void> _trackDownloadUrl(
    Uri uri, {
    String? fileName,
    String? referer,
    String? userAgent,
    String? mimeType,
    int? contentLength,
  }) async {
    await _downloadsReady;
    if (!mounted) {
      return;
    }

    final key = uri.toString();
    final shouldTrackUrl = isLikelyDownloadUrl(uri) || fileName != null;
    if (!shouldTrackUrl) {
      return;
    }

    final hasActiveDuplicate = _downloads.any(
      (item) =>
          item.url == key &&
          (item.status == 'Queued' || item.status == 'Downloading'),
    );
    if (hasActiveDuplicate) {
      return;
    }

    _downloadUrls.remove(key);
    if (!_downloadUrls.add(key)) {
      return;
    }

    final effectiveFileName = fileName ??
        downloadFileNameFromMetadata(
          uri,
          mimeType: mimeType,
        );

    try {
      final nativeId = await _downloadChannel.invokeMethod<int>(
        'startDownload',
        <String, dynamic>{
          'url': key,
          'fileName': effectiveFileName,
          'referer': referer,
          'userAgent': userAgent ?? _browserUserAgent,
          'mimeType': mimeType,
          'contentLength': contentLength,
        },
      );

      if (!mounted || nativeId == null) {
        _downloadUrls.remove(key);
        return;
      }

      final item = DownloadItem(
        url: key,
        fileName: effectiveFileName,
        nativeId: nativeId,
      );

      setState(() {
        _downloads.insert(0, item);
      });
      _downloadRevision.value++;
      unawaited(_saveDownloads());
      _ensureDownloadPolling();
    } on PlatformException catch (error) {
      _downloadUrls.remove(key);
      _showMessage(friendlyDownloadError(error.message));
    }
  }

  void _ensureDownloadPolling() {
    if (_downloadPoller != null) {
      return;
    }

    _downloadPoller = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollDownloads(),
    );
  }

  Future<void> _pollDownloads() async {
    if (_downloadPollInProgress) {
      return;
    }
    _downloadPollInProgress = true;

    try {
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

        final previousStatus = item.status;
        setState(() {
          item.status = nextStatus;
          item.receivedBytes = received;
          item.totalBytes = total;
          item.progress = nextStatus == 'Completed' ? 100 : nextProgress;
          item.error = friendlyDownloadError(data['reason']?.toString());
        });
        if (nextStatus == 'Completed' || nextStatus == 'Failed') {
          _downloadUrls.remove(item.url);
        }
        if (nextStatus == 'Failed' &&
            previousStatus != 'Failed' &&
            mounted) {
          _showMessage(item.error ?? 'Download failed.');
        }
        _downloadRevision.value++;
        } on PlatformException catch (error) {
          if (!mounted) {
            continue;
          }

          setState(() {
            item.status = 'Failed';
            item.error = error.message ?? 'Download status unavailable';
          });
          _downloadRevision.value++;
        }
      }

      if (mounted) {
        unawaited(_saveDownloads());
      }
    } finally {
      _downloadPollInProgress = false;
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

  void _showDownloads() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black,
      isScrollControlled: true,
      builder: (sheetContext) {
        return ValueListenableBuilder<int>(
          valueListenable: _downloadRevision,
          builder: (context, _, __) {
            final activeCount = _downloads
                .where(
                  (item) =>
                      item.status == 'Queued' ||
                      item.status == 'Downloading',
                )
                .length;
            final height = MediaQuery.sizeOf(context).height * 0.75;
            final summary = _downloads.isEmpty
                ? 'No downloads'
                : _downloads.length.toString() +
                    ' total' +
                    (activeCount > 0
                        ? ' â¢ ' + activeCount.toString() + ' active'
                        : '');

            return SafeArea(
              child: SizedBox(
                height: height.clamp(260.0, 600.0),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Downloads',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            summary,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(height: 1, color: Colors.white12),
                      const SizedBox(height: 4),
                      Expanded(
                        child: _downloads.isEmpty
                            ? const Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.download_outlined,
                                      color: Colors.white38,
                                      size: 36,
                                    ),
                                    SizedBox(height: 10),
                                    Text(
                                      'No downloads yet.',
                                      style: TextStyle(
                                        color: Colors.white54,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                itemCount: _downloads.length,
                                separatorBuilder: (context, index) =>
                                    const Divider(
                                  height: 1,
                                  color: Colors.white12,
                                ),
                                itemBuilder: (context, index) {
                                  final item = _downloads[index];
                                  final isActive =
                                      item.status == 'Queued' ||
                                      item.status == 'Downloading';
                                  final percent = item.progress.round();

                                  Widget leading;
                                  if (isActive) {
                                    leading = SizedBox(
                                      width: 42,
                                      height: 42,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          CircularProgressIndicator(
                                            value: item.totalBytes > 0
                                                ? item.progress / 100
                                                : null,
                                            strokeWidth: 2.5,
                                          ),
                                          Text(
                                            percent.toString() + '%',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 8,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  } else {
                                    leading = Icon(
                                      item.status == 'Completed'
                                          ? Icons.check_circle_outline_rounded
                                          : item.status == 'Failed'
                                              ? Icons.error_outline_rounded
                                              : Icons.download_done_rounded,
                                      color: Colors.white70,
                                      size: 28,
                                    );
                                  }

                                  final detail =
                                      isActive && item.totalBytes > 0
                                          ? item.status +
                                              ' â¢ ' +
                                              _formatDownloadBytes(
                                                item.receivedBytes,
                                              ) +
                                              ' / ' +
                                              _formatDownloadBytes(
                                                item.totalBytes,
                                              )
                                          : item.status == 'Failed' &&
                                                  item.error != null
                                              ? item.error!
                                              : item.status;

                                  return ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 0,
                                      vertical: 4,
                                    ),
                                    leading: leading,
                                    title: Text(
                                      item.fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      detail,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                      ),
                                    ),
                                    trailing: isActive
                                        ? Text(
                                            percent.toString() + '%',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
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

  Widget _downloadButton() {
    DownloadItem? active;
    for (final item in _downloads) {
      if (item.status == 'Queued' || item.status == 'Downloading') {
        active = item;
        break;
      }
    }

    return Semantics(
      button: true,
      label: 'Downloads',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _showDownloads,
          child: active == null
              ? const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Icon(Icons.download_rounded),
                  ),
                )
              : SizedBox(
                  width: 82,
                  height: 40,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: active.totalBytes > 0
                                  ? active.progress / 100
                                  : null,
                              strokeWidth: 2.5,
                            ),
                            Text(
                              active.progress.round().toString() + '%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          active.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 8,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _downloadPoller?.cancel();
    _downloadRevision.dispose();
    address.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_goBackOneStep());
        }
      },
      child: Scaffold(
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
                  userAgent: _browserUserAgent,
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
                  onDownloadStart: _handleWebViewDownload,
                  onUrlChanged: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      address.text = url?.toString() ?? '';
                    });
                    final parsedUrl = url == null ? null : Uri.tryParse(url);
                    if (parsedUrl != null) {
                      if (!isLikelyDownloadUrl(parsedUrl)) {
                        _lastPageUrl = parsedUrl.toString();
                      }
                      unawaited(_trackDownloadUrl(parsedUrl));
                    }
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
                    GestureDetector(
                      onLongPress: _showAdBlockStats,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            tooltip: _adBlockEnabled
                                ? 'Disable ad blocker'
                                : 'Enable ad blocker',
                            onPressed: _toggleAdBlock,
                            icon: Icon(
                              _adBlockEnabled
                                  ? Icons.shield_rounded
                                  : Icons.shield_outlined,
                              color: _adBlockEnabled
                                  ? Colors.white
                                  : Colors.white38,
                            ),
                          ),
                        if (_adBlockEnabled && _blockedResourceCount > 0)
                          Positioned(
                            right: 4,
                            top: 2,
                            child: IgnorePointer(
                              child: Container(
                                constraints: const BoxConstraints(
                                  minWidth: 16,
                                  minHeight: 16,
                                ),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  _blockedResourceCount > 999
                                      ? '999+'
                                      : '$_blockedResourceCount',
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 8,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
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
      ),
    );
  }
}