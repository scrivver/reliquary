import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'responsive_page.dart';

const _kPrimary = Color(0xFFB7102A);
const _kSurface = Color(0xFFF8F9FA);
const _kCard = Color(0xFFFFFFFF);
const _kBorder = Color(0xFFE5E5E5);
const _kText = Color(0xFF191C1D);
const _kSecondary = Color(0xFF5F5E5E);
const _kRoleSurface = Color(0xFFE2DFDE);

class AdminScreen extends StatefulWidget {
  final ApiService apiService;

  const AdminScreen({super.key, required this.apiService});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _loading = true);
    try {
      final users = await widget.apiService.listUsers();
      if (mounted) {
        setState(() {
          _users = users;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _createUser() async {
    final result = await showDialog<_CreateUserResult>(
      context: context,
      builder: (ctx) => const _CreateUserDialog(),
    );
    if (result == null) return;

    try {
      await widget.apiService.createUser(
        result.username,
        result.password,
        result.role,
      );
      _loadUsers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to create user: $e',
            style: TextStyle(fontFamily: 'Inter', fontSize: 13),
          ),
        ),
      );
    }
  }

  Future<void> _deleteUser(String username) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Delete user',
          style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Delete user "$username"? Their files will remain.',
          style: TextStyle(fontFamily: 'Inter', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'CANCEL',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'DELETE',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
                color: _kPrimary,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await widget.apiService.deleteUser(username);
      _loadUsers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to delete user: $e',
            style: TextStyle(fontFamily: 'Inter', fontSize: 13),
          ),
        ),
      );
    }
  }

  Future<void> _changePassword(String username) async {
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => _ChangePasswordDialog(username: username),
    );
    if (password == null) return;

    try {
      await widget.apiService.changePassword(username, password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Password changed',
            style: TextStyle(fontFamily: 'Inter', fontSize: 13),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to change password: $e',
            style: TextStyle(fontFamily: 'Inter', fontSize: 13),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = isDesktopWidth(context);
    return Scaffold(
      appBar: isDesktop
          ? null
          : AppBar(
              title: Text(
                'User Management',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
      backgroundColor: _kSurface,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kPrimary))
          : isDesktop
          ? _buildDesktopUsers()
          : _buildMobileUsers(),
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton(
              heroTag: 'add_user_fab',
              backgroundColor: _kPrimary,
              onPressed: _createUser,
              child: const Icon(Icons.person_add, color: Colors.white),
            ),
    );
  }

  Widget _buildMobileUsers() {
    final users = _filteredUsers;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: users.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _DirectoryToolbar(
              query: _query,
              onQueryChanged: (value) => setState(() => _query = value),
              compact: true,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _UserCard(
            user: users[index - 1],
            onChangePassword: _changePassword,
            onDeleteUser: _deleteUser,
          ),
        );
      },
    );
  }

  List<Map<String, dynamic>> get _filteredUsers {
    final normalizedQuery = _query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return _users;
    return _users.where((user) {
      final username = (user['username'] as String?) ?? '';
      final role = (user['role'] as String?) ?? '';
      final createdAt = (user['created_at'] as String?) ?? '';
      return username.toLowerCase().contains(normalizedQuery) ||
          role.toLowerCase().contains(normalizedQuery) ||
          createdAt.toLowerCase().contains(normalizedQuery);
    }).toList();
  }

  Widget _buildDesktopUsers() {
    final users = _filteredUsers;

    return SingleChildScrollView(
      child: DesktopPageFrame(
        maxWidth: 1440,
        padding: const EdgeInsets.fromLTRB(40, 40, 40, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: DesktopPageHeader(
                    title: 'Member Directory',
                    subtitle:
                        'Manage access permissions and administrative roles for the Reliquary vault.',
                  ),
                ),
                const SizedBox(width: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _kPrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 18,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _createUser,
                  icon: const Icon(Icons.person_add, size: 20),
                  label: const Text('ADD USER'),
                ),
              ],
            ),
            const SizedBox(height: 32),
            _DirectoryToolbar(
              query: _query,
              onQueryChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 24),
            if (users.isEmpty)
              const _DirectoryCard(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: _EmptyUsersLabel(),
                ),
              )
            else
              for (final user in users)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _UserCard(
                    user: user,
                    onChangePassword: _changePassword,
                    onDeleteUser: _deleteUser,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _DirectoryToolbar extends StatefulWidget {
  final String query;
  final ValueChanged<String> onQueryChanged;
  final bool compact;

  const _DirectoryToolbar({
    required this.query,
    required this.onQueryChanged,
    this.compact = false,
  });

  @override
  State<_DirectoryToolbar> createState() => _DirectoryToolbarState();
}

class _DirectoryToolbarState extends State<_DirectoryToolbar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.query);
  }

  @override
  void didUpdateWidget(covariant _DirectoryToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: TextField(
        controller: _controller,
        onChanged: widget.onQueryChanged,
        style: const TextStyle(fontFamily: 'Inter', fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search by name or role...',
          prefixIcon: const Icon(Icons.search, color: _kSecondary, size: 20),
          filled: true,
          fillColor: _kCard,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 13,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _kPrimary),
          ),
        ),
      ),
    );

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: const [
        _ToolbarButton(icon: Icons.filter_list, label: 'Filter'),
        _ToolbarButton(icon: Icons.download_outlined, label: 'Export CSV'),
      ],
    );

    if (widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [search, const SizedBox(height: 12), actions],
      );
    }

    return Row(
      children: [
        Expanded(child: search),
        const SizedBox(width: 16),
        actions,
      ],
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String label;

  const _ToolbarButton({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {},
      style: OutlinedButton.styleFrom(
        foregroundColor: _kSecondary,
        side: const BorderSide(color: _kBorder),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontFamily: 'Inter', fontSize: 14),
      ),
    );
  }
}

class _DirectoryCard extends StatelessWidget {
  final Widget child;

  const _DirectoryCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class _UserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final void Function(String username) onChangePassword;
  final void Function(String username) onDeleteUser;

  const _UserCard({
    required this.user,
    required this.onChangePassword,
    required this.onDeleteUser,
  });

  @override
  Widget build(BuildContext context) {
    final username = user['username'] as String;
    final role = user['role'] as String;
    final createdAt = _formatCreatedAt(user['created_at'] as String?);
    final isAdmin = role == 'admin';

    final avatar = Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFEDEEEF),
        border: Border.all(color: isAdmin ? _kPrimary : _kBorder, width: 2),
        boxShadow: isAdmin
            ? [
                BoxShadow(
                  color: _kPrimary.withValues(alpha: 0.16),
                  spreadRadius: 4,
                ),
              ]
            : null,
      ),
      child: Center(
        child: Text(
          username.isEmpty ? '?' : username.substring(0, 1).toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: _kText,
          ),
        ),
      ),
    );

    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              username,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 20,
                height: 28 / 20,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: _kText,
              ),
            ),
            _RoleBadge(role: role),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          createdAt == null ? 'Local password account' : 'Created $createdAt',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            height: 20 / 14,
            letterSpacing: 0.14,
            color: _kSecondary,
          ),
        ),
      ],
    );

    final activity = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text(
          'ACCOUNT TYPE',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            height: 16 / 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.96,
            color: _kSecondary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          isAdmin ? 'Administrator' : 'Standard user',
          textAlign: TextAlign.end,
          style: const TextStyle(
            fontFamily: 'Geist',
            fontSize: 12,
            height: 16 / 12,
            color: _kText,
          ),
        ),
      ],
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Change password',
          onPressed: () => onChangePassword(username),
          icon: const Icon(Icons.edit_outlined, color: _kSecondary),
          style: IconButton.styleFrom(
            hoverColor: const Color(0xFFFFDAD8),
            focusColor: const Color(0xFFFFDAD8),
          ),
        ),
        PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'password') onChangePassword(username);
            if (action == 'delete') onDeleteUser(username);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'password',
              child: Text(
                'Change password',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Text(
                'Delete',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  color: _kPrimary,
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return _DirectoryCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    avatar,
                    const SizedBox(width: 16),
                    Expanded(child: identity),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [activity, actions],
                ),
              ],
            );
          }

          return Row(
            children: [
              avatar,
              const SizedBox(width: 24),
              Expanded(child: identity),
              const SizedBox(width: 24),
              activity,
              const SizedBox(width: 24),
              actions,
            ],
          );
        },
      ),
    );
  }

  String? _formatCreatedAt(String? value) {
    if (value == null || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    final local = parsed.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

class _EmptyUsersLabel extends StatelessWidget {
  const _EmptyUsersLabel();

  @override
  Widget build(BuildContext context) {
    return Text(
      'No users found',
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
      ),
    );
  }
}

class _CreateUserResult {
  final String username;
  final String password;
  final String role;
  _CreateUserResult({
    required this.username,
    required this.password,
    required this.role,
  });
}

class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog();

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String _role = 'user';

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Create user',
        style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _usernameController,
            style: TextStyle(fontFamily: 'Geist', fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Username',
              labelStyle: TextStyle(fontFamily: 'Inter', fontSize: 12),
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _kPrimary),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            style: TextStyle(fontFamily: 'Geist', fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Password',
              labelStyle: TextStyle(fontFamily: 'Inter', fontSize: 12),
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _kPrimary),
              ),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: InputDecoration(
              labelText: 'Role',
              labelStyle: TextStyle(fontFamily: 'Inter', fontSize: 12),
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _kPrimary),
              ),
            ),
            items: [
              DropdownMenuItem(
                value: 'user',
                child: Text(
                  'USER',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 14),
                ),
              ),
              DropdownMenuItem(
                value: 'admin',
                child: Text(
                  'ADMIN',
                  style: TextStyle(fontFamily: 'Inter', fontSize: 14),
                ),
              ),
            ],
            onChanged: (v) => setState(() => _role = v ?? 'user'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kPrimary),
          onPressed: () {
            if (_usernameController.text.isEmpty ||
                _passwordController.text.isEmpty) {
              return;
            }
            Navigator.pop(
              context,
              _CreateUserResult(
                username: _usernameController.text,
                password: _passwordController.text,
                role: _role,
              ),
            );
          },
          child: Text(
            'Create',
            style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  final String username;
  const _ChangePasswordDialog({required this.username});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Change password: ${widget.username}',
        style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
      ),
      content: TextField(
        controller: _controller,
        style: TextStyle(fontFamily: 'Geist', fontSize: 14),
        decoration: InputDecoration(
          labelText: 'New password',
          labelStyle: TextStyle(fontFamily: 'Inter', fontSize: 12),
          border: const OutlineInputBorder(),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: _kPrimary),
          ),
        ),
        obscureText: true,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kPrimary),
          onPressed: () {
            if (_controller.text.isEmpty) return;
            Navigator.pop(context, _controller.text);
          },
          child: Text(
            'Change',
            style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String role;

  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == 'admin';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isAdmin ? _kPrimary : _kRoleSurface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isAdmin ? 'Admin' : 'User',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isAdmin ? Colors.white : const Color(0xFF636262),
        ),
      ),
    );
  }
}
