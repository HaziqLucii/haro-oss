import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../api/haro_api.dart';
import 'settings_scope.dart';

enum SectionLoad { idle, loading, loaded, error }

String errorText(Object e) {
  if (e is HaroApiException) return e.message;
  final s = '$e';
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

/// A read-only resource behind one tab (Usage, System).
class LoadableSection<T> extends ChangeNotifier {
  LoadableSection(this._fetch);

  final Future<T> Function() _fetch;

  SectionLoad state = SectionLoad.idle;
  String? loadError;
  bool _disposed = false;

  /// What the server last returned.
  T? original;
  bool get loaded => state == SectionLoad.loaded;
  bool get dirty => false;
  Set<SettingsScope> get dirtyScopes => const {};

  Future<void> load({bool force = false}) async {
    if (state == SectionLoad.loading || (loaded && !force)) return;
    state = SectionLoad.loading;
    loadError = null;
    _notify();
    try {
      final value = await _fetch();
      original = value;
      onLoaded(value);
      state = SectionLoad.loaded;
    } catch (e) {
      loadError = errorText(e);
      state = SectionLoad.error;
    }
    _notify();
  }

  @protected
  void onLoaded(T value) {}

  @protected
  void notify() => _notify();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// An editable resource: [draft] is what the controls show, [original] what the server has.
/// Dirty means the two differ by [fingerprint], so editing a value back to its original
/// clears the save bar.
class ConfigSection<T> extends LoadableSection<T> {
  ConfigSection({
    required Future<T> Function() fetch,
    required this.put,
    required this.fingerprint,
    required this.defaultScope,
    this.scopesOf,
    this.headerScope,
  }) : super(fetch);

  /// Persists [draft] (with [original] to skip untouched parts) and returns the server's
  /// view, which becomes both original and draft.
  final Future<T> Function(T original, T draft) put;
  final Object? Function(T value) fingerprint;
  final SettingsScope defaultScope;

  /// Which scopes the pending edits touch; defaults to [defaultScope].
  final Set<SettingsScope> Function(T original, T draft)? scopesOf;

  /// Header tag for the current draft; defaults to [defaultScope].
  final SettingsScope Function(T draft)? headerScope;

  T? _draft;
  bool saving = false;
  String? saveError;

  /// Only valid once [loaded].
  T get draft => _draft as T;

  @override
  void onLoaded(T value) => _draft = value;

  /// Scope of the header tag for what is being edited.
  SettingsScope get scope =>
      loaded ? (headerScope?.call(draft) ?? defaultScope) : defaultScope;

  @override
  bool get dirty {
    final o = original;
    final d = _draft;
    if (!loaded || o == null || d == null) return false;
    return jsonEncode(fingerprint(o)) != jsonEncode(fingerprint(d));
  }

  @override
  Set<SettingsScope> get dirtyScopes {
    if (!dirty) return const {};
    final f = scopesOf;
    return f == null ? {defaultScope} : f(original as T, draft);
  }

  void edit(T Function(T current) change) {
    if (!loaded) return;
    _draft = change(draft);
    saveError = null;
    notify();
  }

  void discard() {
    if (!loaded) return;
    _draft = original;
    saveError = null;
    notify();
  }

  /// Returns true when the server accepted it.
  Future<bool> save() async {
    if (!dirty || saving) return true;
    saving = true;
    saveError = null;
    notify();
    try {
      final saved = await put(original as T, draft);
      original = saved;
      _draft = saved;
      saving = false;
      notify();
      return true;
    } catch (e) {
      saveError = errorText(e);
      saving = false;
      notify();
      return false;
    }
  }
}
