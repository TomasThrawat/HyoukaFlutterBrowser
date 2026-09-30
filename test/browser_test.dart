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


  test('APK URLs are recognized as downloads', () {
    expect(
      isLikelyDownloadUrl(
        Uri.parse('https://example.com/files/Browser.apk'),
      ),
      isTrue,
    );
  });

  test('ordinary web pages are not recognized as downloads', () {
    expect(
      isLikelyDownloadUrl(Uri.parse('https://example.com/index.html')),
      isFalse,
    );
  });

  test('download query URLs are recognized as downloads', () {
    expect(
      isLikelyDownloadUrl(
        Uri.parse('https://example.com/file?id=42&download=1'),
      ),
      isTrue,
    );
  });

  test('download file names collapse duplicate APK extensions', () {
    expect(
      downloadFileName(Uri.parse('https://example.com/files/MyApp.apk.apk')),
      'MyApp.apk',
    );
  });

  test('download file names collapse duplicate ZIP extensions', () {
    expect(
      downloadFileName(Uri.parse('https://example.com/files/archive.zip.zip')),
      'archive.zip',
    );
  });

  test('download file names remove browser temporary suffixes', () {
    expect(
      downloadFileName(Uri.parse('https://example.com/files/archive.zip.kkl')),
      'archive.zip',
    );
  });
}
