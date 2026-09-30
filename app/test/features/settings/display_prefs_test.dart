import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/backend/backend_health.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/settings/controls/density_preview.dart';
import 'package:haro_app/features/settings/controls/grain_preview.dart';
import 'package:haro_app/features/settings/controls/toggle.dart';
import 'package:haro_app/features/settings/device_prefs.dart';
import 'package:haro_app/features/settings/display_prefs_provider.dart';
import 'package:haro_app/features/settings/settings_layers.dart';
import 'package:haro_app/features/settings/settings_register.dart';
import 'package:haro_app/features/triage/triage_page.dart';
import 'package:haro_app/features/workspace/steps/agent/agent_markdown.dart';
import 'package:haro_app/features/workspace/steps/code/diff_view.dart';
import 'package:haro_app/features/workspace/steps/code/edit_pane.dart';
import 'package:haro_app/main.dart';
import 'package:haro_app/overlays/overlay.dart';
import 'package:haro_app/router.dart';
import 'package:haro_app/shell/sidebar.dart';
import 'package:haro_app/state/display_state.dart';
import 'package:haro_app/shortcuts/app_commands.dart';
import 'package:haro_app/theme/coding_font.dart';
import 'package:haro_app/theme/display_scope.dart';
import 'package:haro_app/theme/grain.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart';

import '../../api/fixtures.dart';
import '../workspace/harness.dart' show Preview;
import '../workspace/steps/code/code_harness.dart';
import 'settings_harness.dart';

class _FakeStore extends WorkspaceStore {
  _FakeStore(this.snapshot);

  final WorkspaceSnapshot snapshot;

  @override
  WorkspaceSnapshot build() => snapshot;
}

MemoryDevicePrefsStore prefs({
  String font = 'Space Mono',
  String density = 'comfortable',
  bool grain = true,
}) => MemoryDevicePrefsStore({
  'display': {'coding_font': font, 'density': density, 'film_grain': grain},
});

class _PrefsRig extends CodeRig {
  _PrefsRig(MemoryDevicePrefsStore store, {super.files, super.preview}) {
    this.prefs = store;
  }
}

WorkspaceSnapshot triageSnapshot() => WorkspaceSnapshot(
  loaded: true,
  projects: const [
    Project(id: 'p1', name: 'haro', path: '/x', defaultBranch: 'main'),
  ],
  workspaces: {
    'p1': [
      for (final (id, status) in [
        ('red-one', 'gate_red'),
        ('run-one', 'agent_running'),
        ('idle-one', 'idle'),
        ('done-one', 'merged'),
      ])
        Workspace.fromJson(
          workspaceJson(
            id: id,
            status: status,
            gate: status == 'gate_red'
                ? gateSummaryJson(status: 'failed', failed: 3, total: 16)
                : null,
            overrides: {
              'project_id': 'p1',
              'name': id,
              'branch': 'feat/$id',
              'created_at': 1790000000.5,
            },
          ),
        ),
    ],
  },
);

Future<ProviderContainer> pumpApp(
  WidgetTester tester,
  DevicePrefsStore store, {
  Size size = const Size(1200, 800),
  String location = '/',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        workspaceStoreProvider.overrideWith(() => _FakeStore(triageSnapshot())),
        backendStatusProvider.overrideWith(
          (ref) => Stream.value(BackendStatus.up),
        ),
        devicePrefsStoreProvider.overrideWithValue(store),
      ],
      child: HaroApp(router: buildRouter(initialLocation: location)),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(TriagePage)));
}

double rowHeight(WidgetTester tester, Type within, String name) => tester
    .getSize(
      find
          .ancestor(
            of: find.descendant(
              of: find.byType(within),
              matching: find.text(name),
            ),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    )
    .height;

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => registerSettingsCommands(ref, () => context),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// Every colour painted by a [RichText] under [of], including nested spans.
Set<Color> paintedColours(WidgetTester tester, Finder of) {
  final out = <Color>{};
  for (final r in tester.widgetList<RichText>(
    find.descendant(of: of, matching: find.byType(RichText)),
  )) {
    r.text.visitChildren((s) {
      final c = s is TextSpan ? s.style?.color : null;
      if (c != null) out.add(c);
      return true;
    });
  }
  return out;
}

bool hasPalette(Set<Color> colours) => SyntaxColors.all.any(
  (p) => colours.any((c) => c.r == p.r && c.g == p.g && c.b == p.b),
);

Future<(ProviderContainer, MemoryDevicePrefsStore)> openDisplay(
  WidgetTester tester, {
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  haroOverlayDepth.value = 0;
  final store = MemoryDevicePrefsStore();
  final container = ProviderContainer(
    overrides: [
      workspaceStoreProvider.overrideWith(() => _FakeStore(triageSnapshot())),
      haroApiProvider.overrideWithValue(FakeBackend().api()),
      devicePrefsStoreProvider.overrideWithValue(store),
      settingsLayersProvider.overrideWithValue(FakeLayers()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildHaroTheme(),
        routerConfig: GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => const _Host())],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  container.read(appCommandsProvider).openSettings(SettingsTab.display);
  await tester.pumpAndSettle();
  return (container, store);
}

void main() {
  setUpAll(() async {
    await loadBrandFonts();
    codeEditorHighlighting = false;
  });

  group('provider', () {
    test('defaults are the shipped look when the file is missing', () async {
      final c = ProviderContainer(
        overrides: [
          devicePrefsStoreProvider.overrideWithValue(MemoryDevicePrefsStore()),
        ],
      );
      addTearDown(c.dispose);
      c.read(displayPrefsProvider);
      await Future<void>.delayed(Duration.zero);
      final d = c.read(displayPrefsProvider);
      expect(d.codingFont, 'Space Mono');
      expect(d.density, 'comfortable');
      expect(d.filmGrain, isTrue);
    });

    test('loads the stored display prefs at startup', () async {
      final c = ProviderContainer(
        overrides: [
          devicePrefsStoreProvider.overrideWithValue(
            prefs(font: 'Fira Code', density: 'compact', grain: false),
          ),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(displayPrefsProvider).codingFont, 'Space Mono');
      await Future<void>.delayed(Duration.zero);
      final d = c.read(displayPrefsProvider);
      expect(d.codingFont, 'Fira Code');
      expect(d.density, 'compact');
      expect(d.filmGrain, isFalse);
    });

    test(
      'a set() that lands before the first read is not overwritten',
      () async {
        final c = ProviderContainer(
          overrides: [
            devicePrefsStoreProvider.overrideWithValue(
              prefs(font: 'Fira Code'),
            ),
          ],
        );
        addTearDown(c.dispose);
        c
            .read(displayPrefsProvider.notifier)
            .set(const DisplayPrefs(codingFont: 'IBM Plex Mono'));
        await Future<void>.delayed(Duration.zero);
        expect(c.read(displayPrefsProvider).codingFont, 'IBM Plex Mono');
      },
    );

    test('every option maps to a bundled family, unknown falls back', () {
      expect(codingFontFamily('JetBrains Mono'), 'JetBrainsMono');
      expect(codingFontFamily('Fira Code'), 'FiraCode');
      expect(codingFontFamily('IBM Plex Mono'), 'IBMPlexMono');
      expect(codingFontFamily('Space Mono'), HaroTokens.fontMono);
      expect(codingFontFamily('Comic Sans'), HaroTokens.fontMono);
      for (final o in DisplayPrefs.fontOptions) {
        expect(codingFontFamily(o), isNotEmpty);
      }
    });
  });

  testWidgets('saving Display in Settings updates the provider live', (
    tester,
  ) async {
    final (container, store) = await openDisplay(tester);

    String previewFamily() {
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('code-font-preview')),
          matching: find.byType(Text),
        ),
      );
      return (text.textSpan! as TextSpan).children!.first.style!.fontFamily!;
    }

    expect(previewFamily(), 'SpaceMono');
    await tester.tap(find.text('Fira Code'));
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(container.read(displayPrefsProvider).density, 'comfortable');
    expect(
      previewFamily(),
      'FiraCode',
      reason: 'the preview follows the draft before Save',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final d = container.read(displayPrefsProvider);
    expect(d.codingFont, 'Fira Code');
    expect(d.density, 'compact');
    expect((store.data['display'] as Map)['density'], 'compact');
  });

  group('film grain', () {
    double grainOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byType(GrainOverlay),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    testWidgets('shown by default', (tester) async {
      await pumpApp(tester, MemoryDevicePrefsStore());
      expect(grainOpacity(tester), 1);
    });

    testWidgets('hidden when off, and toggles live', (tester) async {
      final c = await pumpApp(tester, prefs(grain: false));
      expect(grainOpacity(tester), 0);
      c
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(filmGrain: true));
      await tester.pump();
      await tester.pump(HaroTokens.fadeFast);
      expect(grainOpacity(tester), 1);
    });
  });

  group('coding font', () {
    testWidgets('reaches the diff, the editor and the terminal', (
      tester,
    ) async {
      final rig = _PrefsRig(prefs(font: 'Fira Code'));
      await rig.pump(tester, step: 'code');
      final diffFamilies = tester
          .widgetList<RichText>(
            find.descendant(
              of: find.byType(DiffView),
              matching: find.byType(RichText),
            ),
          )
          .map((w) => w.text.style?.fontFamily);
      expect(diffFamilies, contains('FiraCode'));

      await tester.tap(find.byKey(const ValueKey('rail-terminal-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView).first)
            .textStyle
            .fontFamily,
        'FiraCode',
      );
    });

    testWidgets('the editor follows a live change', (tester) async {
      final rig = _PrefsRig(
        prefs(font: 'JetBrains Mono'),
        files: {
          'lib/rates.ts': const FileContent(
            path: 'lib/rates.ts',
            content: 'const base = 2;\n',
          ),
        },
      );
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pumpAndSettle();
      String editorFamily() =>
          tester.widget<CodeEditor>(find.byType(CodeEditor)).style!.fontFamily!;
      expect(editorFamily(), 'JetBrainsMono');

      ProviderScope.containerOf(tester.element(find.byType(CodeEditor)))
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(codingFont: 'IBM Plex Mono'));
      await tester.pumpAndSettle();
      expect(editorFamily(), 'IBMPlexMono');
    });

    testWidgets('inline code in agent prose, not the prose itself', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaroTheme(),
          home: Material(
            child: DisplayScope(
              codingFont: 'IBM Plex Mono',
              density: DensityScale.comfortable,
              child: const AgentProse(
                'run `flutter_test` now\n\n```\nblock_text\n```',
              ),
            ),
          ),
        ),
      );
      final families = <String, String?>{};
      final rich = tester.widgetList<RichText>(find.byType(RichText));
      for (final r in rich) {
        r.text.visitChildren((s) {
          if (s is TextSpan && s.text != null) {
            families[s.text!] = s.style?.fontFamily;
          }
          return true;
        });
      }
      expect(families['flutter_test'], 'IBMPlexMono');
      expect(families['run '], isNot('IBMPlexMono'));
      expect(families['block_text'], 'IBMPlexMono');
    });
  });

  group('syntax colours', () {
    final preview = find.byKey(const ValueKey('code-font-preview'));

    testWidgets('default is colour, the row sits under Coding font', (
      tester,
    ) async {
      await openDisplay(tester);
      expect(hasPalette(paintedColours(tester, preview)), isTrue);
      final font = tester.getTopLeft(find.text('Coding font')).dy;
      final syntax = tester.getTopLeft(find.text('Syntax colours')).dy;
      final previewTop = tester.getTopLeft(preview).dy;
      expect(font, lessThan(syntax));
      expect(syntax, lessThan(previewTop));
    });

    testWidgets('the preview follows the draft before Save', (tester) async {
      final (container, store) = await openDisplay(tester);
      await tester.tap(find.text('Monochrome'));
      await tester.pumpAndSettle();
      expect(hasPalette(paintedColours(tester, preview)), isFalse);
      expect(container.read(displayPrefsProvider).syntaxColour, isTrue);

      await tester.tap(find.text('Colour'));
      await tester.pumpAndSettle();
      expect(hasPalette(paintedColours(tester, preview)), isTrue);

      await tester.tap(find.text('Monochrome'));
      await tester.tap(find.text('Fira Code'));
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(
        find.descendant(of: preview, matching: find.byType(Text)),
      );
      expect(
        (text.textSpan! as TextSpan).children!.first.style!.fontFamily,
        'FiraCode',
      );
      expect(hasPalette(paintedColours(tester, preview)), isFalse);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(container.read(displayPrefsProvider).syntaxColour, isFalse);
      expect((store.data['display'] as Map)['syntax_colour'], false);
    });

    testWidgets('the preview shows every palette colour when on', (
      tester,
    ) async {
      await openDisplay(tester);
      final painted = paintedColours(tester, preview);
      for (final p in SyntaxColors.all) {
        expect(
          painted.any((c) => c.r == p.r && c.g == p.g && c.b == p.b),
          isTrue,
          reason: '$p',
        );
      }
    });

    testWidgets('the diff gets coloured spans on, monochrome off', (
      tester,
    ) async {
      await _PrefsRig(MemoryDevicePrefsStore()).pump(tester, step: 'code');
      expect(hasPalette(paintedColours(tester, find.byType(DiffView))), isTrue);

      await _PrefsRig(
        MemoryDevicePrefsStore({
          'display': {'syntax_colour': false},
        }),
      ).pump(tester, step: 'code');
      expect(
        hasPalette(paintedColours(tester, find.byType(DiffView))),
        isFalse,
      );
    });

    testWidgets('the diff follows a live change', (tester) async {
      await _PrefsRig(MemoryDevicePrefsStore()).pump(tester, step: 'code');
      final c = ProviderScope.containerOf(
        tester.element(find.byType(DiffView)),
      );
      c
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(syntaxColour: false));
      await tester.pumpAndSettle();
      expect(
        hasPalette(paintedColours(tester, find.byType(DiffView))),
        isFalse,
      );
    });

    testWidgets('the editor theme is coloured on and monochrome off', (
      tester,
    ) async {
      codeEditorHighlighting = true;
      addTearDown(() => codeEditorHighlighting = false);
      final files = {
        'lib/rates.ts': const FileContent(
          path: 'lib/rates.ts',
          content: 'const base = 2;\n',
        ),
      };
      Color? keyword() => tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .style!
          .codeTheme!
          .theme['keyword']!
          .color;

      final rig = _PrefsRig(MemoryDevicePrefsStore(), files: files);
      await rig.pump(tester, step: 'code');
      await tester.tap(find.byKey(const ValueKey('mode-edit')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(keyword(), SyntaxColors.keyword);

      ProviderScope.containerOf(tester.element(find.byType(CodeEditor)))
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(syntaxColour: false));
      await tester.pump(const Duration(milliseconds: 300));
      expect(keyword(), HaroTokens.ink);
    });

    Future<Set<Color>> proseColours(WidgetTester tester, bool colour) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHaroTheme(),
          home: Material(
            child: DisplayScope(
              codingFont: 'Space Mono',
              density: DensityScale.comfortable,
              syntaxColour: colour,
              child: const AgentProse(
                'use `inline` here\n\n```ts\nconst a = "x"; // hi\n```',
              ),
            ),
          ),
        ),
      );
      return paintedColours(tester, find.byType(AgentProse));
    }

    testWidgets('agent code blocks are coloured on, monochrome off', (
      tester,
    ) async {
      final on = await proseColours(tester, true);
      expect(on, contains(SyntaxColors.keyword));
      expect(on, contains(SyntaxColors.string));
      final off = await proseColours(tester, false);
      expect(hasPalette(off), isFalse);
    });

    testWidgets('agent inline code stays plain in colour mode', (tester) async {
      await proseColours(tester, true);
      Color? inline;
      for (final r in tester.widgetList<RichText>(find.byType(RichText))) {
        r.text.visitChildren((s) {
          if (s is TextSpan && s.text == 'inline') inline = s.style?.color;
          return true;
        });
      }
      expect(inline, HaroTokens.ink86);
    });
  });

  group('display previews', () {
    testWidgets('density preview rows follow the draft before Save', (
      tester,
    ) async {
      final (container, _) = await openDisplay(tester);
      double rowHeight() => tester
          .getSize(
            find
                .descendant(
                  of: find.byType(DensityPreview),
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          )
          .height;
      expect(rowHeight(), DensityScale.comfortable.sidebarRow);
      expect(
        find.descendant(
          of: find.byType(DensityPreview),
          matching: find.byType(SidebarWorkspaceRow),
        ),
        findsNWidgets(3),
      );
      await tester.tap(find.text('Compact'));
      await tester.pumpAndSettle();
      expect(rowHeight(), DensityScale.compact.sidebarRow);
      expect(container.read(displayPrefsProvider).density, 'comfortable');
      await tester.tap(find.text('Comfortable'));
      await tester.pumpAndSettle();
      expect(rowHeight(), DensityScale.comfortable.sidebarRow);
    });

    testWidgets('density preview shows idle, red and merged in state colours', (
      tester,
    ) async {
      await openDisplay(tester);
      final words = find.descendant(
        of: find.byType(DensityPreview),
        matching: find.byType(Text),
      );
      final texts = tester.widgetList<Text>(words).map((t) => t.data).toList();
      expect(texts, containsAll(['red', 'merged']));
      expect(texts, isNot(contains('idle')));
      final red = tester.widget<Text>(
        find.descendant(
          of: find.byType(DensityPreview),
          matching: find.text(DisplayState.red.word),
        ),
      );
      expect(red.style!.color, HaroTokens.fail);
    });

    testWidgets('grain panel shows and hides the texture with the draft', (
      tester,
    ) async {
      final (container, _) = await openDisplay(tester);
      double texture() => tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('grain-preview-texture')),
          )
          .opacity;
      expect(find.byType(GrainPreview), findsOneWidget);
      expect(texture(), 1);
      await tester.ensureVisible(find.byType(SettingToggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SettingToggle));
      await tester.pumpAndSettle();
      expect(texture(), 0);
      expect(container.read(displayPrefsProvider).filmGrain, isTrue);
      await tester.tap(find.byType(SettingToggle));
      await tester.pumpAndSettle();
      expect(texture(), 1);
    });

    testWidgets('no overflow at 960x640 with every preview on screen', (
      tester,
    ) async {
      await openDisplay(tester, size: const Size(960, 640));
      expect(tester.takeException(), isNull);
      final scroll = find
          .ancestor(
            of: find.byType(GrainPreview),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final dy in [-300.0, -600.0, -1200.0]) {
        await tester.drag(scroll, Offset(0, dy));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('density', () {
    testWidgets('compact tightens sidebar and triage rows only', (
      tester,
    ) async {
      await pumpApp(tester, prefs());
      final sideCosy = rowHeight(tester, Sidebar, 'red-one');
      final triageCosy = rowHeight(tester, TriagePage, 'red-one');
      expect(sideCosy, DensityScale.comfortable.sidebarRow);
      expect(triageCosy, greaterThanOrEqualTo(62));

      await pumpApp(tester, prefs(density: 'compact'));
      final sideTight = rowHeight(tester, Sidebar, 'red-one');
      final triageTight = rowHeight(tester, TriagePage, 'red-one');
      expect(sideTight, DensityScale.compact.sidebarRow);
      expect(triageTight, lessThan(triageCosy));
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching density live resizes rows', (tester) async {
      final c = await pumpApp(tester, prefs());
      expect(rowHeight(tester, Sidebar, 'red-one'), 30);
      c
          .read(displayPrefsProvider.notifier)
          .set(const DisplayPrefs(density: 'compact'));
      await tester.pumpAndSettle();
      expect(rowHeight(tester, Sidebar, 'red-one'), 26);
    });

    for (final density in DisplayPrefs.densityOptions) {
      testWidgets('triage has no overflow at 960x640 ($density)', (
        tester,
      ) async {
        await pumpApp(
          tester,
          prefs(density: density),
          size: const Size(960, 640),
        );
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.descendant(
            of: find.byType(TriagePage),
            matching: find.byType(Scrollable),
          ),
          const Offset(0, -2000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('workspace steps have no overflow at 960x640 ($density)', (
        tester,
      ) async {
        for (final preview in [Preview.red, Preview.green, Preview.merged]) {
          for (final step in ['agent', 'code', 'verify', 'ship']) {
            final rig = _PrefsRig(prefs(density: density), preview: preview);
            await rig.pump(tester, size: const Size(960, 640), step: step);
            expect(tester.takeException(), isNull, reason: '$preview $step');
          }
        }
      });
    }
  });
}
