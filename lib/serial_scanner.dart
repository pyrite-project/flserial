import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Information about a single serial port discovered on the host system.
class SerialPortInfo {
  /// Platform-specific port identifier passed to [FlSerial.open].
  ///
  /// | Platform | Example |
  /// |----------|---------|
  /// | Windows | `COM3` |
  /// | Linux | `/dev/ttyUSB0` |
  /// | macOS | `/dev/cu.usbserial-1410` |
  /// | Android | `usb:/dev/bus/usb/001/002` |
  /// | Web | `web:request` |
  final String path;

  /// Human-readable label (device name, manufacturer, or generic category).
  final String description;

  /// USB vendor id reported by the operating system, or `null` when the
  /// platform/driver does not expose it.
  ///
  /// This is the raw 16-bit id exactly as the OS reports it, e.g. `0x2e8a` for
  /// Raspberry Pi. It is never derived from the port name: `null` means
  /// "unknown", not "not a USB device".
  final int? vid;

  /// USB product id reported by the operating system, or `null` when unknown.
  final int? pid;

  /// Creates a [SerialPortInfo] with the given [path] and [description].
  ///
  /// [vid]/[pid] are optional so that call sites which cannot obtain the ids
  /// keep working and leave them `null`.
  SerialPortInfo(this.path, this.description, {this.vid, this.pid});

  /// Whether both USB identifiers are known.
  bool get hasUsbIds => vid != null && pid != null;

  @override
  String toString() => '$path ($description)';
}

// ---------------------------------------------------------------------------
// Pure parsing helpers
//
// The three desktop platforms expose USB ids in three unrelated formats. Each
// format is parsed by a pure function so the mapping can be unit tested
// without a physical board attached.
// ---------------------------------------------------------------------------

/// Parsed USB ids.
class UsbIds {
  const UsbIds({required this.vid, required this.pid});

  final int vid;
  final int pid;
}

/// Parses USB ids out of a Windows PnP device instance id such as
/// `USB\VID_2E8A&PID_0005&MI_00\6&1A2B3C4D&0&0000`.
///
/// Returns `null` when either id is missing so callers never fabricate one.
UsbIds? parseWindowsVidPid(String pnpDeviceId) {
  final vidMatch = RegExp(
    r'VID_([0-9A-Fa-f]{4})',
    caseSensitive: false,
  ).firstMatch(pnpDeviceId);
  final pidMatch = RegExp(
    r'PID_([0-9A-Fa-f]{4})',
    caseSensitive: false,
  ).firstMatch(pnpDeviceId);
  if (vidMatch == null || pidMatch == null) return null;
  final vid = int.tryParse(vidMatch.group(1)!, radix: 16);
  final pid = int.tryParse(pidMatch.group(1)!, radix: 16);
  if (vid == null || pid == null) return null;
  return UsbIds(vid: vid, pid: pid);
}

/// Parses the `PRODUCT=` line of a Linux USB `uevent` file.
///
/// The line looks like `PRODUCT=2e8a/5/200`, where the first field is the
/// vendor id, the second the product id and the third the device revision.
UsbIds? parseLinuxUeventProduct(String uevent) {
  for (final rawLine in uevent.split('\n')) {
    final line = rawLine.trim();
    if (!line.startsWith('PRODUCT=')) continue;
    final parts = line.substring('PRODUCT='.length).split('/');
    if (parts.length < 2) continue;
    final vid = int.tryParse(parts[0], radix: 16);
    final pid = int.tryParse(parts[1], radix: 16);
    if (vid == null || pid == null) continue;
    return UsbIds(vid: vid, pid: pid);
  }
  return null;
}

/// One USB device entry reported by `system_profiler SPUSBDataType -json`.
class MacUsbDeviceInfo {
  const MacUsbDeviceInfo({
    required this.name,
    this.vid,
    this.pid,
    this.serialNumber,
    this.manufacturer,
  });

  final String name;
  final int? vid;
  final int? pid;
  final String? serialNumber;
  final String? manufacturer;

  /// Flattened manufacturer + product label.
  String get label {
    final parts = [
      manufacturer,
      name,
    ].where((part) => part != null && part.trim().isNotEmpty).cast<String>();
    return parts.join(' ').trim();
  }
}

/// Parses the `vendor_id`/`product_id` values used by system_profiler.
///
/// Observed forms are `0x2e8a`, `0x2e8a  (Raspberry Pi)`, `0X2E8A` and bare
/// decimals; system_profiler has switched between hex and decimal output
/// across macOS releases, so both are accepted.
int? parseSystemProfilerUsbId(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  // Drop the human readable vendor suffix, e.g. "(Raspberry Pi)".
  final token = text.split(RegExp(r'\s+')).first;
  if (token.toLowerCase().startsWith('0x')) {
    return int.tryParse(token.substring(2), radix: 16);
  }
  final decimal = int.tryParse(token);
  if (decimal != null) return decimal;
  return int.tryParse(token, radix: 16);
}

/// Flattens both the legacy list shape and the newer map shape into one list
/// of USB devices, including devices nested under hubs.
List<MacUsbDeviceInfo> parseSystemProfilerUsbJson(String rawJson) {
  Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (_) {
    return const [];
  }
  if (decoded is! Map) return const [];
  final devices = <MacUsbDeviceInfo>[];

  void visit(Object? node) {
    if (node is List) {
      for (final item in node) {
        visit(item);
      }
      return;
    }
    if (node is! Map) return;
    final name = node['_name']?.toString();
    if (name != null && name.isNotEmpty) {
      devices.add(
        MacUsbDeviceInfo(
          name: name,
          vid: parseSystemProfilerUsbId(node['vendor_id']),
          pid: parseSystemProfilerUsbId(node['product_id']),
          serialNumber: node['serial_num']?.toString(),
          manufacturer: node['manufacturer']?.toString(),
        ),
      );
    }
    // Hubs nest their downstream ports under `_items`.
    visit(node['_items']);
  }

  visit(decoded['SPUSBDataType']);
  return devices;
}

/// Strips the `/dev/cu.` / `/dev/tty.` prefix and the common driver prefixes
/// so a port name can be compared against a USB serial number.
///
/// For example `cu.usbmodem1101` -> `1101`, `cu.usbserial-1410` -> `1410`.
String macSerialPortSuffix(String portPath) {
  var name = portPath.split('/').last;
  if (name.startsWith('cu.')) name = name.substring(3);
  if (name.startsWith('tty.')) name = name.substring(4);
  for (final prefix in const [
    'usbmodem',
    'usbserial',
    'SLAB_USBtoUART',
    'wchusbserial',
    'usb',
  ]) {
    if (name.toLowerCase().startsWith(prefix.toLowerCase())) {
      name = name.substring(prefix.length);
      if (name.startsWith('-') || name.startsWith('.')) {
        name = name.substring(1);
      }
      break;
    }
  }
  return name;
}

String _normalizeMacToken(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Finds the USB device that most plausibly owns [portPath].
///
/// Matching is intentionally conservative: IOKit does not expose a
/// `IOSerialBSDClient`'s USB parentage through a single command, so a wrong
/// guess would be worse than no answer. An unique serial-number suffix match
/// wins; otherwise the port name must contain an unique product-name token.
///
/// Returns `null` when nothing or more than one device matches, letting the
/// caller keep `vid`/`pid` unknown.
MacUsbDeviceInfo? matchMacUsbDeviceForPort(
  String portPath,
  List<MacUsbDeviceInfo> devices,
) {
  final normalizedSuffix = _normalizeMacToken(macSerialPortSuffix(portPath));
  if (normalizedSuffix.length >= 3) {
    final serialMatches = devices
        .where(
          (device) =>
              _normalizeMacToken(device.serialNumber ?? '') == normalizedSuffix,
        )
        .toList();
    if (serialMatches.length == 1) return serialMatches.single;
  }

  final loweredPath = portPath.toLowerCase();
  final nameMatches = devices.where((device) {
    final token = _normalizeMacToken(device.name);
    return token.length >= 4 && loweredPath.contains(token);
  }).toList();
  if (nameMatches.length == 1) return nameMatches.single;
  return null;
}

/// USB ids resolved for a Windows COM port.
class WindowsUsbPortIds {
  const WindowsUsbPortIds({
    required this.vid,
    required this.pid,
    this.description,
  });

  final int vid;
  final int pid;
  final String? description;
}

/// Parses the JSON produced by the PnP/CIM query in [SerialScanner].
///
/// The `SERIALCOMM` registry key only maps driver names to COM numbers, so the
/// ids have to come from the PnP device list. CIM emits either a single object
/// or an array, hence both shapes are accepted here.
Map<String, WindowsUsbPortIds> parseWindowsComPortUsbIds(String rawJson) {
  Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } catch (_) {
    return const {};
  }
  final entries = <Map>[];
  if (decoded is List) {
    entries.addAll(decoded.whereType<Map>());
  } else if (decoded is Map) {
    entries.add(decoded);
  }

  final result = <String, WindowsUsbPortIds>{};
  for (final entry in entries) {
    final name = entry['Name']?.toString().trim() ?? '';
    final comMatch = RegExp(
      r'\((COM\d+)\)',
      caseSensitive: false,
    ).firstMatch(name);
    if (comMatch == null) continue;
    final ids = parseWindowsVidPid(entry['PNPDeviceID']?.toString() ?? '');
    if (ids == null) continue;
    final description = name
        .replaceAll(RegExp(r'\s*\(COM\d+\)', caseSensitive: false), '')
        .trim();
    final manufacturer = entry['Manufacturer']?.toString().trim() ?? '';
    result[comMatch.group(1)!.toUpperCase()] = WindowsUsbPortIds(
      vid: ids.vid,
      pid: ids.pid,
      description: description.isEmpty
          ? (manufacturer.isEmpty ? null : manufacturer)
          : description,
    );
  }
  return result;
}

/// Scans the host system for available serial ports.
///
/// Prefer [FlSerial.availablePorts], which delegates here.
///
/// ```dart
/// final ports = await SerialScanner.getAvailablePorts();
/// for (final p in ports) print(p);
/// ```
class SerialScanner {
  static final _usbChannel = MethodChannel('io.github.grzesl.flserial/usb');

  /// Returns all serial ports currently available on this device.
  ///
  /// The implementation is platform-specific:
  ///
  /// * **Windows** — reads `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM` from the registry.
  /// * **Linux** — scans `/sys/class/tty` for `ttyUSB*`, `ttyACM*`, `ttyS*` entries.
  /// * **macOS** — scans `/dev/cu.*` (call-out devices only).
  /// * **Android** — queries connected USB serial devices via the USB Host API
  ///   platform channel; returns `usb:`-prefixed paths.
  /// * **Web** — returns a single synthetic `"Web Serial Port"` entry; opening
  ///   it shows the browser's native port-picker dialog.
  ///
  /// Every platform additionally performs a best-effort USB id lookup
  /// ([SerialPortInfo.vid]/[SerialPortInfo.pid]) and leaves both fields `null`
  /// when the OS does not expose them.
  static Future<List<SerialPortInfo>> getAvailablePorts() async {
    if (kIsWeb) return _scanWeb();
    if (Platform.isWindows) {
      return _scanWindows();
    } else if (Platform.isLinux) {
      return _scanLinux();
    } else if (Platform.isMacOS) {
      return _scanMacOS();
    } else if (Platform.isAndroid) {
      return _scanAndroid();
    }
    return [];
  }

  static Future<List<SerialPortInfo>> _scanWindows() async {
    final List<SerialPortInfo> ports = [];
    try {
      final result = await Process.run('reg', [
        'query',
        r'HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM',
      ]);

      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\r\n');
        for (var line in lines) {
          if (line.contains('REG_SZ')) {
            final parts = line.split(RegExp(r'\s+'));
            final portName = parts.last;
            ports.add(SerialPortInfo(portName, 'Windows Serial Device'));
          }
        }
      }
    } catch (_) {}
    if (ports.isEmpty) return ports;

    final usbIds = await _windowsUsbIdsByPort();
    if (usbIds.isEmpty) return ports;
    return [
      for (final port in ports)
        if (usbIds[port.path.toUpperCase()] case final ids?)
          SerialPortInfo(
            port.path,
            ids.description ?? port.description,
            vid: ids.vid,
            pid: ids.pid,
          )
        else
          port,
    ];
  }

  /// Correlates COM ports with their PnP device instance ids.
  ///
  /// Any failure is treated as "ids unknown" rather than an error: the port
  /// list must remain usable even on hosts where PowerShell is restricted.
  static Future<Map<String, WindowsUsbPortIds>> _windowsUsbIdsByPort() async {
    const script =
        r'Get-CimInstance -ClassName Win32_PnPEntity | '
        r"Where-Object { $_.Name -match '\(COM\d+\)' } | "
        r'Select-Object Name,Manufacturer,PNPDeviceID | '
        r'ConvertTo-Json -Compress';
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return const {};
      return parseWindowsComPortUsbIds(result.stdout.toString());
    } catch (_) {
      return const {};
    }
  }

  static Future<List<SerialPortInfo>> _scanLinux() async {
    final List<SerialPortInfo> ports = [];
    final dir = Directory('/sys/class/tty');

    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        final name = entity.path.split('/').last;
        if (name.startsWith('ttyUSB') ||
            name.startsWith('ttyACM') ||
            name.startsWith('ttyS')) {
          final devicePath = '/dev/$name';
          if (await File(devicePath).exists()) {
            final ids = await _linuxUsbIds(name);
            ports.add(
              ids == null
                  ? SerialPortInfo(devicePath, 'Linux TTY Device')
                  : SerialPortInfo(
                      devicePath,
                      'Linux TTY Device',
                      vid: ids.vid,
                      pid: ids.pid,
                    ),
            );
          }
        }
      }
    }
    return ports;
  }

  /// Walks up from `/sys/class/tty/<name>/device` looking for the first
  /// `uevent` that carries a USB `PRODUCT` line.
  static Future<UsbIds?> _linuxUsbIds(String ttyName) async {
    try {
      final deviceLink = Link('/sys/class/tty/$ttyName/device');
      if (!await deviceLink.exists()) return null;
      var current = await deviceLink.resolveSymbolicLinks();
      for (var depth = 0; depth < 5; depth++) {
        final uevent = File('$current/uevent');
        if (await uevent.exists()) {
          final ids = parseLinuxUeventProduct(await uevent.readAsString());
          if (ids != null) return ids;
        }
        final parent = Directory(current).parent.path;
        if (parent == current || parent.isEmpty) break;
        current = parent;
      }
    } catch (_) {}
    return null;
  }

  static Future<List<SerialPortInfo>> _scanMacOS() async {
    final List<SerialPortInfo> ports = [];
    final dir = Directory('/dev');
    final serialPaths = <String>[];

    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        final name = entity.path.split('/').last;
        if (name.startsWith('cu.')) {
          if (!name.contains('Bluetooth') && !name.contains('AirPods')) {
            serialPaths.add(entity.path);
          }
        }
      }
    }
    if (serialPaths.isEmpty) return ports;

    final usbDevices = await _macUsbDevices();
    for (final devicePath in serialPaths) {
      final match = matchMacUsbDeviceForPort(devicePath, usbDevices);
      final label = match?.label ?? '';
      ports.add(
        SerialPortInfo(
          devicePath,
          label.isNotEmpty ? label : 'macOS Serial Device',
          vid: match?.vid,
          pid: match?.pid,
        ),
      );
    }
    return ports;
  }

  /// Reads the USB device inventory with `system_profiler`.
  ///
  /// `ioreg` is not used for parentage because a `IOSerialBSDClient` node does
  /// not expose its USB parents' `idVendor`/`idProduct` in a single bounded
  /// query; the system_profiler inventory is the documented source for those
  /// ids and is correlated with the port name by
  /// [matchMacUsbDeviceForPort].
  static Future<List<MacUsbDeviceInfo>> _macUsbDevices() async {
    try {
      final result = await Process.run('system_profiler', [
        'SPUSBDataType',
        '-json',
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return const [];
      return parseSystemProfilerUsbJson(result.stdout.toString());
    } catch (_) {
      return const [];
    }
  }

  static Future<List<SerialPortInfo>> _scanAndroid() async {
    final List<SerialPortInfo> ports = [];
    try {
      final List<dynamic>? result = await _usbChannel.invokeListMethod<dynamic>(
        'listUsbSerialDevices',
      );
      if (result != null) {
        for (final item in result) {
          if (item is Map) {
            final name = item['name'] as String? ?? '';
            final product = item['product'] as String? ?? '';
            final manufacturer = item['manufacturer'] as String? ?? '';
            final desc = [
              manufacturer,
              product,
            ].where((s) => s.isNotEmpty).join(' ').trim();
            if (name.isNotEmpty) {
              ports.add(
                SerialPortInfo(
                  'usb:$name',
                  desc.isNotEmpty ? desc : 'USB Serial Device',
                  vid: _asPositiveInt(item['vid']),
                  pid: _asPositiveInt(item['pid']),
                ),
              );
            }
          }
        }
      }
    } catch (_) {}
    return ports;
  }

  /// Android reports unknown ids as `0`, which must stay `null` upstream.
  static int? _asPositiveInt(Object? value) {
    if (value is int) return value > 0 ? value : null;
    if (value is num) return value > 0 ? value.toInt() : null;
    return null;
  }

  static Future<List<SerialPortInfo>> _scanWeb() async {
    return [SerialPortInfo('web:request', 'Web Serial Port')];
  }
}
