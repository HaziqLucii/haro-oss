import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../util/home_dir.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class CloneException implements Exception {
  const CloneException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The user cancelled or closed the overlay mid-clone. Not an error to show.
class CloneCancelled implements Exception {
  const CloneCancelled();
}

/// Lets the caller stop a clone that is running. The runner attaches the way to kill its
/// process; cancelling before it attaches kills it the moment it does.
class CloneHandle {
  void Function()? _kill;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void attach(void Function() kill) {
    _kill = kill;
    if (_cancelled) kill();
  }

  void cancel() {
    _cancelled = true;
    _kill?.call();
  }
}

/// Clones [url] into [destination] (a folder that must not hold anything yet). Throws
/// [CloneException] on failure and [CloneCancelled] if [handle] was cancelled.
typedef CloneRunner = Future<void> Function(
  String url,
  String destination,
  CloneHandle handle,
);

/// What is at a path, checked before git runs so it never clones into someone's files.
enum TargetState { missing, empty, notEmpty }

typedef TargetProbe = Future<TargetState> Function(String path);

/// The backend has no clone endpoint, so the desktop client runs `git clone` itself with the
/// user's own credentials. Override in tests.
final cloneRunnerProvider = Provider<CloneRunner>((ref) => gitClone);

final cloneTargetProbeProvider = Provider<TargetProbe>((ref) => probeTarget);

/// `HOME`, for expanding a leading `~` the way the backend will.
final homeDirProvider = Provider<String?>((ref) => userHomeDir());

Future<TargetState> probeTarget(String path) async {
  final type = await FileSystemEntity.type(path);
  if (type == FileSystemEntityType.notFound) return TargetState.missing;
  if (type != FileSystemEntityType.directory) return TargetState.notEmpty;
  return await Directory(path).list().isEmpty
      ? TargetState.empty
      : TargetState.notEmpty;
}

/// Environment that makes git fail instead of waiting for input nobody can answer:
/// no terminal prompt for credentials, and no ssh host-key or password prompt. An ssh
/// command the user already configured is left alone.
Map<String, String> cloneEnvironment(Map<String, String> parent) => {
  'GIT_TERMINAL_PROMPT': '0',
  if ((parent['GIT_SSH_COMMAND'] ?? '').isEmpty)
    'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes',
};

Future<void> gitClone(
  String url,
  String destination,
  CloneHandle handle,
) async {
  final Process process;
  try {
    process = await Process.start('git', [
      'clone',
      '--',
      url,
      destination,
    ], environment: cloneEnvironment(Platform.environment));
  } on ProcessException catch (e) {
    throw CloneException('Could not run git: ${e.message}');
  }
  handle.attach(() => process.kill());
  final err = process.stderr.transform(utf8.decoder).join();
  unawaited(process.stdout.drain<void>());
  final code = await process.exitCode;
  if (handle.cancelled) throw const CloneCancelled();
  if (code != 0) {
    final text = (await err).trim();
    throw CloneException(text.isEmpty ? 'git clone failed' : text);
  }
}

final _shorthand = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

/// `owner/repo` is shorthand for the GitHub HTTPS URL; anything else is passed through.
String normalizeCloneUrl(String input) {
  final t = input.trim();
  return _shorthand.hasMatch(t) ? 'https://github.com/$t.git' : t;
}

/// Folder name git would pick: the last path segment without `.git`. Empty when unknown.
String repoFolderName(String url) {
  var t = url.trim().replaceAll(RegExp(r'/+$'), '');
  if (t.endsWith('.git')) t = t.substring(0, t.length - 4);
  final cut = t.lastIndexOf(RegExp(r'[/:]'));
  return cut == -1 ? '' : t.substring(cut + 1);
}
