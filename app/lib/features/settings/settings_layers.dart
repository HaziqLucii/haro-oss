import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/models.dart';

/// The backend only returns the merged view of the committed and personal config files, and
/// its Agent, Gate and Roles writes take every field. Writing that merged view into the
/// committed file would copy personal overrides into it, so a Team save is only allowed when
/// this says the personal layer cannot differ from the team one.
abstract class SettingsLayerReader {
  /// True only when it is certain that neither the personal file nor the user-global file
  /// sets any of [tables]. Unreadable or unknown means false.
  Future<bool> teamWriteSafe(Project project, List<String> tables);
}

/// Reads the files on this machine. A project the app cannot see (remote backend, another
/// path inside a container, macOS sandbox) reads as unknown, never as clean.
class FileSettingsLayerReader implements SettingsLayerReader {
  const FileSettingsLayerReader({this.globalPath});

  /// The user-global settings file; defaults to `$HARO_USER_CONFIG` or `~/.haro/settings.toml`.
  final String? globalPath;

  @override
  Future<bool> teamWriteSafe(Project project, List<String> tables) async {
    try {
      if (!await Directory(project.path).exists()) return false;
    } catch (_) {
      return false;
    }
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    final global0 =
        globalPath ??
        env['HARO_USER_CONFIG'] ??
        (home == null ? null : '$home/.haro/settings.toml');
    if (global0 == null) return false;
    final local = await _read('${project.path}/.haro/settings.local.toml');
    final global = await _read(global0);
    if (local == null || global == null) return false;
    return !tablesDeclared(local, tables) && !tablesDeclared(global, tables);
  }

  static Future<String?> _read(String path) async {
    try {
      return await File(path).readAsString();
    } on PathNotFoundException {
      return '';
    } on FileSystemException catch (e) {
      return e.osError?.errorCode == 2 ? '' : null;
    } catch (_) {
      return null;
    }
  }
}

/// Whether TOML text declares any of [tables], as `[t]`, `[t.x]`, `t.key = ...` or `t = {`.
/// Deliberately over-eager: a false positive only turns Team saving off.
bool tablesDeclared(String toml, List<String> tables) {
  final names = tables.map(RegExp.escape).join('|');
  final header = RegExp('^\\s*\\[\\s*($names)\\s*[\\].]', multiLine: true);
  final dotted = RegExp('^\\s*($names)\\s*[.=]', multiLine: true);
  return header.hasMatch(toml) || dotted.hasMatch(toml);
}

final settingsLayersProvider = Provider<SettingsLayerReader>(
  (ref) => const FileSettingsLayerReader(),
);
