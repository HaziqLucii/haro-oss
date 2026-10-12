import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/api/haro_api.dart' show HaroApiException;
import 'package:haro_app/api/models/models.dart';
import 'package:haro_app/data/github_accounts.dart';
import 'package:haro_app/data/workspace_store.dart';
import 'package:haro_app/features/workspace/rail/workspace_rail.dart'
    show workspaceUrlOpenerProvider;
import 'package:haro_app/shell/github_account_menu.dart';
import 'package:haro_app/shell/github_avatar.dart';
import 'package:haro_app/shell/haro_shell.dart';
import 'package:haro_app/theme/haro_theme.dart';
import 'package:haro_app/theme/tokens.dart';
import 'package:haro_app/widgets/check_mark.dart';

import '../data/github_harness.dart';
import 'fake_shell_data.dart';

const _tinyPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

GithubAccounts _accounts({String? defaultLogin = 'octo'}) => GithubAccounts(
  defaultLogin: defaultLogin,
  accounts: [
    GithubAccount(
      login: 'octo',
      avatarUrl: 'https://github.com/octo.png?size=64',
      isDefault: defaultLogin == 'octo',
      terminalActive: true,
    ),
    GithubAccount(
      login: 'work',
      avatarUrl: 'https://github.com/work.png?size=64',
      isDefault: defaultLogin == 'work',
    ),
  ],
);

class _Rig {
  _Rig(this.api);

  final FakeGithubApi api;
  final opened = <Uri>[];
  final images = <String>[];
}

/// `image: true` serves a real picture; otherwise the load fails like an offline machine.
Future<_Rig> _pump(
  WidgetTester tester, {
  GithubAccounts? accounts,
  String? projectId,
  bool image = false,
  FakeGithubApi? fake,
}) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = fake ?? FakeGithubApi();
  if (accounts != null) api.accounts = accounts;
  final rig = _Rig(api);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        haroApiProvider.overrideWithValue(api),
        workspaceUrlOpenerProvider.overrideWithValue((uri) async {
          rig.opened.add(uri);
          return true;
        }),
        githubAvatarImageProvider.overrideWithValue((url) {
          rig.images.add(url);
          return image
              ? MemoryImage(base64Decode(_tinyPng))
              : _FailingImage(url);
        }),
      ],
      child: MaterialApp(
        theme: buildHaroTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: GithubAccountButton(projectId: projectId),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (image) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  return rig;
}

class _FailingImage extends ImageProvider<_FailingImage> {
  const _FailingImage(this.url);

  final String url;

  @override
  Future<_FailingImage> obtainKey(ImageConfiguration configuration) async =>
      this;

  @override
  ImageStreamCompleter loadImage(
    _FailingImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Future.error(Exception('offline')));
}

final _avatar = find.byKey(const ValueKey('gh-avatar-button'));
Finder _in(String key, Finder what) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: what);

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_avatar);
  await tester.pumpAndSettle();
}

void main() {
  group('avatar faces', () {
    testWidgets('letter ring when the picture cannot load', (tester) async {
      await _pump(tester, accounts: _accounts());
      expect(find.byKey(const ValueKey('gh-avatar-letter')), findsOneWidget);
      expect(find.text('O'), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-avatar-person')), findsNothing);
    });

    testWidgets('the picture, grayscale, once it loads', (tester) async {
      final rig = await _pump(tester, accounts: _accounts(), image: true);
      expect(find.byKey(const ValueKey('gh-avatar-letter')), findsNothing);
      expect(find.byKey(const ValueKey('gh-avatar-image')), findsOneWidget);
      expect(find.byType(ColorFiltered), findsOneWidget);
      expect(rig.images, contains('https://github.com/octo.png?size=64'));
    });

    testWidgets('person icon with no accounts', (tester) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('gh-avatar-person')), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-avatar-letter')), findsNothing);
    });

    testWidgets('person icon when gh is missing', (tester) async {
      await _pump(
        tester,
        accounts: GithubAccounts(
          ghAvailable: false,
          accounts: _accounts().accounts,
        ),
      );
      expect(find.byKey(const ValueKey('gh-avatar-person')), findsOneWidget);
    });

    testWidgets('person icon when the lookup fails', (tester) async {
      final api = FakeGithubApi()
        ..accountsError = const HaroApiException(404, 'no route');
      await _pump(tester, fake: api);
      expect(find.byKey(const ValueKey('gh-avatar-person')), findsOneWidget);
    });

    testWidgets('a hairline ring, a circle, no shadow', (tester) async {
      await _pump(tester, accounts: _accounts());
      final box = tester.widget<AnimatedContainer>(
        find.descendant(of: _avatar, matching: find.byType(AnimatedContainer)),
      );
      final deco = box.decoration! as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
      expect(deco.boxShadow, isNull);
      expect(
        tester.getSize(find.byType(GithubAvatar)).width,
        HaroTokens.avatarSize,
      );
    });
  });

  group('menu', () {
    testWidgets(
      'lists the accounts with the default marked and the terminal tagged',
      (tester) async {
        await _pump(tester, accounts: _accounts());
        await _openMenu(tester);
        expect(find.text('ACCOUNTS'), findsOneWidget);
        expect(find.text('octo'), findsOneWidget);
        expect(find.text('work'), findsOneWidget);
        expect(_in('gh-account-octo', find.byType(CheckMark)), findsOneWidget);
        expect(_in('gh-account-work', find.byType(CheckMark)), findsNothing);
        expect(_in('gh-account-octo', find.text('TERMINAL')), findsOneWidget);
        expect(_in('gh-account-work', find.text('TERMINAL')), findsNothing);
        expect(find.text('Add GitHub account…'), findsOneWidget);
        expect(find.text('THIS PROJECT USES'), findsNothing);
      },
    );

    testWidgets(
      'clicking an account makes it the default and the avatar follows',
      (tester) async {
        final rig = await _pump(tester, accounts: _accounts());
        await _openMenu(tester);
        expect(find.text('O'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('gh-account-work')));
        await tester.pumpAndSettle();
        expect(rig.api.calls, contains('default:work'));
        expect(_in('gh-account-work', find.byType(CheckMark)), findsOneWidget);
        expect(_in('gh-account-octo', find.byType(CheckMark)), findsNothing);
        final avatar = tester.widget<GithubAvatar>(
          find.descendant(of: _avatar, matching: find.byType(GithubAvatar)),
        );
        expect(avatar.account!.login, 'work');
      },
    );

    testWidgets('the avatar switches before the backend answers', (
      tester,
    ) async {
      final api = FakeGithubApi()..accounts = _accounts();
      await _pump(tester, fake: api);
      await _openMenu(tester);
      final element = tester.element(find.byKey(const ValueKey('gh-menu')));
      final container = ProviderScope.containerOf(element);
      final pending = container
          .read(githubAccountsProvider.notifier)
          .setDefault('work');
      expect(container.read(githubAccountsProvider).data!.defaultLogin, 'work');
      await pending;
    });

    testWidgets(
      'closing the menu while a default switch is pending is harmless',
      (tester) async {
        final api = FakeGithubApi()
          ..accounts = _accounts()
          ..defaultGate = Completer<void>();
        await _pump(tester, fake: api, projectId: 'p1');
        await _openMenu(tester);
        await tester.tap(find.byKey(const ValueKey('gh-account-work')));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('gh-menu')), findsNothing);
        api.defaultGate!.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(api.calls, contains('default:work'));
      },
    );

    testWidgets('no project section without a project', (tester) async {
      await _pump(tester, accounts: _accounts());
      await _openMenu(tester);
      expect(find.byKey(const ValueKey('gh-project-auto')), findsNothing);
    });

    testWidgets(
      'project section: Auto shows who and why, rows override, Auto clears',
      (tester) async {
        final api = FakeGithubApi()
          ..accounts = _accounts()
          ..project = const ProjectGhAccount(resolved: 'work', source: 'auto');
        await _pump(tester, fake: api, projectId: 'p1');
        await _openMenu(tester);
        expect(find.text('THIS PROJECT USES'), findsOneWidget);
        expect(find.text('work · matches the repo owner'), findsOneWidget);
        expect(_in('gh-project-auto', find.byType(CheckMark)), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('gh-project-octo')));
        await tester.pumpAndSettle();
        expect(api.calls, contains('override:p1:octo'));
        expect(_in('gh-project-octo', find.byType(CheckMark)), findsOneWidget);
        expect(_in('gh-project-auto', find.byType(CheckMark)), findsNothing);

        await tester.tap(find.byKey(const ValueKey('gh-project-auto')));
        await tester.pumpAndSettle();
        expect(api.calls, contains('override:p1:auto'));
        expect(_in('gh-project-auto', find.byType(CheckMark)), findsOneWidget);
      },
    );

    testWidgets('gh missing: one explanation, no actions', (tester) async {
      await _pump(
        tester,
        projectId: 'p1',
        accounts: const GithubAccounts(ghAvailable: false),
      );
      await _openMenu(tester);
      expect(find.byKey(const ValueKey('gh-missing')), findsOneWidget);
      expect(find.textContaining('not installed'), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-add')), findsNothing);
      expect(find.byKey(const ValueKey('gh-project-auto')), findsNothing);
    });

    testWidgets('no accounts: says so and still offers sign-in', (
      tester,
    ) async {
      await _pump(tester, accounts: const GithubAccounts());
      await _openMenu(tester);
      expect(find.byKey(const ValueKey('gh-none')), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-add')), findsOneWidget);
    });

    testWidgets('Esc closes', (tester) async {
      await _pump(tester, accounts: _accounts());
      await _openMenu(tester);
      expect(find.byKey(const ValueKey('gh-menu')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gh-menu')), findsNothing);
    });

    testWidgets('a click outside closes', (tester) async {
      await _pump(tester, accounts: _accounts());
      await _openMenu(tester);
      await tester.tapAt(const Offset(60, 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gh-menu')), findsNothing);
    });

    testWidgets('arrow keys and Enter pick a row', (tester) async {
      final rig = await _pump(tester, accounts: _accounts());
      await _openMenu(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(rig.api.calls, contains('default:work'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(rig.api.calls, contains('default:octo'));
    });

    testWidgets('Add GitHub account opens the login dialog', (tester) async {
      await _pump(tester, accounts: _accounts());
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('gh-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gh-menu')), findsNothing);
      expect(find.byKey(const ValueKey('gh-login')), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-login-code')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('refreshes the lists every time it opens', (tester) async {
      final rig = await _pump(tester, accounts: _accounts(), projectId: 'p1');
      final before = rig.api.calls.where((c) => c == 'accounts').length;
      await _openMenu(tester);
      expect(
        rig.api.calls.where((c) => c == 'accounts').length,
        greaterThan(before),
      );
      expect(rig.api.calls, contains('project:p1'));
    });
  });

  group('login dialog', () {
    Future<void> openLogin(WidgetTester tester) async {
      await _openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('gh-add')));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the code, copies it, opens the device page', (
      tester,
    ) async {
      String? clip;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clip = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final rig = await _pump(tester, accounts: _accounts());
      await openLogin(tester);
      expect(find.text('ABCD-1234'), findsOneWidget);
      expect(find.text('Open github.com/login/device'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gh-login-copy')));
      await tester.pumpAndSettle();
      expect(clip, 'ABCD-1234');
      expect(find.text('COPIED'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gh-login-open')));
      await tester.pumpAndSettle();
      expect(rig.opened.single.toString(), 'https://github.com/login/device');
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'polls every second, then done refreshes the accounts and closes',
      (tester) async {
        final api = FakeGithubApi()
          ..accounts = _accounts()
          ..pollReplies = const [
            GithubLoginStatus(state: GithubLoginState.pending),
            GithubLoginStatus(state: GithubLoginState.pending),
            GithubLoginStatus(state: GithubLoginState.done, login: 'newbie'),
          ];
        await _pump(tester, fake: api);
        await openLogin(tester);
        expect(api.calls.where((c) => c == 'login-poll'), isEmpty);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(api.calls.where((c) => c == 'login-poll'), hasLength(2));
        expect(find.byKey(const ValueKey('gh-login-done')), findsNothing);

        final accountCalls = api.calls.where((c) => c == 'accounts').length;
        api.accounts = GithubAccounts(
          defaultLogin: 'octo',
          accounts: [
            ..._accounts().accounts,
            const GithubAccount(login: 'newbie', avatarUrl: 'u'),
          ],
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.byKey(const ValueKey('gh-login-done')), findsOneWidget);
        expect(find.text('Signed in as newbie.'), findsOneWidget);
        expect(
          api.calls.where((c) => c == 'accounts').length,
          greaterThan(accountCalls),
        );
        await tester.pump(HaroTokens.beat);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('gh-login')), findsNothing);
        expect(api.calls.where((c) => c.startsWith('login-cancel')), isEmpty);
        final element = tester.element(_avatar);
        final data = ProviderScope.containerOf(element)
            .read(githubAccountsProvider)
            .data!;
        expect(data.accounts.map((a) => a.login), contains('newbie'));
      },
    );

    testWidgets('a failed sign-in shows the error and stops polling', (
      tester,
    ) async {
      final api = FakeGithubApi()
        ..accounts = _accounts()
        ..pollReplies = const [
          GithubLoginStatus(
            state: GithubLoginState.failed,
            error: 'the code expired',
          ),
        ];
      await _pump(tester, fake: api);
      await openLogin(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('the code expired'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(api.calls.where((c) => c == 'login-poll'), hasLength(1));
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.startsWith('login-cancel')), isEmpty);
    });

    testWidgets('409 login_in_progress is a plain message', (tester) async {
      final api = FakeGithubApi()
        ..accounts = _accounts()
        ..startError = const HaroApiException(
          409,
          'conflict',
          body: {'reason': 'login_in_progress'},
        );
      await _pump(tester, fake: api);
      await openLogin(tester);
      expect(
        find.text(
          'A GitHub sign-in is already in progress. Finish or cancel it first.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('gh-login-code')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('a 409 that names the old sign-in offers cancel and retry', (
      tester,
    ) async {
      final api = FakeGithubApi()
        ..accounts = _accounts()
        ..startError = const HaroApiException(
          409,
          'conflict',
          body: {'reason': 'login_in_progress', 'id': 'old'},
        );
      await _pump(tester, fake: api);
      await openLogin(tester);
      final retry = find.byKey(const ValueKey('gh-login-retry'));
      expect(retry, findsOneWidget);
      expect(find.byKey(const ValueKey('gh-login-code')), findsNothing);
      api.startError = null;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(
        api.calls.where((c) => c == 'login-cancel:old' || c == 'login-start'),
        ['login-start', 'login-cancel:old', 'login-start'],
      );
      expect(find.byKey(const ValueKey('gh-login-code')), findsOneWidget);
      expect(retry, findsNothing);
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('a 409 without an id is the message only', (tester) async {
      final api = FakeGithubApi()
        ..accounts = _accounts()
        ..startError = const HaroApiException(
          409,
          'conflict',
          body: {'reason': 'login_in_progress'},
        );
      await _pump(tester, fake: api);
      await openLogin(tester);
      expect(find.textContaining('already in progress'), findsOneWidget);
      expect(find.byKey(const ValueKey('gh-login-retry')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('done reads the accounts again a second later', (tester) async {
      final api = FakeGithubApi()
        ..accounts = _accounts()
        ..pollReplies = const [
          GithubLoginStatus(state: GithubLoginState.done, login: 'newbie'),
        ];
      await _pump(tester, fake: api);
      await openLogin(tester);
      final fresh = GithubAccounts(
        defaultLogin: 'octo',
        accounts: [
          const GithubAccount(login: 'octo', avatarUrl: 'u', isDefault: true),
          const GithubAccount(login: 'newbie', avatarUrl: 'u'),
        ],
      );
      api
        ..accounts = fresh
        ..staleOnce = _accounts();
      final before = api.calls.where((c) => c == 'accounts').length;
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const ValueKey('gh-login'))),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.calls.where((c) => c == 'accounts').length, before + 1);
      final staleData = container.read(githubAccountsProvider).data!;
      expect(staleData.accounts.map((a) => a.login), ['octo', 'work']);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(api.calls.where((c) => c == 'accounts').length, before + 2);
      final data = container.read(githubAccountsProvider).data!;
      expect(data.accounts.map((a) => a.login), ['octo', 'newbie']);
      await tester.pumpAndSettle();
    });

    testWidgets('Cancel cancels the pending sign-in', (tester) async {
      final api = FakeGithubApi()..accounts = _accounts();
      await _pump(tester, fake: api);
      await openLogin(tester);
      await tester.tap(find.byKey(const ValueKey('gh-login-cancel')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('login-cancel:l1'));
      expect(find.byKey(const ValueKey('gh-login')), findsNothing);
    });

    testWidgets('Esc and a click outside cancel it too', (tester) async {
      final api = FakeGithubApi()..accounts = _accounts();
      await _pump(tester, fake: api);
      await openLogin(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c == 'login-cancel:l1'), hasLength(1));

      await openLogin(tester);
      await tester.tapAt(const Offset(10, 690));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c == 'login-cancel:l1'), hasLength(2));
    });
  });

  group('top bar', () {
    testWidgets('the avatar sits at the far right of the top bar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeGithubApi()..accounts = _accounts();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            haroApiProvider.overrideWithValue(api),
            githubAvatarImageProvider.overrideWithValue(_FailingImage.new),
          ],
          child: MaterialApp(
            theme: buildHaroTheme(),
            home: HaroShell(
              data: fakeShellData,
              crumb1: 'haro',
              draggable: false,
              macTrafficLights: false,
              account: const GithubAccountButton(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(GithubAvatar));
      expect(rect.top, lessThan(HaroTokens.topBarHeight));
      expect(1000 - rect.right, 16);
      expect(rect.width, HaroTokens.avatarSize);
    });
  });
}
