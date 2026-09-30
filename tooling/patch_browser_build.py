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
candidates = sorted(pubcache.glob("adblocker_webview-2.3.0"))
if len(candidates) != 1:
    raise SystemExit(
        "Expected exactly one adblocker_webview-2.3.0 package, found "
        + str(len(candidates))
    )

widget = candidates[0] / "lib" / "src" / "adblocker_webview.dart"
if not widget.is_file():
    raise SystemExit("adblocker_webview 2.3.0 widget source not found: " + str(widget))

w = widget.read_text()

if "this.onDownloadStart," not in w:
    constructor_anchor = "    this.onUrlChanged,\n"
    if constructor_anchor not in w:
        raise SystemExit("DownloadListener constructor anchor not found")
    w = w.replace(
        constructor_anchor,
        "    this.onUrlChanged,\n    this.onDownloadStart,\n",
        1,
    )

if "final DownloadListener? onDownloadStart;" not in w:
    field_anchor = "  final void Function(String? url)? onUrlChanged;\n"
    if field_anchor not in w:
        raise SystemExit("DownloadListener field anchor not found")
    w = w.replace(
        field_anchor,
        field_anchor
        + "\n"
        + "  /// Invoked when Android WebView reports a download request.\n"
        + "  final DownloadListener? onDownloadStart;\n",
        1,
    )

listener_block = """    if (_webViewController.platform is AndroidWebViewController &&
        widget.onDownloadStart != null) {
      await (_webViewController.platform as AndroidWebViewController)
          .setDownloadListener(widget.onDownloadStart);
    }

"""
if "setDownloadListener(widget.onDownloadStart)" not in w:
    platform_anchor = """    if (_webViewController.platform is AndroidWebViewController) {
      unawaited(AndroidWebViewController.enableDebugging(kDebugMode));
      unawaited(
        (_webViewController.platform as AndroidWebViewController)
            .setMediaPlaybackRequiresUserGesture(true),
      );
    }

"""
    if platform_anchor not in w:
        raise SystemExit("Android WebView initialization anchor not found")
    w = w.replace(platform_anchor, platform_anchor + listener_block, 1)

for required in (
    "this.onDownloadStart,",
    "final DownloadListener? onDownloadStart;",
    "setDownloadListener(widget.onDownloadStart)",
):
    if required not in w:
        raise SystemExit("Package patch incomplete: " + required)

widget.write_text(w)
print("Patched app source:", MAIN)
print("Patched dependency:", widget)
