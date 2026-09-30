import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_ws.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_actions.dart';
import 'package:haro_app/data/workspace_detail.dart';
import 'package:haro_app/data/workspace_detail_lazy.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart';
import 'package:haro_app/features/workspace/steps/code/code_providers.dart';
import 'package:haro_app/features/workspace/steps/code/workbench/workbench_ops.dart';
import 'package:haro_app/state/diff_stats.dart';

import '../../../../state/builders.dart' as builders;

import '../../harness.dart';

const rates = '''diff --git a/lib/rates.ts b/lib/rates.ts
index 1111111..2222222 100644
--- a/lib/rates.ts
+++ b/lib/rates.ts
@@ -1,5 +1,7 @@ export
 import { zone } from './zones';
-const base = 1;
+const base = 2;
+const surcharge = 3;
+// note
 export function rate() {
   return base;
 }
diff --git a/README.md b/README.md
index 3333333..4444444 100644
--- a/README.md
+++ b/README.md
@@ -1,2 +1,3 @@
 # haro
+more docs
 end
diff --git a/lib/zones.ts b/lib/zones.ts
index 6666666..7777777 100644
--- a/lib/zones.ts
+++ b/lib/zones.ts
@@ -1 +1,2 @@
 export const z = 1;
+export const y = 2;
diff --git a/lib/old.ts b/lib/old.ts
deleted file mode 100644
index 5555555..0000000
--- a/lib/old.ts
+++ /dev/null
@@ -1,2 +0,0 @@
-export const gone = 1;
-export const also = 2;
''';

/// Lines 2 and 3 of lib/rates.ts ran / never ran; the comment on line 4 is not coverable.
VerifiedHunksResponse verified({bool supported = true}) =>
    VerifiedHunksResponse(
      baseRef: 'origin/main',
      supported: supported,
      files: [
        const VerifiedFile(
          path: 'lib/rates.ts',
          inMap: true,
          added: 3,
          executed: 1,
          unexecuted: 1,
          noncoverable: 1,
          lines: {2: 3, 3: 0, 4: null},
        ),
        const VerifiedFile(
          path: 'lib/zones.ts',
          inMap: true,
          added: 1,
          executed: 1,
          lines: {2: 1},
        ),
        const VerifiedFile(
          path: 'README.md',
          inMap: false,
          added: 1,
          unexecuted: 1,
        ),
      ],
    );

class FileActions extends WorkspaceActions {
  FileActions(
    super.ref,
    super.workspaceId,
    this.files,
    this.reads,
    this.saves, {
    this.saveError,
    this.gateRuns,
    this.commits,
    this.saveWait,
  });

  final Map<String, FileContent> files;

  /// Holds every save open until it completes, for a test that needs one in flight.
  final Future<void>? saveWait;
  final List<String> reads;
  final List<(String, String)> saves;
  final Object? saveError;

  /// Scope of each gate run started (true = impacted), when the test wants to see them.
  final List<bool>? gateRuns;

  /// Messages sent to `commitStaged`, when a test wants them.
  final List<String>? commits;

  @override
  Future<TestRun> runGate({
    bool impacted = false,
    bool failedOnly = false,
  }) async {
    gateRuns?.add(impacted);
    return builders.run();
  }

  @override
  Future<CommitResult> commitStaged(String message) async {
    commits?.add(message);
    return const CommitResult(committed: 'abc123');
  }

  @override
  Future<FileContent> readFile(String path) async {
    reads.add(path);
    return files[path] ?? FileContent(path: path, content: 'hello\n');
  }

  @override
  Future<void> saveFile(String path, String content) async {
    saves.add((path, content));
    await saveWait;
    if (saveError != null) throw saveError!;
    files[path] = FileContent(path: path, content: content);
  }
}

class CodeRig extends Rig {
  CodeRig({
    String diff = rates,
    this.proof,
    this.tree = const [],
    this.files = const {},
    this.saveError,
    bool runOnSave = false,
    this.gitFiles = const [],
    this.saveWait,
    this.makeDetail,
    Preview preview = Preview.green,
    super.mode,
  }) : reads = [],
       saves = [],
       gateRuns = [],
       commits = [],
       ops = [],
       super(preview, detail: _detail(preview, diff, runOnSave, mode));

  final VerifiedHunksResponse? proof;
  final List<FileNode> tree;
  final Map<String, FileContent> files;
  final Object? saveError;
  final Future<void>? saveWait;

  /// Builds the workspace detail notifier, for a test that changes the diff mid-run.
  final WorkspaceDetailNotifier Function(String id, WorkspaceDetail d)?
  makeDetail;

  /// What `git status` reports for the Changes panel.
  final List<GitFileStatus> gitFiles;
  final List<String> reads;
  final List<(String, String)> saves;
  final List<bool> gateRuns;
  final List<String> commits;

  /// Every write the workbench made, as `verb:args`.
  final List<String> ops;

  static WorkspaceDetail _detail(
    Preview p,
    String diff,
    bool runOnSave,
    WorkspaceMode mode,
  ) => detailFor(p, mode: mode).copyWith(
    gateConfig: runOnSave ? const GateConfig(runOnSave: true) : null,
    diff: DiffResponse(
      baseRef: 'origin/main',
      diff: diff,
      filesChanged: parseDiffStats(diff).files,
    ),
    diffStats: parseDiffStats(diff),
  );

  /// Rig's own list with its actions stand-in swapped for one that serves files; a family
  /// cannot be overridden twice in one scope.
  @override
  List<Override> get overrides => [
    devicePrefsStoreProvider.overrideWithValue(prefs),
    workspaceDetailProvider.overrideWith2(
      (wsId) =>
          (makeDetail ?? FixedDetail.new)(wsId, detail ?? detailFor(preview)),
    ),
    workspaceActionsProvider.overrideWith(
      (ref, id) => FileActions(
        ref,
        id,
        files,
        reads,
        saves,
        saveError: saveError,
        gateRuns: gateRuns,
        commits: commits,
        saveWait: saveWait,
      ),
    ),
    workspaceGitStatusProvider.overrideWith(
      (ref, wsId) async => GitStatusResponse(
        branch: 'feat/electron-optimization',
        baseRef: 'origin/main',
        behind: behind,
        files: gitFiles,
        dirty: gitFiles.length,
      ),
    ),
    workbenchOpsProvider.overrideWith((ref, id) => RecordingOps(ref, id, ops)),
    workspaceStoreProvider.overrideWith(
      () => FakeStore(
        WorkspaceSnapshot(
          loaded: true,
          projects: [project()],
          workspaces: {
            'p1': [workspaceFor(preview)],
          },
        ),
      ),
    ),
    haroWsProvider.overrideWithValue(
      HaroWs(Uri.parse('http://127.0.0.1:8000'), connector: net.connect),
    ),
    backendStatusProvider.overrideWith((ref) => Stream.value(BackendStatus.up)),
    workspaceUrlOpenerProvider.overrideWithValue((uri) async {
      opened.add(uri);
      return true;
    }),
    workspaceVerifiedHunksProvider.overrideWith((ref, id) async => proof),
    codeFileTreeProvider.overrideWith((ref, id) async => tree),
  ];
}

class RecordingOps extends WorkbenchOps {
  RecordingOps(super.ref, super.workspaceId, this.log);

  final List<String> log;

  @override
  Future<void> createEntry(String path, {required bool dir}) async =>
      log.add('create:$path:${dir ? 'dir' : 'file'}');

  @override
  Future<void> renameEntry(String path, String to) async =>
      log.add('rename:$path:$to');

  @override
  Future<void> deleteEntry(String path) async => log.add('delete:$path');

  @override
  Future<void> stage(List<String> paths) async =>
      log.add('stage:${paths.join(',')}');

  @override
  Future<void> unstage(List<String> paths) async =>
      log.add('unstage:${paths.join(',')}');
}

FileNode file(String path) => FileNode(name: path.split('/').last, path: path);

FileNode dir(String path, List<FileNode> children) => FileNode(
  name: path.split('/').last,
  path: path,
  dir: true,
  children: children,
);

/// The explorer opens on All files; the changed-file rows live under its Changes toggle.
Future<void> showChanges(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('explorer-scope:changes')));
  await tester.pumpAndSettle();
}
