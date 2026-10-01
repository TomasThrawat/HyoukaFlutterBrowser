from pathlib import Path
import re

NL = chr(10)
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

missing_domains = [d for d in required_domains if d not in source]
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
missing_main = [x for x in required_main if x not in source]
if missing_main:
    raise SystemExit("Browser download implementation incomplete: " + ", ".join(missing_main))
MAIN.write_text(source)

pubcache = Path.home() / ".pub-cache" / "hosted" / "pub.dev"

android_candidates = sorted(pubcache.glob("webview_flutter_android-4.14.1"))
if len(android_candidates) != 1:
    raise SystemExit("Expected webview_flutter_android-4.14.1 exactly once")

android_root = android_candidates[0] / "lib" / "src"
delegate_candidates = []
for dart_file in sorted(android_root.rglob("*.dart")):
    text = dart_file.read_text()
    if "class AndroidNavigationDelegate extends PlatformNavigationDelegate" in text and "androidDownloadListener" in text and "onDownloadStart:" in text:
        delegate_candidates.append(dart_file)

if len(delegate_candidates) != 1:
    raise SystemExit("Expected exactly one AndroidNavigationDelegate source, found " + str(len(delegate_candidates)))

delegate = delegate_candidates[0]
cs = delegate.read_text()

field = NL.join([
    "  void Function(",
    "    String url,",
    "    String userAgent,",
    "    String contentDisposition,",
    "    String mimetype,",
    "    int contentLength,",
    "  )? _onDownloadStart;",
])

if "_onDownloadStart;" not in cs:
    class_match = re.search(r"class\s+AndroidNavigationDelegate\s+extends\s+PlatformNavigationDelegate\s*\{", cs)
    if class_match is None:
        raise SystemExit("AndroidNavigationDelegate class anchor not found")
    cs = cs[:class_match.end()] + NL + field + NL + cs[class_match.end():]

callback_pos = cs.find("onDownloadStart:")
if callback_pos < 0:
    raise SystemExit("AndroidNavigationDelegate download callback not found")
brace_pos = cs.find("{", callback_pos)
if brace_pos < 0:
    raise SystemExit("AndroidNavigationDelegate download callback body not found")

header = cs[callback_pos:brace_pos]
for name in ("url", "userAgent", "contentDisposition", "mimetype", "contentLength"):
    if re.search(r"\b" + name + r"\b", header) is None:
        raise SystemExit("Unexpected download callback signature; missing " + name)

if "final callback = this._onDownloadStart;" not in cs:
    injection = NL.join([
        "        final callback = this._onDownloadStart;",
        "        if (callback != null) {",
        "          callback(",
        "            url,",
        "            userAgent,",
        "            contentDisposition,",
        "            mimetype,",
        "            contentLength,",
        "          );",
        "          return;",
        "        }",
    ])
    cs = cs[:brace_pos + 1] + NL + injection + cs[brace_pos + 1:]

signature = NL.join([
    "  Future<void> setOnDownloadStart(",
    "    void Function(",
    "      String url,",
    "      String userAgent,",
    "      String contentDisposition,",
    "      String mimetype,",
    "      int contentLength,",
    "    ) onDownloadStart,",
    "  ) async {",
    "    _onDownloadStart = onDownloadStart;",
    "  }",
])

if "Future<void> setOnDownloadStart(" not in cs:
    getter_match = re.search(
        r"  (?:android_webview\.)?DownloadListener\s+get\s+androidDownloadListener\s*=>",
        cs,
    )
    if getter_match is None:
        raise SystemExit("AndroidNavigationDelegate download getter not found")
    cs = cs[:getter_match.start()] + signature + NL + NL + cs[getter_match.start():]

for required in ("Future<void> setOnDownloadStart(", "_onDownloadStart;", "onDownloadStart:", "androidDownloadListener"):
    if required not in cs:
        raise SystemExit("AndroidNavigationDelegate patch incomplete: " + required)

delegate.write_text(cs)

adblock_candidates = sorted(pubcache.glob("adblocker_webview-2.3.0"))
if len(adblock_candidates) != 1:
    raise SystemExit("Expected adblocker_webview-2.3.0 exactly once")

widget = adblock_candidates[0] / "lib" / "src" / "adblocker_webview.dart"
ws = widget.read_text()

callback_field = NL.join([
    "  /// Invoked when Android WebView reports a download request.",
    "  final void Function(",
    "    String url,",
    "    String userAgent,",
    "    String contentDisposition,",
    "    String mimetype,",
    "    int contentLength,",
    "  )? onDownloadStart;",
])

if "this.onDownloadStart," not in ws:
    constructor_anchor = "    this.onUrlChanged,"
    if constructor_anchor not in ws:
        raise SystemExit("AdBlockerWebview constructor anchor not found")
    ws = ws.replace(constructor_anchor, constructor_anchor + NL + "    this.onDownloadStart,", 1)

if "? onDownloadStart;" not in ws:
    field_anchor = "  final void Function(String? url)? onUrlChanged;"
    if field_anchor not in ws:
        raise SystemExit("AdBlockerWebview callback field anchor not found")
    ws = ws.replace(field_anchor, field_anchor + NL + NL + callback_field, 1)

listener_bridge = NL.join([
    "    if (_webViewController.platform is AndroidWebViewController &&",
    "        navigationDelegate.platform is AndroidNavigationDelegate &&",
    "        widget.onDownloadStart != null) {",
    "      unawaited(",
    "        (navigationDelegate.platform as AndroidNavigationDelegate)",
    "            .setOnDownloadStart(widget.onDownloadStart!),",
    "      );",
    "    }",
])

if "setOnDownloadStart(widget.onDownloadStart!)" not in ws:
    targets = (
        "    await _webViewController.setNavigationDelegate(navigationDelegate);",
        "    _webViewController.setNavigationDelegate(navigationDelegate);",
    )
    target = next((candidate for candidate in targets if candidate in ws), None)
    if target is None:
        raise SystemExit("AdBlockerWebview navigation delegate target not found")
    ws = ws.replace(target, listener_bridge + NL + target, 1)

for required in ("this.onDownloadStart,", "? onDownloadStart;", "setOnDownloadStart(widget.onDownloadStart!)"):
    if required not in ws:
        raise SystemExit("AdBlockerWebview patch incomplete: " + required)

widget.write_text(ws)

print("download listener patch applied")
