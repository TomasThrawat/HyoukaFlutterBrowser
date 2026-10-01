from pathlib import Path
import re

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
    raise SystemExit(
        "Missing adblock domains: " + ", ".join(missing_domains)
    )

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
        "Browser download implementation incomplete: "
        + ", ".join(missing_main)
    )
MAIN.write_text(source)

pubcache = Path.home() / ".pub-cache" / "hosted" / "pub.dev"
android_candidates = sorted(pubcache.glob("webview_flutter_android-4.14.1"))
if len(android_candidates) != 1:
    raise SystemExit("Expected webview_flutter_android-4.14.1 exactly once")

android_root = android_candidates[0] / "lib" / "src"
delegate_candidates = []
for dart_file in sorted(android_root.rglob("*.dart")):
    text = dart_file.read_text()
    if (
        "class AndroidNavigationDelegate" in text
        and "androidDownloadListener" in text
        and "onDownloadStart:" in text
    ):
        delegate_candidates.append(dart_file)

if len(delegate_candidates) != 1:
    raise SystemExit(
        "Expected exactly one AndroidNavigationDelegate source, found "
        + str(len(delegate_candidates))
    )

delegate = delegate_candidates[0]
cs = delegate.read_text()

field = """  void Function(
    String url,
    String userAgent,
    String contentDisposition,
    String mimetype,
    int contentLength,
  )? _onDownloadStart;
"""

if "_onDownloadStart;" not in cs:
    class_match = re.search(
        r"class\s+AndroidNavigationDelegate[^\{]*\{",
        cs,
    )
    if class_match is None:
        raise SystemExit("AndroidNavigationDelegate class anchor not found")
    cs = (
        cs[: class_match.end()]
        + "\n"
        + field
        + cs[class_match.end() :]
    )

callback_marker = "onDownloadStart:"
callback_pos = cs.find(callback_marker)
if callback_pos < 0:
    raise SystemExit("AndroidNavigationDelegate download callback not found")

brace_pos = cs.find("{", callback_pos)
if brace_pos < 0:
    raise SystemExit("AndroidNavigationDelegate download callback body not found")

callback_header = cs[callback_pos:brace_pos]
callback_names = (
    "url",
    "userAgent",
    "contentDisposition",
    "mimetype",
    "contentLength",
)
missing_callback_names = [
    name for name in callback_names if re.search(r"\b" + name + r"\b", callback_header) is None
]
if missing_callback_names:
    raise SystemExit(
        "Unexpected download callback signature: "
        + ", ".join(missing_callback_names)
    )

if "final callback = _onDownloadStart;" not in cs:
    if "weakThis" in cs[max(0, callback_pos - 1000):callback_pos]:
        receiver = "weakThis.target?._onDownloadStart"
        null_guard = """        final callback = weakThis.target?._onDownloadStart;
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
"""
    else:
        receiver = "this._onDownloadStart"
        null_guard = """        final callback = this._onDownloadStart;
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
"""
    cs = cs[:brace_pos + 1] + "
" + null_guard + cs[brace_pos + 1 :]

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
    getter_match = re.search(
        r"  (?:android_webview\.)?DownloadListener get androidDownloadListener\s*=>",
        cs,
    )
    if getter_match is None:
        raise SystemExit("AndroidNavigationDelegate download getter not found")
    cs = cs[:getter_match.start()] + signature + cs[getter_match.start() :]

for required in (
    "Future<void> setOnDownloadStart(",
    "_onDownloadStart;",
    "onDownloadStart:",
    "androidDownloadListener",
):
    if required not in cs:
        raise SystemExit("Android delegate patch incomplete: " + required)

delegate.write_text(cs)

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
    constructor_anchor = "    this.onUrlChanged,"
    if constructor_anchor not in ws:
        raise SystemExit("AdBlockerWebview constructor anchor not found")
    ws = ws.replace(
        constructor_anchor,
        constructor_anchor + "\n    this.onDownloadStart,",
        1,
    )

if "? onDownloadStart;" not in ws:
    field_anchor = "  final void Function(String? url)? onUrlChanged;"
    if field_anchor not in ws:
        raise SystemExit("AdBlockerWebview callback field anchor not found")
    ws = ws.replace(
        field_anchor,
        field_anchor + "\n\n" + callback_field.rstrip("\n"),
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
    target = "    await _webViewController.setNavigationDelegate(navigationDelegate);"
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

print("Robust download listener patch applied to", delegate)
