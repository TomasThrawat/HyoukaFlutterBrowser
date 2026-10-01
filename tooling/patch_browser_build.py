from pathlib import Path

MAIN = Path("lib/main.dart")
source = MAIN.read_text()

required_domains = [
    "readilyprobablechow.shop",
    "nexus-nexus-ba.github.io",
    "inthedungeons123.lol",
    "melbetegypt.com",
    "hemihydro.com",
    "werefilledwit.org",
    "profitableratecpm.com",
    "engridfanlike.com",
    "pubfuture.com",
    "highcpmrevenuegate.com",
    "track.cpvtrack.com",
    "go.strp.tw",
    "clickadu.com",
    "propellerads.com",
    "popads.net",
    "popcash.net",
    "adcash.com",
    "exoclick.com",
    "effectivegatecpm.com",
    "effectiveratecpm.com",
    "cpmrevenuegate.com",
    "revenuecpmgate.com",
    "highrevenuenetwork.com",
    "professionaltrafficmonitor.com",
    "sourshaped.com",
    "skinnycrawlinglax.com",
    "agitatechampionship.com",
    "beggingload.com",
    "creative-sb1.com",
    "gatetotrustednetwork.com",
    "heartilyscales.com",
    "preferencenail.com",
]
missing_domains = [domain for domain in required_domains if domain not in source]
if missing_domains:
    raise SystemExit("Missing adblock domains: " + ", ".join(missing_domains))

required_main = (
    "onDownloadStart:",
    "contentDispositionFileName(",
    "downloadFileNameFromMetadata(",
    "friendlyDownloadError(",
    "'referer': referer",
    "'userAgent': userAgent ?? _browserUserAgent",
    "'mimeType': mimeType",
    "String? _lastPageUrl;",
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
    raise SystemExit("Expected webview_flutter_android-4.14.1 exactly once")

controller = android_candidates[0] / "lib" / "src" / "android_webview_controller.dart"
cs = controller.read_text()

field = """  void Function(
    String url,
    String userAgent,
    String contentDisposition,
    String mimetype,
    int contentLength,
  )? _onDownloadStart;
"""
if "_onDownloadStart;" not in cs:
    anchor = "  late final android_webview.DownloadListener _downloadListener;
"
    if anchor not in cs:
        raise SystemExit(
            "AndroidNavigationDelegate download listener declaration not found"
        )
    cs = cs.replace(anchor, field + "
" + anchor, 1)

old_callback = """      onDownloadStart: (
        _,
        String url,
        String userAgent,
        String contentDisposition,
        String mimetype,
        int contentLength,
      ) {
        if (weakThis.target != null) {
          weakThis.target?._handleNavigation(url, isForMainFrame: true);
        }
      },
"""
new_callback = """      onDownloadStart: (
        _,
        String url,
        String userAgent,
        String contentDisposition,
        String mimetype,
        int contentLength,
      ) {
        final callback = weakThis.target?._onDownloadStart;
        if (callback != null) {
          callback(
            url,
            userAgent,
            contentDisposition,
            mimetype,
            contentLength,
          );
          return;
        }
        weakThis.target?._handleNavigation(url, isForMainFrame: true);
      },
"""
if old_callback in cs:
    cs = cs.replace(old_callback, new_callback, 1)
elif "final callback = weakThis.target?._onDownloadStart;" not in cs:
    raise SystemExit("AndroidNavigationDelegate download callback body not found")

signature = """  Future<void> setOnDownloadStart(
    void Function(
      String url,
      String userAgent,
      String contentDisposition,
      String mimetype,
      int contentLength,
    ) onDownloadStart,
  ) async {
    _onDownloadStart = onDownloadStart;
  }

"""
if "Future<void> setOnDownloadStart(" not in cs:
    getter = """  android_webview.DownloadListener get androidDownloadListener =>
      _downloadListener;
"""
    if getter not in cs:
        raise SystemExit("AndroidNavigationDelegate download getter not found")
    cs = cs.replace(getter, getter + "
" + signature, 1)

for required in (
    "Future<void> setOnDownloadStart(",
    "_onDownloadStart;",
    "final callback = weakThis.target?._onDownloadStart;",
    "callback(",
):
    if required not in cs:
        raise SystemExit("Android delegate patch incomplete: " + required)

controller.write_text(cs)

adblock_candidates = sorted(pubcache.glob("adblocker_webview-2.3.0"))
if len(adblock_candidates) != 1:
    raise SystemExit("Expected adblocker_webview-2.3.0 exactly once")

widget = adblock_candidates[0] / "lib" / "src" / "adblocker_webview.dart"
ws = widget.read_text()

callback_field = """  /// Invoked when Android WebView reports a download request.
  final void Function(
    String url,
    String userAgent,
    String contentDisposition,
    String mimetype,
    int contentLength,
  )? onDownloadStart;
"""
if "this.onDownloadStart," not in ws:
    constructor_anchor = "    this.onUrlChanged,
"
    if constructor_anchor not in ws:
        raise SystemExit("AdBlockerWebview constructor anchor not found")
    ws = ws.replace(
        constructor_anchor,
        constructor_anchor + "    this.onDownloadStart,
",
        1,
    )

if "? onDownloadStart;" not in ws:
    field_anchor = "  final void Function(String? url)? onUrlChanged;
"
    if field_anchor not in ws:
        raise SystemExit("AdBlockerWebview callback field anchor not found")
    ws = ws.replace(
        field_anchor,
        field_anchor + "
" + callback_field,
        1,
    )

listener_bridge = """    if (_webViewController.platform is AndroidWebViewController &&
        navigationDelegate.platform is AndroidNavigationDelegate &&
        widget.onDownloadStart != null) {
      await (navigationDelegate.platform as AndroidNavigationDelegate)
          .setOnDownloadStart(widget.onDownloadStart!);
    }

"""
if "setOnDownloadStart(widget.onDownloadStart!)" not in ws:
    target = "    await _webViewController.setNavigationDelegate(navigationDelegate);
"
    if target not in ws:
        raise SystemExit("AdBlockerWebview navigation delegate target not found")
    ws = ws.replace(target, listener_bridge + target, 1)

for required in (
    "this.onDownloadStart,",
    "? onDownloadStart;",
    "setOnDownloadStart(widget.onDownloadStart!)",
):
    if required not in ws:
        raise SystemExit("AdBlockerWebview patch incomplete: " + required)

widget.write_text(ws)

print("download listener architecture patch applied")
