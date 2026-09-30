import 'package:adblocker_webview/adblocker_webview.dart';
import 'package:flutter/material.dart';

const homeUrl = 'https://www.google.com/';

Uri resolveBrowserInput(String value) {
  final input = value.trim();
  if (input.isEmpty) {
    return Uri.parse(homeUrl);
  }

  final hasHttpScheme =
      input.startsWith('http://') || input.startsWith('https://');
  if (hasHttpScheme) {
    return Uri.parse(input);
  }

  final looksLikeDomain = input.contains('.') && !input.contains(' ');
  if (looksLikeDomain) {
    return Uri.parse('https://$input');
  }

  return Uri.parse(
    'https://www.google.com/search?q=${Uri.encodeComponent(input)}',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AdBlockerWebviewController.instance.initialize(
    FilterConfig(
      filterTypes: [FilterType.easyList, FilterType.adGuard],
    ),
  );

  runApp(const BrowserApp());
}

class BrowserApp extends StatelessWidget {
  const BrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Hyouka Browser',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          surfaceContainer: Color(0xFF050505),
          primary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const BrowserPage(),
    );
  }
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final controller = AdBlockerWebviewController.instance;
  final address = TextEditingController(text: homeUrl);
  final focus = FocusNode();

  int progress = 0;
  bool canBack = false;
  bool canForward = false;

  @override
  void initState() {
    super.initState();
    controller.resetStatistics();
  }

  Future<void> _syncNavigation() async {
    final back = await controller.canGoBack();
    final forward = await controller.canGoForward();

    if (!mounted) {
      return;
    }

    setState(() {
      canBack = back;
      canForward = forward;
    });
  }

  Future<void> _search(String value) async {
    final input = value.trim();
    if (input.isEmpty) {
      return;
    }

    final target = resolveBrowserInput(input);
    focus.unfocus();

    await controller.loadUrl(target);
    await _syncNavigation();
  }

  Future<void> _reload() async {
    await controller.reload();
    await _syncNavigation();
  }

  Future<void> _goBack() async {
    if (!canBack) {
      return;
    }

    await controller.goBack();
    await _syncNavigation();
  }

  Future<void> _goForward() async {
    if (!canForward) {
      return;
    }

    await controller.goForward();
    await _syncNavigation();
  }

  @override
  void dispose() {
    address.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            if (progress > 0 && progress < 100)
              LinearProgressIndicator(
                value: progress / 100,
                minHeight: 2,
                backgroundColor: Colors.black,
              )
            else
              const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: canBack ? _goBack : null,
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: canBack ? Colors.white : Colors.white24,
                  ),
                  IconButton(
                    onPressed: canForward ? _goForward : null,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    color: canForward ? Colors.white : Colors.white24,
                  ),
                  Expanded(
                    child: TextField(
                      controller: address,
                      focusNode: focus,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLines: 1,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: _search,
                      decoration: InputDecoration(
                        hintText: 'Search or enter address',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Colors.black,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: Colors.white54,
                        ),
                        suffixIcon: IconButton(
                          onPressed: _searchFromField,
                          icon: const Icon(
                            Icons.arrow_upward_rounded,
                            color: Colors.white,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: AdBlockerWebview(
                  url: Uri.parse(homeUrl),
                  shouldBlockAds: true,
                  adBlockerWebviewController: controller,
                  onLoadStart: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      progress = 0;
                      address.text = url.toString();
                    });
                  },
                  onLoadFinished: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      progress = 100;
                      address.text = url.toString();
                    });
                    _syncNavigation();
                  },
                  onUrlChanged: (url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      address.text = url.toString();
                    });
                    _syncNavigation();
                  },
                  onProgress: (value) {
                    if (!mounted) {
                      return;
                    }
                    setState(() => progress = value);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _searchFromField() => _search(address.text);
}
