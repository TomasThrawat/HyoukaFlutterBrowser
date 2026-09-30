import 'package:flutter_test/flutter_test.dart';
import 'package:hyouka_browser/main.dart';

void main() {
  test('plain text is converted to a Google search', () {
    expect(
      resolveBrowserInput('flutter ad blocker').toString(),
      'https://www.google.com/search?q=flutter%20ad%20blocker',
    );
  });

  test('http and https URLs stay direct', () {
    expect(
      resolveBrowserInput('https://example.com').toString(),
      'https://example.com',
    );
  });

  test('bare domains get https', () {
    expect(
      resolveBrowserInput('example.com').toString(),
      'https://example.com',
    );
  });
}
