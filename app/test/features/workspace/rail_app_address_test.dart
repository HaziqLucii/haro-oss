import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';

void main() {
  group('appAddress', () {
    test('a url with a port shows just the port', () {
      expect(appAddress('http://localhost:4200', 4500), ':4200');
    });

    test('a url without a port shows its host', () {
      expect(appAddress('https://app.example.test/', 4500), 'app.example.test');
    });

    test('no url falls back to the reserved port, no port to nothing', () {
      expect(appAddress(null, 4500), ':4500');
      expect(appAddress(null, null), '');
      expect(appAddress('not a url', 4500), ':4500');
    });
  });
}
