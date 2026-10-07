import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/models/json_util.dart';
import '../../util/home_dir.dart';

/// Where "This device" settings live. The file is one JSON object with a key per tab
/// (`display`, `notifications`); keys this client does not know are kept on every write.
abstract class DevicePrefsStore {
  Future<Json> read();
  Future<void> write(Json data);

  /// Read-modify-write under one lock: [change] gets the current file and returns the whole
  /// next one. Every writer goes through this (Settings, the shell collapse flags), so two
  /// of them never read the same base and drop each other's keys.
  Future<void> update(FutureOr<Json> Function(Json current) change);
}

/// Serialises async jobs: each starts when the one before it has finished, error or not.
class _Lock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() job) {
    final done = _tail.then((_) => job());
    _tail = done.then((_) {}, onError: (_) {});
    return done;
  }
}

/// `~/.haro/flutter-client.json`, next to the backend's own state.
class FileDevicePrefsStore implements DevicePrefsStore {
  FileDevicePrefsStore({File? file}) : _file = file ?? _defaultFile();

  final File _file;

  /// One lock per path, so two store instances over the same file still take turns.
  static final _locks = <String, _Lock>{};
  _Lock get _lock => _locks.putIfAbsent(_file.absolute.path, _Lock.new);

  static File _defaultFile() {
    final home = userHomeDir();
    return File('${home ?? '.'}/.haro/flutter-client.json');
  }

  @override
  Future<Json> read() async {
    try {
      if (!await _file.exists()) return <String, dynamic>{};
      return asJson(jsonDecode(await _file.readAsString()));
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Written to a sibling temp file and renamed over the target, so a concurrent read sees
  /// the old file or the new one, never a truncated one.
  @override
  Future<void> write(Json data) => _lock.run(() => _writeNow(data));

  Future<void> _writeNow(Json data) async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await tmp.rename(_file.path);
  }

  @override
  Future<void> update(FutureOr<Json> Function(Json current) change) =>
      _lock.run(() async => _writeNow(await change(await read())));
}

class MemoryDevicePrefsStore implements DevicePrefsStore {
  MemoryDevicePrefsStore([Json? initial]) : data = {...?initial};

  Json data;
  final _lock = _Lock();

  @override
  Future<Json> read() async => {...data};

  @override
  Future<void> write(Json next) => _lock.run(() async => data = {...next});

  @override
  Future<void> update(FutureOr<Json> Function(Json current) change) =>
      _lock.run(
        () async => data = {
          ...await change({...data}),
        },
      );
}

final devicePrefsStoreProvider = Provider<DevicePrefsStore>(
  (ref) => FileDevicePrefsStore(),
);

class DisplayPrefs {
  const DisplayPrefs({
    this.codingFont = 'Space Mono',
    this.density = 'comfortable',
    this.filmGrain = true,
    this.syntaxColour = true,
    this.preferredEditor = askEditor,
  });

  /// [preferredEditor] value for "pick every time".
  static const askEditor = 'ask';

  static const fontOptions = [
    'JetBrains Mono',
    'Fira Code',
    'IBM Plex Mono',
    'Space Mono',
  ];
  static const densityOptions = ['comfortable', 'compact'];

  final String codingFont;
  final String density;
  final bool filmGrain;

  /// Muted syntax colours in code; off is the monochrome look.
  final bool syntaxColour;

  /// An `Open in...` target id from `GET /editors`, or [askEditor].
  final String preferredEditor;

  factory DisplayPrefs.fromJson(Json j) => DisplayPrefs(
    codingFont: jStr(j, 'coding_font', 'Space Mono'),
    density: jStr(j, 'density', 'comfortable'),
    filmGrain: jBool(j, 'film_grain', true),
    syntaxColour: jBool(j, 'syntax_colour', true),
    preferredEditor: jStr(j, 'preferred_editor', askEditor),
  );

  Json toJson() => {
    'coding_font': codingFont,
    'density': density,
    'film_grain': filmGrain,
    'syntax_colour': syntaxColour,
    'preferred_editor': preferredEditor,
  };

  DisplayPrefs copyWith({
    String? codingFont,
    String? density,
    bool? filmGrain,
    bool? syntaxColour,
    String? preferredEditor,
  }) => DisplayPrefs(
    codingFont: codingFont ?? this.codingFont,
    density: density ?? this.density,
    filmGrain: filmGrain ?? this.filmGrain,
    syntaxColour: syntaxColour ?? this.syntaxColour,
    preferredEditor: preferredEditor ?? this.preferredEditor,
  );
}

/// Code editor look, kept per device like Display: font size, the minimap and word wrap, plus
/// the one behaviour switch, [formatOnSave].
class EditorPrefs {
  const EditorPrefs({
    this.fontSize = 13,
    this.minimap = true,
    this.wordWrap = false,
    this.formatOnSave = false,
  });

  static const fontSizes = [12, 13, 14, 15];

  final int fontSize;
  final bool minimap;
  final bool wordWrap;

  /// Off by default: the TS server's formatter can disagree with a project's prettier or eslint
  /// style and turn a save into a noisy diff.
  final bool formatOnSave;

  factory EditorPrefs.fromJson(Json j) => EditorPrefs(
    fontSize: jInt(j, 'font_size', 13).clamp(fontSizes.first, fontSizes.last),
    minimap: jBool(j, 'minimap', true),
    wordWrap: jBool(j, 'word_wrap'),
    formatOnSave: jBool(j, 'format_on_save'),
  );

  Json toJson() => {
    'font_size': fontSize,
    'minimap': minimap,
    'word_wrap': wordWrap,
    'format_on_save': formatOnSave,
  };

  EditorPrefs copyWith({
    int? fontSize,
    bool? minimap,
    bool? wordWrap,
    bool? formatOnSave,
  }) => EditorPrefs(
    fontSize: fontSize ?? this.fontSize,
    minimap: minimap ?? this.minimap,
    wordWrap: wordWrap ?? this.wordWrap,
    formatOnSave: formatOnSave ?? this.formatOnSave,
  );
}

/// XP is a reward on top of the work, so it is one switch away from gone: [showXp] hides the
/// sidebar footer, the strip badge and the toasts.
class XpPrefs {
  const XpPrefs({this.showXp = true});

  final bool showXp;

  factory XpPrefs.fromJson(Json j) =>
      XpPrefs(showXp: jBool(j, 'show_xp', true));

  Json toJson() => {'show_xp': showXp};

  XpPrefs copyWith({bool? showXp}) => XpPrefs(showXp: showXp ?? this.showXp);
}

class NotificationPrefs {
  const NotificationPrefs({
    this.soundOnFinish = true,
    this.sound = 'chime',
    this.desktop = false,
    this.quietOnGreen = false,
    this.toastPosition = 'bottom-right',
    this.toastSeconds = 4,
  });

  static const soundOptions = ['chime', 'beep', 'blip', 'arcade', 'glass'];
  static const toastPositions = {
    'top-left': 'Top left',
    'top-center': 'Top center',
    'top-right': 'Top right',
    'bottom-left': 'Bottom left',
    'bottom-center': 'Bottom center',
    'bottom-right': 'Bottom right',
  };
  static const toastDurations = [2, 4, 6, 10, 20];

  final bool soundOnFinish;
  final String sound;
  final bool desktop;
  final bool quietOnGreen;
  final String toastPosition;
  final int toastSeconds;

  factory NotificationPrefs.fromJson(Json j) => NotificationPrefs(
    soundOnFinish: jBool(j, 'sound_on_finish', true),
    sound: jStr(j, 'sound', 'chime'),
    desktop: jBool(j, 'desktop'),
    quietOnGreen: jBool(j, 'quiet_on_green'),
    toastPosition: jStr(j, 'toast_position', 'bottom-right'),
    toastSeconds: jInt(j, 'toast_seconds', 4),
  );

  Json toJson() => {
    'sound_on_finish': soundOnFinish,
    'sound': sound,
    'desktop': desktop,
    'quiet_on_green': quietOnGreen,
    'toast_position': toastPosition,
    'toast_seconds': toastSeconds,
  };

  NotificationPrefs copyWith({
    bool? soundOnFinish,
    String? sound,
    bool? desktop,
    bool? quietOnGreen,
    String? toastPosition,
    int? toastSeconds,
  }) => NotificationPrefs(
    soundOnFinish: soundOnFinish ?? this.soundOnFinish,
    sound: sound ?? this.sound,
    desktop: desktop ?? this.desktop,
    quietOnGreen: quietOnGreen ?? this.quietOnGreen,
    toastPosition: toastPosition ?? this.toastPosition,
    toastSeconds: toastSeconds ?? this.toastSeconds,
  );
}
