import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'responsive_page.dart';

const _kAccentRed = Color(0xFFEC3713);

class AdminScreen extends StatefulWidget {
  final ApiService apiService;

  const AdminScreen({super.key, required this.apiService});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

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
            style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
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
          'DELETE_USER',
          style: TextStyle(
            fontFamily: 'Space Grotesk',
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        content: Text(
          'Delete user "$username"? Their files will remain.',
          style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'CANCEL',
              style: TextStyle(
                fontFamily: 'Space Grotesk',
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'DELETE',
              style: TextStyle(
                fontFamily: 'Space Grotesk',
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: _kAccentRed,
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
            style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
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
            style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to change password: $e',
            style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kAccentRed))
          : isDesktop
          ? _buildDesktopUsers()
          : _buildMobileUsers(),
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton(
              heroTag: 'add_user_fab',
              backgroundColor: _kAccentRed,
              onPressed: _createUser,
              child: const Icon(Icons.person_add, color: Colors.white),
            ),
    );
  }

  Widget _buildMobileUsers() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _users.length,
      itemBuilder: (context, index) => _UserCard(
        user: _users[index],
        onChangePassword: _changePassword,
        onDeleteUser: _deleteUser,
      ),
    );
  }

  Widget _buildDesktopUsers() {
    final adminCount = _users.where((u) => u['role'] == 'admin').length;
    final regularCount = _users.length - adminCount;

    return SingleChildScrollView(
      child: DesktopPageFrame(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'User Management',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 32,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Manage password-authenticated accounts and administrative access.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                height: 1.45,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.64),
              ),
            ),
            const SizedBox(height: 32),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
                onPressed: _createUser,
                icon: const Icon(Icons.person_add, color: Colors.white),
                label: const Text('Create user'),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: PageSectionCard(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _users.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: _EmptyUsersLabel(),
                          )
                        : Column(
                            children: [
                              const _UsersTableHeader(),
                              Divider(
                                height: 1,
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                              for (
                                var index = 0;
                                index < _users.length;
                                index++
                              )
                                _UserCard(
                                  user: _users[index],
                                  dense: true,
                                  showDivider: index != _users.length - 1,
                                  onChangePassword: _changePassword,
                                  onDeleteUser: _deleteUser,
                                ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 280,
                  child: PageSectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Overview',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _SummaryRow(
                          label: 'Total users',
                          value: '${_users.length}',
                        ),
                        _SummaryRow(label: 'Admins', value: '$adminCount'),
                        _SummaryRow(
                          label: 'Standard users',
                          value: '$regularCount',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool dense;
  final bool showDivider;
  final void Function(String username) onChangePassword;
  final void Function(String username) onDeleteUser;

  const _UserCard({
    required this.user,
    required this.onChangePassword,
    required this.onDeleteUser,
    this.dense = false,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    final username = user['username'] as String;
    final role = user['role'] as String;
    final tile = ListTile(
      contentPadding: EdgeInsets.symmetric(
        horizontal: dense ? 24 : 16,
        vertical: dense ? 6 : 0,
      ),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        child: Text(
          username.isEmpty ? '?' : username.substring(0, 1).toUpperCase(),
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      title: Text(
        username,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [_RoleBadge(role: role)]),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          if (action == 'password') onChangePassword(username);
          if (action == 'delete') onDeleteUser(username);
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'password',
            child: Text(
              'Change password',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
                color: _kAccentRed,
              ),
            ),
          ),
        ],
      ),
    );

    if (dense) {
      return Column(
        children: [
          tile,
          if (showDivider)
            Divider(
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
        ],
      );
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: tile,
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Geist',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
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
                borderSide: BorderSide(color: _kAccentRed),
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
                borderSide: BorderSide(color: _kAccentRed),
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
                borderSide: BorderSide(color: _kAccentRed),
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
          style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
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
            borderSide: BorderSide(color: _kAccentRed),
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
          style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
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

class _UsersTableHeader extends StatelessWidget {
  const _UsersTableHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Account',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.96,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Text(
            'Actions',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.96,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
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
        color: isAdmin
            ? _kAccentRed.withValues(alpha: 0.08)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isAdmin ? 'Admin' : 'User',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isAdmin
              ? _kAccentRed
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}
