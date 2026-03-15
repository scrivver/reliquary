import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/api_service.dart';

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
        SnackBar(content: Text('Failed to create user: $e', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    }
  }

  Future<void> _deleteUser(String username) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('DELETE_USER', style: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        )),
        content: Text(
          'Delete user "$username"? Their files will remain.',
          style: GoogleFonts.spaceMono(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('CANCEL', style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            )),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('DELETE', style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: _kAccentRed,
            )),
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
        SnackBar(content: Text('Failed to delete user: $e', style: GoogleFonts.spaceMono(fontSize: 13))),
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
        SnackBar(content: Text('Password changed', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to change password: $e', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'USER_MANAGEMENT',
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kAccentRed))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _users.length,
              itemBuilder: (context, index) {
                final user = _users[index];
                final username = user['username'] as String;
                final role = user['role'] as String;
                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: ListTile(
                    leading: Icon(
                      role == 'admin'
                          ? Icons.admin_panel_settings
                          : Icons.person,
                      color: role == 'admin' ? _kAccentRed : null,
                    ),
                    title: Text(
                      username,
                      style: GoogleFonts.spaceMono(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      'ROLE: ${role.toUpperCase()}',
                      style: GoogleFonts.spaceMono(
                        fontSize: 11,
                        letterSpacing: 0.8,
                        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        if (action == 'password') _changePassword(username);
                        if (action == 'delete') _deleteUser(username);
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'password',
                          child: Text('CHANGE_PASSWORD', style: GoogleFonts.spaceGrotesk(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
                          )),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('DELETE', style: GoogleFonts.spaceGrotesk(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.8,
                            color: _kAccentRed,
                          )),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _kAccentRed,
        onPressed: _createUser,
        child: const Icon(Icons.person_add, color: Colors.white),
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
      title: Text('CREATE_USER', style: GoogleFonts.spaceGrotesk(
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      )),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _usernameController,
            style: GoogleFonts.spaceMono(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'USERNAME',
              labelStyle: GoogleFonts.spaceMono(fontSize: 12, letterSpacing: 1.0),
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _kAccentRed),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            style: GoogleFonts.spaceMono(fontSize: 14),
            decoration: InputDecoration(
              labelText: 'PASSWORD',
              labelStyle: GoogleFonts.spaceMono(fontSize: 12, letterSpacing: 1.0),
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
              labelText: 'ROLE',
              labelStyle: GoogleFonts.spaceMono(fontSize: 12, letterSpacing: 1.0),
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _kAccentRed),
              ),
            ),
            items: [
              DropdownMenuItem(
                value: 'user',
                child: Text('USER', style: GoogleFonts.spaceMono(fontSize: 14)),
              ),
              DropdownMenuItem(
                value: 'admin',
                child: Text('ADMIN', style: GoogleFonts.spaceMono(fontSize: 14)),
              ),
            ],
            onChanged: (v) => setState(() => _role = v ?? 'user'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('CANCEL', style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          )),
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
          child: Text('CREATE', style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          )),
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
        'CHANGE_PASSWORD: ${widget.username}',
        style: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
      content: TextField(
        controller: _controller,
        style: GoogleFonts.spaceMono(fontSize: 14),
        decoration: InputDecoration(
          labelText: 'NEW_PASSWORD',
          labelStyle: GoogleFonts.spaceMono(fontSize: 12, letterSpacing: 1.0),
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
          child: Text('CANCEL', style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          )),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
          onPressed: () {
            if (_controller.text.isEmpty) return;
            Navigator.pop(context, _controller.text);
          },
          child: Text('CHANGE', style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          )),
        ),
      ],
    );
  }
}
