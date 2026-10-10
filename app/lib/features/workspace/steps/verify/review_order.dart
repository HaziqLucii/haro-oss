import '../code/diff_model.dart';
import '../code/proof.dart';

/// What a changed file is to a reviewer. The role decides the order the review step lists it in
/// and the small label next to it. It is read from the path and the diff alone: no model, and
/// nothing here says a file is risky, only what kind of file it is.
enum FileRole { noise, ci, deps, config, schema, auth, test, source }

const _lockfiles = {
  'package-lock.json',
  'yarn.lock',
  'pnpm-lock.yaml',
  'bun.lockb',
  'bun.lock',
  'cargo.lock',
  'poetry.lock',
  'uv.lock',
  'pipfile.lock',
  'go.sum',
  'gemfile.lock',
  'composer.lock',
  'pubspec.lock',
  'flake.lock',
};

const _manifests = {
  'package.json',
  'pyproject.toml',
  'setup.py',
  'setup.cfg',
  'cargo.toml',
  'go.mod',
  'gemfile',
  'composer.json',
  'pubspec.yaml',
  'pom.xml',
  'build.gradle',
  'build.gradle.kts',
};

/// Build output is only generated at the top of the repo: `src/build/pipeline.ts` is code.
const _generatedRoots = {
  'dist',
  'build',
  '.next',
  'out',
  'coverage',
  'node_modules',
};

const _testDirs = {'test', 'tests', '__tests__', 'spec', 'specs', 'e2e'};

const _authDirs = {'auth', 'oauth', 'authn', 'authz', 'permissions', 'crypto'};

final _authFile = RegExp(
  r'^(auth|oauth|authn|authz|session|permissions)([._-][a-z0-9._-]*)?\.[a-z0-9]+$',
);
final _testName = RegExp(r'[._-](test|spec)\.[a-z0-9]+$');
final _testSuffix = RegExp(r'tests?\.(java|kt|cs)$');
final _generatedName = RegExp(
  r'(\.g\.dart|\.freezed\.dart|_pb2\.py|\.pb\.go|\.generated\.[a-z]+)$',
);
final _configName = RegExp(r'\.config\.(js|ts|mjs|cjs|json)$');
final _tsconfig = RegExp(r'^tsconfig.*\.json$');
final _requirements = RegExp(r'^requirements.*\.txt$');
final _docName = RegExp(r'\.(md|mdx|txt|rst)$');

String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

Set<String> _dirs(String path) {
  final parts = path.split('/');
  return {for (final p in parts.take(parts.length - 1)) p.toLowerCase()};
}

bool _isTestPath(String path) {
  final base = _base(path).toLowerCase();
  if (_dirs(path).any(_testDirs.contains)) return true;
  return _testName.hasMatch(base) ||
      base.startsWith('test_') ||
      _testSuffix.hasMatch(base);
}

bool _isNoise(DiffFile f) {
  final path = f.path;
  final base = _base(path).toLowerCase();
  if (f.isBinary) return true;
  if (f.tag == DiffFileTag.renamed && f.additions == 0 && f.deletions == 0) {
    return true;
  }
  if (_lockfiles.contains(base)) return true;
  if (base.endsWith('.snap') || base.endsWith('.min.js')) return true;
  if (base.endsWith('.min.css') || base.endsWith('.map')) return true;
  if (_generatedName.hasMatch(base)) return true;
  return _generatedRoots.contains(path.split('/').first.toLowerCase()) ||
      _dirs(path).contains('__snapshots__');
}

final _roles = Expando<FileRole>('fileRole');

FileRole fileRole(DiffFile f) => _roles[f] ??= _role(f);

FileRole _role(DiffFile f) {
  if (_isNoise(f)) return FileRole.noise;
  final path = f.path;
  final lower = path.toLowerCase();
  final base = _base(lower);
  if (lower.startsWith('.github/workflows/') ||
      lower.startsWith('.circleci/') ||
      base == '.gitlab-ci.yml' ||
      base == 'jenkinsfile' ||
      base.startsWith('azure-pipelines')) {
    return FileRole.ci;
  }
  if (_manifests.contains(base) || _requirements.hasMatch(base)) {
    return FileRole.deps;
  }
  if (_docName.hasMatch(base)) return FileRole.source;
  // A test is a test even inside an auth or migrations folder: that is where a weakened guard
  // matters most.
  if (_isTestPath(path)) return FileRole.test;
  final dirs = _dirs(path);
  if (dirs.contains('migrations') ||
      dirs.contains('migration') ||
      dirs.contains('prisma') ||
      base.endsWith('.sql') ||
      base.startsWith('schema.')) {
    return FileRole.schema;
  }
  if (dirs.any(_authDirs.contains) || _authFile.hasMatch(base)) {
    return FileRole.auth;
  }
  if (_configName.hasMatch(base) ||
      _tsconfig.hasMatch(base) ||
      base.startsWith('dockerfile') ||
      base.startsWith('docker-compose') ||
      base.startsWith('.env') ||
      base == 'makefile' ||
      lower.startsWith('.haro/')) {
    return FileRole.config;
  }
  return FileRole.source;
}

/// A test file that existed before and lost more lines than it gained: the guard may have been
/// weakened. A one-line change, or a rewrite that keeps its size, is not flagged (the tamper
/// alarm covers removed tests).
bool testEdited(DiffFile f) =>
    fileRole(f) == FileRole.test &&
    f.tag != DiffFileTag.added &&
    f.deletions > f.additions;

/// The label shown beside a file, or null when its role needs none.
String? roleBadge(DiffFile f) => switch (fileRole(f)) {
  FileRole.ci => 'CI',
  FileRole.deps => 'DEPENDENCIES',
  FileRole.config => 'CONFIG',
  FileRole.schema => 'SCHEMA',
  FileRole.auth => 'AUTH',
  FileRole.test => testEdited(f) ? 'TEST EDITED' : 'TEST',
  FileRole.noise => f.isBinary ? 'BINARY' : 'GENERATED',
  FileRole.source => null,
};

int _rank(DiffFile f, ProofIndex? proof) {
  final role = fileRole(f);
  if (role == FileRole.noise) return 4;
  if (proofSquareFor(f, proof) == ProofSquare.partial) return 0;
  if (testEdited(f)) return 1;
  return switch (role) {
    FileRole.ci ||
    FileRole.deps ||
    FileRole.config ||
    FileRole.schema ||
    FileRole.auth => 1,
    FileRole.test => 2,
    _ => 3,
  };
}

/// The changed files in the order to read them: files with added lines the suite never ran,
/// then boundary files (CI, dependencies, config, schema, auth) and edited tests, then new
/// tests (the spec the agent chose), then everything else, then generated files and lockfiles.
/// Ties go by path.
List<DiffFile> reviewOrder(List<DiffFile> files, ProofIndex? proof) {
  final ranked = [for (final f in files) (_rank(f, proof), f)]
    ..sort((a, b) {
      final r = a.$1.compareTo(b.$1);
      return r != 0 ? r : a.$2.path.compareTo(b.$2.path);
    });
  return [for (final r in ranked) r.$2];
}

/// How much there is to read. Generated files and lockfiles are listed apart and not counted.
class ReviewSize {
  const ReviewSize({
    required this.lines,
    required this.files,
    required this.skipped,
  });

  final int lines;
  final int files;

  /// Generated files, lockfiles, binaries and pure renames.
  final int skipped;

  static const comfortable = 100;
  static const strained = 400;
  static const excessive = 1000;
  static const manyFiles = 20;

  /// Minutes to read at 400 changed lines an hour (the guide from the review studies),
  /// rounded up to 5.
  int get minutes => lines == 0 ? 0 : ((lines / 400 * 60) / 5).ceil() * 5;

  bool get over => lines > strained || files > manyFiles;
}

ReviewSize reviewSize(List<DiffFile> files) {
  var lines = 0;
  var counted = 0;
  var skipped = 0;
  for (final f in files) {
    if (fileRole(f) == FileRole.noise) {
      skipped++;
    } else {
      counted++;
      lines += f.additions + f.deletions;
    }
  }
  return ReviewSize(lines: lines, files: counted, skipped: skipped);
}

String readTime(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes / 60;
  return h == h.roundToDouble()
      ? '${h.round()} h'
      : '${h.toStringAsFixed(1)} h';
}
