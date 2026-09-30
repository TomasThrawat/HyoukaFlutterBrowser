# Hyouka Browser

Flutter Android browser with a pure-black UI, Google search, history, EasyList + AdGuard filtering, extra tracker/ad domains, visible download progress, and automatic fallback when Google shows an unusual-traffic challenge.

## Architecture

- Flutter/Dart owns the browser UI, navigation state, history, ad-blocker state, filter statistics UI, and download progress presentation.
- A small Kotlin Android bridge delegates file downloads to Android DownloadManager.
- The bridge forwards active WebView cookies and the Android user agent so downloads can reuse the browser session.
- Android DownloadManager writes to the system Downloads directory and continues in the background.
- The APK is built for arm64-v8a only.

## Ad blocking

The browser uses the package's EasyList and AdGuard filters plus an explicit tracker/ad domain denylist. The shield button toggles blocking and shows a blocked-resource badge after pages load. Long-pressing the shield opens blocking statistics.

When Google Search returns its unusual-traffic challenge, the browser automatically switches that search to Bing so the challenge page does not interrupt the search flow.
