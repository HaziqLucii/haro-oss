import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../api/models/json_util.dart' show asJson;
import '../api/models/models.dart';
import '../data/workspace_store.dart';
import '../features/settings/device_prefs.dart';

/// What to do about one feed event: play a tone, raise an OS notification, or both.
class NotifyPlan {
  const NotifyPlan({
    required this.title,
    required this.body,
    required this.sound,
    required this.desktop,
  });

  final String title;
  final String body;
  final bool sound;
  final bool desktop;
}

/// Decides, from the device's Notifications settings, what an event earns. Pure, so the
/// rules (who beeps, who stays quiet) are tested without a window or a process.
///
/// A managed agent workspace already beeped on `agent_done`, so its gate verdict stays
/// silent. An adopted worktree and a manual workspace have no agent `done`: the gate
/// verdict is the moment they finish, so that is where the tone and the notification go.
NotifyPlan? planNotification(
  NotifyEvent e,
  NotificationPrefs prefs, {
  required bool focused,
}) {
  switch (e) {
    case AgentDoneNotify():
      final name = e.workspaceName ?? 'a workspace';
      final failed = e.status == 'error';
      return NotifyPlan(
        title: name,
        body: failed ? 'The agent stopped with an error' : 'The agent is done',
        sound: prefs.soundOnFinish,
        desktop: prefs.desktop && !focused,
      );
    case GateResultNotify():
      if (e.green && prefs.quietOnGreen) return null;
      final name = e.workspaceName ?? 'a workspace';
      final ownsFinish =
          e.workspaceKind == WorkspaceKind.adopted ||
          e.workspaceMode == WorkspaceMode.manual;
      return NotifyPlan(
        title: name,
        body: e.green
            ? 'Gate green: ${e.passed} of ${e.total} tests pass'
            : e.total == 0
            ? 'Gate errored: no tests ran'
            : 'Gate red: ${e.failed} of ${e.total} tests fail',
        sound: ownsFinish && prefs.soundOnFinish,
        desktop: prefs.desktop && !focused,
      );
    default:
      return null;
  }
}

typedef ProcessRunner = Future<void> Function(String exe, List<String> args);

/// Posts through the app's own notification centre; false when that is unavailable (not
/// allowed by the user, or no native side in this build) so the caller can fall back.
typedef NativeNotify = Future<bool> Function(String title, String body);

const _notifyChannel = MethodChannel('dev.haro.haroApp/notify');

Future<bool> _nativeNotify(String title, String body) async {
  try {
    return await _notifyChannel.invokeMethod<bool>('show', {
          'title': title,
          'body': body,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<void> _runProcess(String exe, List<String> args) async {
  try {
    await Process.run(exe, args);
  } on ProcessException {
    // A missing player or notifier (no libnotify on a minimal Linux) is not an error.
  }
}

/// Plays tones and raises OS notifications through the platform's own tools, so the app
/// needs no native plugin: `afplay` and `osascript` on macOS, `canberra-gtk-play` and
/// `notify-send` on Linux.
class DesktopNotifier {
  DesktopNotifier({
    ProcessRunner? run,
    bool? isMac,
    NativeNotify? native,
    String? Function()? icon,
  }) : _run = run ?? _runProcess,
       _isMac = isMac ?? Platform.isMacOS,
       _native = native ?? _nativeNotify,
       _icon = icon ?? _bundledIcon;

  final ProcessRunner _run;
  final bool _isMac;
  final NativeNotify _native;
  final String? Function() _icon;

  /// The haro icon shipped inside the bundle (and so inside the AppImage's mount), so a
  /// notification carries it without any file installed on the system. Null when the app is
  /// not running from a bundle (`flutter run`).
  static String? _bundledIcon() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final icon = File('$dir/data/flutter_assets/assets/brand/app_icon.png');
    return icon.existsSync() ? icon.path : null;
  }

  static const _macSounds = {
    'chime': 'Hero',
    'beep': 'Ping',
    'blip': 'Pop',
    'arcade': 'Funk',
    'glass': 'Glass',
  };
  static const _linuxSounds = {
    'chime': 'complete',
    'beep': 'bell',
    'blip': 'message',
    'arcade': 'service-login',
    'glass': 'dialog-information',
  };

  Future<void> perform(NotifyPlan plan, String sound) async {
    if (plan.sound) unawaited(playSound(sound));
    if (plan.desktop) unawaited(show(plan.title, plan.body));
  }

  Future<void> playSound(String sound) {
    if (_isMac) {
      final file = _macSounds[sound] ?? 'Hero';
      return _run('afplay', ['/System/Library/Sounds/$file.aiff']);
    }
    return _run('canberra-gtk-play', ['-i', _linuxSounds[sound] ?? 'complete']);
  }

  Future<void> show(String title, String body) async {
    // osascript is the fallback: it works without permission but shows as Script Editor.
    if (_isMac && await _native(title, body)) return;
    if (_isMac) {
      String q(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      return _run('osascript', [
        '-e',
        'display notification "${q(body)}" with title "${q(title)}"',
      ]);
    }
    // Without --app-name the card is headed by the tool's own name ("notify-send") and has no
    // icon. The workspace is the title; the verdict is the body.
    final icon = _icon();
    return _run('notify-send', [
      '--app-name=haro',
      if (icon != null) '--icon=$icon',
      '--',
      title,
      body,
    ]);
  }
}

final desktopNotifierProvider = Provider<DesktopNotifier>(
  (ref) => DesktopNotifier(),
);

Future<bool> _windowFocused() async {
  try {
    return await windowManager.isFocused();
  } catch (_) {
    return true;
  }
}

/// Listens to the global feed and turns gate verdicts and agent-done signals into tones
/// and OS notifications, so a dev coding in another editor hears the verdict. Sits at the
/// app root and draws nothing. The prefs are re-read per event: the file is tiny and this
/// way a change in Settings applies at once without wiring a second copy of the prefs.
class NotifierHost extends ConsumerStatefulWidget {
  const NotifierHost({super.key, required this.child, this.isFocused});

  final Widget child;
  final Future<bool> Function()? isFocused;

  @override
  ConsumerState<NotifierHost> createState() => _NotifierHostState();
}

class _NotifierHostState extends ConsumerState<NotifierHost> {
  StreamSubscription<NotifyEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(workspaceStoreProvider.notifier)
        .notifyEvents
        .listen((e) => unawaited(_handle(e)));
  }

  Future<void> _handle(NotifyEvent e) async {
    try {
      final file = await ref.read(devicePrefsStoreProvider).read();
      final prefs = NotificationPrefs.fromJson(asJson(file['notifications']));
      final focused = await (widget.isFocused ?? _windowFocused)();
      final plan = planNotification(e, prefs, focused: focused);
      if (plan == null || !mounted) return;
      await ref.read(desktopNotifierProvider).perform(plan, prefs.sound);
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
