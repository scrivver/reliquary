import 'package:flutter/material.dart';

import '../services/api_service.dart';

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
      if (mounted) setState(() { _users = users; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
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
        SnackBar(content: Text('Failed to create user: $e')),
      );
    }
  }

  Future<void> _deleteUser(String username) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete User'),
        content: Text('Delete user "$username"? Their files will remain.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
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
        SnackBar(content: Text('Failed to delete user: $e')),
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
        const SnackBar(content: Text('Password changed')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to change password: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('User Management')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final username = user['username'] as String;
                final role = user['role'] as String;
                return ListTile(
                  leading: Icon(
                    role == 'admin'
                        ? Icons.admin_panel_settings
                        : Icons.person,
                  ),
                  title: Text(username),
                  subtitle: Text(role),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'password') _changePassword(username);
                      if (action == 'delete') _deleteUser(username);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'password',
                        child: Text('Change Password'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createUser,
        child: const Icon(Icons.person_add),
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
      title: const Text('Create User'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _role,
            decoration: const InputDecoration(
              labelText: 'Role',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'user', child: Text('User')),
              DropdownMenuItem(value: 'admin', child: Text('Admin')),
            ],
            onChanged: (v) => setState(() => _role = v ?? 'user'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
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
          child: const Text('Create'),
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
      title: Text('Change Password: ${widget.username}'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          labelText: 'New Password',
          border: OutlineInputBorder(),
        ),
        obscureText: true,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_controller.text.isEmpty) return;
            Navigator.pop(context, _controller.text);
          },
          child: const Text('Change'),
        ),
      ],
    );
  }
}
