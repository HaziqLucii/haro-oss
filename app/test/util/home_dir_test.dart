import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/util/home_dir.dart';

void main() {
  test('strips the macOS sandbox container from HOME', () {
    expect(
      userHomeDir({
        'HOME': '/Users/dev/Library/Containers/dev.haro.haroApp/Data',
      }),
      '/Users/dev',
    );
  });

  test('passes a normal HOME through', () {
    expect(userHomeDir({'HOME': '/home/dev'}), '/home/dev');
    expect(userHomeDir(const {}), isNull);
  });
}
