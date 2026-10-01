from pathlib import Path

MAIN = Path("lib/main.dart")
source = MAIN.read_text()

required_domains = [
    "readilyprobablechow.shop", "nexus-nexus-ba.github.io", "inthedungeons123.lol",
    "melbetegypt.com", "hemihydro.com", "werefilledwit.org",
    "profitableratecpm.com", "engridfanlike.com", "pubfuture.com",
    "highcpmrevenuegate.com", "track.cpvtrack.com", "go.strp.tw",
    "clickadu.com", "propellerads.com", "popads.net", "popcash.net",
    "adcash.com", "exoclick.com", "effectivegatecpm.com", "effectiveratecpm.com",
    "cpmrevenuegate.com", "revenuecpmgate.com", "highrevenuenetwork.com",
    "professionaltrafficmonitor.com", "sourshaped.com", "skinnycrawlinglax.com",
    "agitatechampionship.com", "beggingload.com", "creative-sb1.com",
    "gatetotrustednetwork.com", "heartilyscales.com", "preferencenail.com",
]
for domain in required_domains:
    if domain not in source:
        raise SystemExit("Missing adblock domain: " + domain)

required_main = (
    "onDownloadStart:", "contentDispositionFileName(",
    "downloadFileNameFromMetadata(", "friendlyDownloadError(",
    "'referer': referer", "'userAgent': userAgent ?? _browserUserAgent",
    "'mimeType': mimeType",
)
missing = [item for item in required_main if item not in source]
if missing:
    raise SystemExit("Browser download implementation incomplete: " + ", ".join(missing))
MAIN.write_text(source)

pubcache = Path.home() / ".pub-cache" / "hosted" / "pub.dev"

android_candidates = sorted(pubcache.glob("webview_flutter_android-4.14.1"))
if len(android_candidates) != 1:
    raise SystemExit("Expected webview_flutter_android-4.14.1 exactly once")
controller = android_candidates[0] / "lib" / "src" / "android_webview_controller.dart"
cs = controller.read_text()
method = r"""
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
if "Future<void> setOnDownloadStart(" not in cs:
    anchor = """  @override
  Future<void> runJavaScript(String javaScript) {
"""
    if anchor not in cs:
        raise SystemExit("webview controller insertion anchor not found")
    cs = cs.replace(anchor, method + anchor, 1)
controller.write_text(cs)

adblock_candidates = sorted(pubcache.glob("adblocker_webview-2.3.0"))
if len(adblock_candidates) != 1:
    raise SystemExit("Expected adblocker_webview-2.3.0 exactly once")
widget = adblock_candidates[0] / "lib" / "src" / "adblocker_webview.dart"
ws = widget.read_text()

if "this.onDownloadStart," not in ws:
    anchor = "    this.onUrlChanged,\n"
    if anchor not in ws:
        raise SystemExit("adblocker constructor anchor not found")
    ws = ws.replace(anchor, anchor + "    this.onDownloadStart,\n", 1)

field = """  /// Invoked when Android WebView reports a download request.
  final void Function(
    String url,
    String userAgent,
    String contentDisposition,
    String mimetype,
    int contentLength,
  )? onDownloadStart;
"""
if "String contentDisposition," not in ws:
    anchor = "  final void Function(String? url)? onUrlChanged;
"
    if anchor not in ws:
        raise SystemExit("adblocker callback field anchor not found")
    ws = ws.replace(anchor, anchor + "\n" + field, 1)

listener = """    if (_webViewController.platform is AndroidWebViewController &&
        widget.onDownloadStart != null) {
      await (_webViewController.platform as AndroidWebViewController)
          .setOnDownloadStart(widget.onDownloadStart!);
    }

"""
if "setOnDownloadStart(widget.onDownloadStart!)" not in ws:
    anchor = "    _setNavigationDelegate();\n"
    if anchor not in ws:
        raise SystemExit("adblocker navigation anchor not found")
    ws = ws.replace(anchor, anchor + listener, 1)

widget.write_text(ws)
print("active browser hardening patch applied")
