from pathlib import Path

path = Path("lib/main.dart")
source = path.read_text()

anchor = "  'click.a-ads.com',"
required_domains = (
    "  'readilyprobablechow.shop',",
    "  'nexus-nexus-ba.github.io',",
    "  'inthedungeons123.lol',",
)
if anchor not in source:
    raise SystemExit("Adblock denylist anchor not found")
for domain in required_domains:
    if domain not in source:
        source = source.replace(anchor, anchor + "\n" + domain, 1)

ua_declaration = (
    "const _browserUserAgent = "
    "'Mozilla/5.0 (Linux; Android 12; CPH2095) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/140.0.0.0 Mobile Safari/537.36';"
)
if "_browserUserAgent" not in source:
    source = source.replace(
        "const _adBlockKey = 'ad_block_enabled';",
        "const _adBlockKey = 'ad_block_enabled';\n" + ua_declaration,
        1,
    )

if "String? _lastPageUrl;" not in source:
    source = source.replace(
        "  bool _adBlockEnabled = true;",
        "  String? _lastPageUrl;\n  bool _adBlockEnabled = true;",
        1,
    )

if "final referer = _lastPageUrl;" not in source:
    source = source.replace(
        "    final fileName = downloadFileName(uri);",
        "    final fileName = downloadFileName(uri);\n"
        "    final referer = _lastPageUrl;",
        1,
    )

old_map = """        <String, dynamic>{
          'url': key,
          'fileName': fileName,
        },"""
new_map = """        <String, dynamic>{
          'url': key,
          'fileName': fileName,
          'referer': referer,
          'userAgent': _browserUserAgent,
        },"""
if old_map in source:
    source = source.replace(old_map, new_map, 1)

if "_lastPageUrl = url.toString();" not in source:
    source = source.replace(
        "    _recordHistory(url.toString());",
        "    _lastPageUrl = url.toString();\n"
        "    _recordHistory(url.toString());",
        1,
    )

old_url_block = """                    final parsedUrl = url == null ? null : Uri.tryParse(url);
                    if (parsedUrl != null) {
                      unawaited(_trackDownloadUrl(parsedUrl));
                    }"""
new_url_block = """                    final parsedUrl = url == null ? null : Uri.tryParse(url);
                    if (parsedUrl != null) {
                      if (!isLikelyDownloadUrl(parsedUrl)) {
                        _lastPageUrl = parsedUrl.toString();
                      }
                      unawaited(_trackDownloadUrl(parsedUrl));
                    }"""
if old_url_block in source:
    source = source.replace(old_url_block, new_url_block, 1)

old_widget_ua = """                   userAgent:
                       'Mozilla/5.0 (Linux; Android 12; CPH2095) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/140.0.0.0 Mobile Safari/537.36',"""
if old_widget_ua in source:
    source = source.replace(
        old_widget_ua,
        "                   userAgent: _browserUserAgent,",
        1,
    )

checks = (
    "readilyprobablechow.shop",
    "nexus-nexus-ba.github.io",
    "inthedungeons123.lol",
    "'referer': referer",
    "'userAgent': _browserUserAgent",
    "String? _lastPageUrl;",
)
missing = [item for item in checks if item not in source]
if missing:
    raise SystemExit("Browser hardening patch incomplete: " + ", ".join(missing))

path.write_text(source)
print("Patched", path, "with", len(source), "bytes")
