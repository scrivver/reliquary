import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'admin_screen.dart';
import 'archive_screen.dart';
import 'gallery_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

class AppShell extends StatefulWidget {
  final AuthService authService;

  const AppShell({super.key, required this.authService});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ApiService _apiService;
  int _selectedIndex = 0;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.authService, onUnauthorized: _onUnauthorized);
    _loadRole();
  }

  void _onUnauthorized() {
    // Handled by main.dart navigatorKey
  }

  Future<void> _loadRole() async {
    final isAdmin = await widget.authService.isAdmin();
    if (mounted) setState(() => _isAdmin = isAdmin);
  }

  List<_NavItem> get _navItems => [
        const _NavItem(icon: Icons.folder_outlined, selectedIcon: Icons.folder, label: 'FILES'),
        const _NavItem(icon: Icons.archive_outlined, selectedIcon: Icons.archive, label: 'ARCHIVE'),
        const _NavItem(icon: Icons.bar_chart_outlined, selectedIcon: Icons.bar_chart, label: 'STATUS'),
        if (_isAdmin)
          const _NavItem(icon: Icons.people_outlined, selectedIcon: Icons.people, label: 'USERS'),
        const _NavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: 'CONFIG'),
      ];

  List<Widget> get _screens => [
        GalleryScreen(authService: widget.authService, apiService: _apiService),
        ArchiveScreen(apiService: _apiService),
        StatsScreen(apiService: _apiService),
        if (_isAdmin) AdminScreen(apiService: _apiService),
        SettingsScreen(apiService: _apiService, authService: widget.authService),
      ];

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 800;
    final items = _navItems;

    // Clamp index if admin status changed
    if (_selectedIndex >= items.length) {
      _selectedIndex = 0;
    }

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (i) => setState(() => _selectedIndex = i),
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: _VaultLogo(),
              ),
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.selectedIcon),
                    label: Text(item.label),
                  ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: _screens,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        height: 64,
        destinations: [
          for (final item in items)
            NavigationDestination(
              icon: Icon(item.icon),
              selectedIcon: Icon(item.selectedIcon),
              label: item.label,
            ),
        ],
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

class _VaultLogo extends StatelessWidget {
  const _VaultLogo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0xFFEC3713),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Center(
        child: Text(
          'R',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
      ),
    );
  }
}
