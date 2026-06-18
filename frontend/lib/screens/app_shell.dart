import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'admin_screen.dart';
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
  String _username = '';

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(
      widget.authService,
      onUnauthorized: _onUnauthorized,
    );
    _loadRole();
  }

  void _onUnauthorized() {
    // Handled by main.dart navigatorKey
  }

  Future<void> _loadRole() async {
    final isAdmin = await widget.authService.isAdmin();
    final username = await widget.authService.getUsername();
    if (mounted) {
      setState(() {
        _isAdmin = isAdmin;
        _username = username ?? '';
      });
    }
  }

  List<_NavItem> get _navItems => [
    const _NavItem(
      icon: Icons.folder_outlined,
      selectedIcon: Icons.folder,
      label: 'FILES',
    ),
    const _NavItem(
      icon: Icons.bar_chart_outlined,
      selectedIcon: Icons.bar_chart,
      label: 'STATUS',
    ),
    if (_isAdmin)
      const _NavItem(
        icon: Icons.people_outlined,
        selectedIcon: Icons.people,
        label: 'USERS',
      ),
    const _NavItem(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'CONFIG',
    ),
  ];

  List<Widget> get _screens => [
    GalleryScreen(authService: widget.authService, apiService: _apiService),
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
            Container(
              width: 260,
              color: const Color(0xFF1A1A1A),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          _VaultLogo(),
                          SizedBox(width: 12),
                          Text(
                            'Reliquary',
                            style: TextStyle(
                              color: Colors.white,
                              fontFamily: 'Inter',
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      for (var i = 0; i < items.length; i++) ...[
                        _DesktopNavItem(
                          item: items[i],
                          selected: i == _selectedIndex,
                          onTap: () => setState(() => _selectedIndex = i),
                        ),
                        const SizedBox(height: 8),
                      ],
                      const Spacer(),
                      _SidebarUserButton(username: _username),
                    ],
                  ),
                ),
              ),
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: IndexedStack(index: _selectedIndex, children: _screens),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _screens),
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

class _DesktopNavItem extends StatelessWidget {
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopNavItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFFE63946) : Colors.white70;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFFE63946).withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 20,
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFFE63946)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected ? item.selectedIcon : item.icon,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 12),
              Text(
                _displayLabel(item.label),
                style: TextStyle(
                  color: color,
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _displayLabel(String label) {
    switch (label) {
      case 'FILES':
        return 'Files';
      case 'STATUS':
        return 'Vault status';
      case 'USERS':
        return 'Users';
      case 'CONFIG':
        return 'Config';
      default:
        return label;
    }
  }
}

class _SidebarUserButton extends StatelessWidget {
  final String username;

  const _SidebarUserButton({required this.username});

  @override
  Widget build(BuildContext context) {
    final initial = username.isEmpty ? '?' : username[0].toUpperCase();
    return Tooltip(
      message: username.isEmpty ? 'Account' : username,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                username.isEmpty ? 'Account' : username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
