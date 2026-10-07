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
}

/// The bar text for a set of scopes: the scope itself when there is one, else a count.
String scopeSummary(Iterable<SettingsScope> scopes) {
  final distinct = scopes.toSet();
  if (distinct.isEmpty) return '';
  if (distinct.length == 1) return distinct.first.label;
  return '${distinct.length} places';
}
