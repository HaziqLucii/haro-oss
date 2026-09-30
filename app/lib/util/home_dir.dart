import 'dart:io';

/// The user's real home directory. Inside the macOS app sandbox `HOME` points at the
/// app's container (`~/Library/Containers/<bundle id>/Data`), which would turn every `~`
/// label and expansion into a path inside the container.
String? userHomeDir([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  final home = e['HOME'] ?? e['USERPROFILE'];
  if (home == null) return null;
  const marker = '/Library/Containers/';
  final i = home.indexOf(marker);
  return i > 0 ? home.substring(0, i) : home;
}
