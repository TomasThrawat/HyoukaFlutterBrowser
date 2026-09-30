import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const BrowserApp());

class BrowserApp extends StatelessWidget {
  const BrowserApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Hyouka Browser',
    theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
    home: const BrowserPage(),
  );
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  static const home = 'https://www.google.com/';
  late final WebViewController controller;
  final address = TextEditingController(text: home);
  final focus = FocusNode();
  int progress = 0;
  bool canBack = false, canForward = false;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => progress = p);
        },
        onPageStarted: (url) {
          if (mounted) setState(() => address.text = url);
        },
        onUrlChange: (change) {
          if (change.url != null && mounted) setState(() => address.text = change.url!);
          _sync();
        },
        onPageFinished: (url) {
          if (mounted) setState(() => address.text = url);
          _sync();
        },
        onNavigationRequest: (request) {
          final scheme = Uri.tryParse(request.url)?.scheme;
          return scheme == 'http' || scheme == 'https'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(home));
  }

  Future<void> _sync() async {
    final b = await controller.canGoBack();
    final f = await controller.canGoForward();
    if (mounted) setState(() {
      canBack = b;
      canForward = f;
    });
  }

  Future<void> _submit(String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    final url = v.startsWith('http://') || v.startsWith('https://')
        ? v
        : (v.contains('.') && !v.contains(' ')
            ? 'https://$v'
            : 'https://www.google.com/search?q=${Uri.encodeComponent(v)}');
    focus.unfocus();
    await controller.loadRequest(Uri.parse(url));
  }

  @override
  void dispose() {
    address.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        if (progress > 0 && progress < 100)
          LinearProgressIndicator(value: progress / 100, minHeight: 2)
        else
          const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            IconButton(
              onPressed: canBack ? () async { await controller.goBack(); await _sync(); } : null,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            IconButton(
              onPressed: canForward ? () async { await controller.goForward(); await _sync(); } : null,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
            Expanded(
              child: TextField(
                controller: address,
                focusNode: focus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                maxLines: 1,
                onSubmitted: _submit,
                decoration: InputDecoration(
                  hintText: 'Search or enter address',
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                  suffixIcon: IconButton(onPressed: controller.reload, icon: const Icon(Icons.refresh_rounded)),
                ),
              ),
            ),
          ]),
        ),
        Expanded(child: WebViewWidget(controller: controller)),
      ]),
    ),
  );
}
