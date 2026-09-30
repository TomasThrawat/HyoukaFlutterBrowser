import 'package:flutter_test/flutter_test.dart';
import 'package:browser/main.dart';

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

  test('history moves the newest visit to the front and removes duplicates', () {
    expect(
      addHistoryEntry(
        const <String>['https://google.com', 'https://example.com'],
        'https://google.com',
      ),
      const <String>['https://google.com', 'https://example.com'],
    );
  });

  test('history ignores non-web schemes', () {
    expect(
      addHistoryEntry(
        const <String>['https://example.com'],
        'mailto:test@example.com',
      ),
      const <String>['https://example.com'],
    );
  });

  test('download file names are sanitized', () {
    expect(
      downloadFileName(Uri.parse('https://example.com/files/test.pdf')),
      'test.pdf',
    );
  });
}
