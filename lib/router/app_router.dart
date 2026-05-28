import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app_keys.dart';
import '../features/bookshelf/bookshelf_page.dart';
import '../features/discover/discover_page.dart';
import '../features/reader/reader_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sources/sources_page.dart';
import '../l10n/app_localizations.dart';
import '../src/rust/api/storage.dart' as rs;
import '../theme/motion.dart';
import '../widgets/responsive.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'velora-root');
final _shellNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'velora-shell',
);

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/bookshelf',
    routes: [
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => _Shell(state: state, child: child),
        routes: [
          GoRoute(path: '/bookshelf', builder: (c, s) => const BookshelfPage()),
          GoRoute(path: '/discover', builder: (c, s) => const DiscoverPage()),
          GoRoute(path: '/sources', builder: (c, s) => const SourcesPage()),
          GoRoute(path: '/settings', builder: (c, s) => const SettingsPage()),
        ],
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/reader',
        pageBuilder: (c, s) => CustomTransitionPage<void>(
          key: s.pageKey,
          transitionDuration: M3Motion.medium4,
          reverseTransitionDuration: M3Motion.medium2,
          child: ReaderPage(
            bookId: s.uri.queryParameters['bookId'] ?? '',
            initialBook: s.extra is rs.BookshelfEntry
                ? s.extra as rs.BookshelfEntry
                : null,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final fade = CurvedAnimation(
              parent: animation,
              curve: M3Motion.standardDecelerate,
            );
            final scale = Tween<double>(begin: 0.98, end: 1).animate(fade);
            final slide = Tween<Offset>(
              begin: const Offset(0.02, 0.02),
              end: Offset.zero,
            ).animate(fade);
            return FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: slide,
                child: ScaleTransition(scale: scale, child: child),
              ),
            );
          },
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/reader/:bookId',
        pageBuilder: (c, s) => CustomTransitionPage<void>(
          key: s.pageKey,
          transitionDuration: M3Motion.medium4,
          reverseTransitionDuration: M3Motion.medium2,
          child: ReaderPage(
            bookId: s.pathParameters['bookId'] ?? '',
            initialBook: s.extra is rs.BookshelfEntry
                ? s.extra as rs.BookshelfEntry
                : null,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final fade = CurvedAnimation(
              parent: animation,
              curve: M3Motion.standardDecelerate,
            );
            final scale = Tween<double>(begin: 0.98, end: 1).animate(fade);
            final slide = Tween<Offset>(
              begin: const Offset(0.02, 0.02),
              end: Offset.zero,
            ).animate(fade);
            return FadeTransition(
              opacity: fade,
              child: SlideTransition(
                position: slide,
                child: ScaleTransition(scale: scale, child: child),
              ),
            );
          },
        ),
      ),
    ],
  );
});

class _Shell extends StatelessWidget {
  final GoRouterState state;
  final Widget child;
  const _Shell({required this.state, required this.child});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final destinations = <_Dest>[
      _Dest(
        l10n.bookshelf,
        Icons.menu_book_outlined,
        Icons.menu_book,
        '/bookshelf',
        AppKeys.navBookshelf,
      ),
      _Dest(
        l10n.discover,
        Icons.explore_outlined,
        Icons.explore,
        '/discover',
        AppKeys.navDiscover,
      ),
      _Dest(
        l10n.bookSources,
        Icons.cloud_outlined,
        Icons.cloud,
        '/sources',
        AppKeys.navSources,
      ),
      _Dest(
        l10n.settings,
        Icons.settings_outlined,
        Icons.settings,
        '/settings',
        AppKeys.navSettings,
      ),
    ];
    final loc = state.uri.toString();
    final selected = destinations.indexWhere((d) => loc.startsWith(d.path));
    final idx = selected < 0 ? 0 : selected;

    return AdaptiveNavigationScaffold(
      currentIndex: idx,
      onDestinationSelected: (i) => context.go(destinations[i].path),
      destinations: destinations
          .map(
            (d) => NavigationDestination(
              icon: KeyedSubtree(key: d.key, child: Icon(d.icon)),
              selectedIcon: KeyedSubtree(
                key: d.key,
                child: Icon(d.selectedIcon),
              ),
              label: d.label,
            ),
          )
          .toList(),
      body: child,
    );
  }
}

class _Dest {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String path;
  final Key key;
  const _Dest(this.label, this.icon, this.selectedIcon, this.path, this.key);
}
