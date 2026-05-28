import 'package:flutter/material.dart';

class Breakpoints {
  Breakpoints._();
  static const double compact = 600;
  static const double medium = 840;
  static const double expanded = 1240;
  static const double large = 1600;
}

enum WindowSizeClass { compact, medium, expanded, large, extraLarge }

WindowSizeClass windowSizeOf(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < Breakpoints.compact) return WindowSizeClass.compact;
  if (w < Breakpoints.medium) return WindowSizeClass.medium;
  if (w < Breakpoints.expanded) return WindowSizeClass.expanded;
  if (w < Breakpoints.large) return WindowSizeClass.large;
  return WindowSizeClass.extraLarge;
}

class AdaptiveNavigationScaffold extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;

  const AdaptiveNavigationScaffold({
    super.key,
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.appBar,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    final size = windowSizeOf(context);
    final useRail = size != WindowSizeClass.compact;
    if (!useRail) {
      return Scaffold(
        appBar: appBar,
        body: body,
        floatingActionButton: floatingActionButton,
        bottomNavigationBar: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: onDestinationSelected,
          destinations: destinations,
        ),
      );
    }
    final extended =
        size == WindowSizeClass.expanded ||
        size == WindowSizeClass.large ||
        size == WindowSizeClass.extraLarge;
    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          NavigationRail(
            extended: extended,
            minExtendedWidth: 220,
            selectedIndex: currentIndex,
            onDestinationSelected: onDestinationSelected,
            labelType: extended
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            destinations: destinations
                .map(
                  (d) => NavigationRailDestination(
                    icon: d.icon,
                    selectedIcon: d.selectedIcon,
                    label: Text(d.label),
                  ),
                )
                .toList(),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ],
      ),
      floatingActionButton: floatingActionButton,
    );
  }
}
