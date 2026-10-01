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

for domain in required_domains:
    if domain not in source:
        raise SystemExit("Missing adblock domain: " + domain)

required_main = (
    "onDownloadStart:",
    "contentDispositionFileName(",
    "downloadFileNameFromMetadata(",
    "friendlyDownloadError(",
    "'referer': referer",
    "'userAgent': userAgent ?? _browserUserAgent",
    "'mimeType': mimeType",
)
missing = [item for item in required_main if item not in source]
if missing:
    raise SystemExit("Browser download implementation incomplete: " + ", ".join(missing))

pubcache = Path.home() / ".pub-cache" / "hosted" / "pub.dev"

android_candidates = sorted(pubcache.glob("webview_flutter_android-4.14.1"))
if len(android_candidates) != 1:
    raise SystemExit("Expected webview_flutter_android-4.14.1 exactly once")
controller = android_candidates[0] / "lib" / "src" / "android_webview_controller.dart"
if not controller.is_file():
    raise SystemExit("Android WebView controller source not found")
cs = controller.read_text()
for item in (
    "Future<void> setOnDownloadStart(",
    "android_webview.DownloadListener(",
    "_webView.setDownloadListener(listener)",
):
    if item not in cs:
        raise SystemExit("Missing Android WebView listener patch: " + item)

adblock_candidates = sorted(pubcache.glob("adblocker_webview-2.3.0"))
if len(adblock_candidates) != 1:
    raise SystemExit("Expected adblocker_webview-2.3.0 exactly once")
widget = adblock_candidates[0] / "lib" / "src" / "adblocker_webview.dart"
if not widget.is_file():
    raise SystemExit("adblocker_webview source not found")
ws = widget.read_text()
for item in (
    "this.onDownloadStart,",
    "final void Function(",
    "setOnDownloadStart(widget.onDownloadStart!)",
):
    if item not in ws:
        raise SystemExit("Missing adblocker download listener patch: " + item)

print("browser build patch verification OK")
