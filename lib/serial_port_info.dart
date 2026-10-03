/// Information about a single serial port discovered on the host system.
///
/// This class is platform-neutral so both the native scanner and the Web
/// Serial implementation can share it.
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

  /// Creates a [SerialPortInfo] with the given [path] and [description].
  SerialPortInfo(this.path, this.description);

  @override
  String toString() => '$path ($description)';
}
