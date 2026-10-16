// These tests open real paths through the native library. `flutter test`
// builds it via the hook but does not put it on the loader path, so run:
//
//   LD_LIBRARY_PATH=$PWD/build/native_assets/linux flutter test
@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:flserial/flserial.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final isRoot = Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

  test('opening a missing path reports notFound', () async {
    final serial = FlSerial();
    addTearDown(serial.dispose);

    final ok = await serial.open('/dev/pyrite-missing-port', SerialConfig());

    expect(ok, isFalse);
    expect(serial.lastOpenError?.reason, SerialOpenFailure.notFound);
  });

  test(
    'opening a path without access reports permissionDenied',
    () async {
      final dir = Directory.systemTemp.createTempSync('flserial_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final port = File('${dir.path}/ttyLocked')..createSync();
      Process.runSync('chmod', ['000', port.path]);
      final serial = FlSerial();
      addTearDown(serial.dispose);

      final ok = await serial.open(port.path, SerialConfig());

      expect(ok, isFalse);
      expect(serial.lastOpenError?.reason, SerialOpenFailure.permissionDenied);
    },
    skip: isRoot ? 'root bypasses file permissions' : false,
  );
}
