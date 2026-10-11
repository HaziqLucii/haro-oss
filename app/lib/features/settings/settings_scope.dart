/// Where a save lands (§6.1 scope tag). File names are the ones the backend really writes:
/// `.haro/settings.toml` is committed, `.haro/settings.local.toml` is gitignored.
enum SettingsScope {
  device('This device'),
  team('Team · .haro/settings.toml'),
  personal('Personal · .haro/settings.local.toml'),
  teamInstructions('Team · .haro/instructions.md'),
  personalInstructions('Personal · .haro/instructions.local.md'),
  env('Personal · gitignored'),
  readOnly('Read only');

  const SettingsScope(this.label);

  final String label;

  /// Whether the pane's tag says anything. Where a save lands matters for the project tabs
  /// (committed for the team, or gitignored and yours); the app-wide tabs have nowhere else to
  /// save, so "This device" would only state the obvious.
  bool get worthATag => this != device;
}

/// Whether every scope in [scopes] is the device itself: nothing to say about where it saves.
bool onlyDevice(Iterable<SettingsScope> scopes) =>
    scopes.isNotEmpty && scopes.every((s) => !s.worthATag);

/// The bar text for a set of scopes: the scope itself when there is one, else a count.
String scopeSummary(Iterable<SettingsScope> scopes) {
  final distinct = scopes.toSet();
  if (distinct.isEmpty) return '';
  if (distinct.length == 1) return distinct.first.label;
  return '${distinct.length} places';
}
