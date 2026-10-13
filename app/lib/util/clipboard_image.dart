import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('dev.haro.haroApp/clipboard');

/// Whether this device can hand over a copied picture (macOS only: Flutter has no clipboard
/// image API and the app carries no plugin for it). Elsewhere a paste in a note is a text paste.
bool get clipboardImageSupported => Platform.isMacOS;

/// The copied picture as PNG bytes, or null when the clipboard holds none (or the channel is
/// missing, as in a test).
Future<Uint8List?> readClipboardImage() async {
  if (!clipboardImageSupported) return null;
  try {
    return await _channel.invokeMethod<Uint8List>('readImage');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
