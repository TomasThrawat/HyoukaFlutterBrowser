from pathlib import Path

MAIN = Path("lib/main.dart")
source = MAIN.read_text()

domains = (
    "  'readilyprobablechow.shop',",
    "  'nexus-nexus-ba.github.io',",
    "  'inthedungeons123.lol',",
)
anchor = "  'click.a-ads.com',"
if anchor not in source:
    raise SystemExit("Adblock denylist anchor not found")
for domain in domains:
    if domain not in source:
        source = source.replace(anchor, anchor + "\n" + domain, 1)

ua_declaration = (
    "const _browserUserAgent = "
    "'Mozilla/5.0 (Linux; Android 12; CPH2095) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/140.0.0.0 Mobile Safari/537.36';"
)
if "const _browserUserAgent =" not in source:
    source = source.replace(
        "const _adBlockKey = 'ad_block_enabled';",
        "const _adBlockKey = 'ad_block_enabled';\n" + ua_declaration,
        1,
    )

if "String? _lastPageUrl;" not in source:
    source = source.replace(
        "  bool _adBlockEnabled = true;",
        "  bool _adBlockEnabled = true;\n  String? _lastPageUrl;",
        1,
    )

required_main = (
    "onDownloadStart:",
    "contentDispositionFileName(",
    "downloadFileNameFromMetadata(",
    "friendlyDownloadError(",
    "'referer': referer",
    "'userAgent': userAgent ?? _browserUserAgent",
    "'mimeType': mimeType",
)
missing_main = [item for item in required_main if item not in source]
if missing_main:
    raise SystemExit(
        "Browser download implementation incomplete: " + ", ".join(missing_main)
    )

MAIN.write_text(source)


pubcache = Path.home() / ".pub-cache" / "hosted" / "pub.dev"

android_candidates = sorted(pubcache.glob("webview_flutter_android-4.14.1"))
if len(android_candidates) != 1:
    raise SystemExit(
        "Expected exactly one webview_flutter_android-4.14.1 package, found "
        + str(len(android_candidates))
    )

android_controller = (
    android_candidates[0] / "lib" / "src" / "android_webview_controller.dart"
)
if not android_controller.is_file():
    raise SystemExit(
        "webview_flutter_android controller source not found: "
        + str(android_controller)
    )

controller_source = android_controller.read_text()
if "Future<void> setOnDownloadStart(" not in controller_source:
    controller_method = r"""
  /// Registers a callback for native Android WebView downloads.
  Future<void> setOnDownloadStart(
    void Function(
      String url,
      String userAgent,
      String contentDisposition,
      String mimetype,
      int contentLength,
    )? onDownloadStart,
  ) async {
    if (onDownloadStart == null) {
      await _webView.setDownloadListener(null);
      return;
    }

    final listener = android_webview.DownloadListener(
      onDownloadStart: (
        _,
        String url,
        String userAgent,
        String contentDisposition,
        String mimetype,
        int contentLength,
      ) {
        onDownloadStart(
          url,
          userAgent,
          contentDisposition,
          mimetype,
          contentLength,
        );
      },
    );
    await _webView.setDownloadListener(listener);
  }

"""
    anchor = """  @override
  Future<void> runJavaScript(String javaScript) {
"""
    if anchor not in controller_source:
        raise SystemExit("webview_flutter_android controller insertion anchor not found")
    controller_source = controller_source.replace(
        anchor, controller_method + anchor, 1
    )

for required in (
    "Future<void> setOnDownloadStart(",
    "android_webview.DownloadListener(",
    "_webView.setDownloadListener(listener)",
):
    if required not in controller_source:
        raise SystemExit("Android controller patch incomplete: " + required)
android_controller.write_text(controller_source)

adblock_candidates = sorted(pubcache.glob("adblocker_webview-2.3.0"))
if len(adblock_candidates) != 1:
    raise SystemExit(
        "Expected exactly one adblocker_webview-2.3.0 package, found "
        + str(len(adblock_candidates))
    )

widget = adblock_candidates[0] / "lib" / "src" / "adblocker_webview.dart"
if not widget.is_file():
    raise SystemExit("adblocker_webview widget source not found: " + str(widget))

w = widget.read_text()
if "this.onDownloadStart," not in w:
    anchor = "    this.onUrlChanged," + chr(10)
    if anchor not in w:
        raise SystemExit("adblocker constructor anchor not found")
    w = w.replace(anchor, anchor + "    this.onDownloadStart," + chr(10), 1)

field = """  /// Invoked when Android WebView reports a download request.
  final void Function(
    String url,
    String userAgent,
    String contentDisposition,
    String mimetype,
    int contentLength,
  )? onDownloadStart;
"""
if field not in w:
    anchor = "  final void Function(String? url)? onUrlChanged;" + chr(10)
    if anchor not in w:
        raise SystemExit("adblocker callback field anchor not found")
    w = w.replace(anchor, anchor + chr(10) + field, 1)

listener_call = """    if (_webViewController.platform is AndroidWebViewController &&
        widget.onDownloadStart != null) {
      await (_webViewController.platform as AndroidWebViewController)
          .setOnDownloadStart(widget.onDownloadStart!);
    }

"""
if "setOnDownloadStart(widget.onDownloadStart!)" not in w:
    anchor = "    _setNavigationDelegate();" + chr(10)
    if anchor not in w:
        raise SystemExit("adblocker navigation delegate anchor not found")
    w = w.replace(anchor, anchor + listener_call, 1)

for required in (
    "this.onDownloadStart,",
    "setOnDownloadStart(widget.onDownloadStart!)",
):
    if required not in w:
        raise SystemExit("adblocker patch incomplete: " + required)

widget.write_text(w)
print("supported listener patcher ready")
