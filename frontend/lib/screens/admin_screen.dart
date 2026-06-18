import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'responsive_page.dart';

const _kPrimary = Color(0xFFB7102A);
const _kSurface = Color(0xFFF8F9FA);
const _kSurfaceLow = Color(0xFFF3F4F5);
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
      barrierColor: _kText.withValues(alpha: 0.4),
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
      barrierColor: _kText.withValues(alpha: 0.4),
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
        if (!isAdmin)
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
            if (action == 'password' && !isAdmin) onChangePassword(username);
            if (action == 'delete') onDeleteUser(username);
          },
          itemBuilder: (_) => [
            if (!isAdmin)
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
  bool _showPassword = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.transparent,
      child: _ModalCard(
        maxWidth: 520,
        title: 'Add New User',
        onClose: () => Navigator.pop(context),
        footer: _ModalActions(
          primaryLabel: 'Add User',
          onCancel: () => Navigator.pop(context),
          onPrimary: () {
            final username = _usernameController.text.trim();
            final password = _passwordController.text;
            if (username.isEmpty || password.isEmpty) return;
            Navigator.pop(
              context,
              _CreateUserResult(
                username: username,
                password: password,
                role: _role,
              ),
            );
          },
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModalFieldLabel('Username'),
            TextField(
              controller: _usernameController,
              autofocus: true,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 16),
              decoration: _modalInputDecoration(
                hintText: 'e.g. alexander.pierce',
              ),
            ),
            const SizedBox(height: 24),
            _ModalFieldLabel('Password'),
            TextField(
              controller: _passwordController,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 16),
              decoration: _modalInputDecoration(
                hintText: 'Enter password',
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: _kSecondary,
                  ),
                ),
              ),
              obscureText: !_showPassword,
            ),
            const SizedBox(height: 24),
            _ModalFieldLabel('Access Role'),
            DropdownButtonFormField<String>(
              initialValue: _role,
              decoration: _modalInputDecoration(),
              dropdownColor: _kCard,
              items: const [
                DropdownMenuItem(value: 'user', child: Text('Standard User')),
                DropdownMenuItem(value: 'admin', child: Text('Admin')),
              ],
              onChanged: (v) => setState(() => _role = v ?? 'user'),
            ),
          ],
        ),
      ),
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
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _showPassword = false;
  bool _showConfirm = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.transparent,
      child: _ModalCard(
        maxWidth: 440,
        title: 'Change Password',
        subtitle: 'Update password for ${widget.username}',
        onClose: () => Navigator.pop(context),
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _kPrimary,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _submit,
              child: const Text(
                'Update Password',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: _kText,
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: _kBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModalFieldLabel('New Password'),
            TextField(
              controller: _passwordController,
              autofocus: true,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 16),
              decoration: _modalInputDecoration(
                hintText: 'Enter new password',
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: _kSecondary,
                  ),
                ),
              ),
              obscureText: !_showPassword,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 24),
            _ModalFieldLabel('Confirm New Password'),
            TextField(
              controller: _confirmController,
              style: const TextStyle(fontFamily: 'Inter', fontSize: 16),
              decoration: _modalInputDecoration(
                hintText: 'Confirm new password',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _showConfirm = !_showConfirm),
                  icon: Icon(
                    _showConfirm
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: _kSecondary,
                  ),
                ),
              ),
              obscureText: !_showConfirm,
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error ?? 'Use a strong temporary password for this account.',
                style: TextStyle(
                  fontFamily: 'Geist',
                  fontSize: 12,
                  height: 16 / 12,
                  color: _error == null ? _kSecondary : _kPrimary,
                ),
              ),
            ),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: _passwordStrength,
                minHeight: 4,
                backgroundColor: _kSurfaceLow,
                color: _kPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  double get _passwordStrength {
    final length = _passwordController.text.length;
    if (length == 0) return 0;
    if (length < 6) return 0.33;
    if (length < 10) return 0.66;
    return 1;
  }

  void _submit() {
    final password = _passwordController.text;
    final confirm = _confirmController.text;
    if (password.isEmpty || confirm.isEmpty) {
      setState(() => _error = 'Enter and confirm the new password.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    Navigator.pop(context, password);
  }
}

class _ModalCard extends StatelessWidget {
  final double maxWidth;
  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  final Widget child;
  final Widget footer;

  const _ModalCard({
    required this.maxWidth,
    required this.title,
    this.subtitle,
    required this.onClose,
    required this.child,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: _kCard,
        elevation: 16,
        shadowColor: Colors.black.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 24, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 24,
                            height: 32 / 24,
                            fontWeight: FontWeight.w700,
                            color: _kText,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            subtitle!,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 16,
                              height: 24 / 16,
                              color: _kSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, color: _kSecondary),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _kBorder),
            Padding(padding: const EdgeInsets.all(32), child: child),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: _kSurfaceLow,
                border: Border(top: BorderSide(color: _kBorder)),
              ),
              child: footer,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModalActions extends StatelessWidget {
  final String primaryLabel;
  final VoidCallback onCancel;
  final VoidCallback onPrimary;

  const _ModalActions({
    required this.primaryLabel,
    required this.onCancel,
    required this.onPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: _kText,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            side: const BorderSide(color: _kBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onCancel,
          child: const Text(
            'Cancel',
            style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _kPrimary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onPrimary,
          child: Text(
            primaryLabel,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _ModalFieldLabel extends StatelessWidget {
  final String label;

  const _ModalFieldLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            height: 16 / 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.96,
            color: _kSecondary,
          ),
        ),
      ),
    );
  }
}

InputDecoration _modalInputDecoration({String? hintText, Widget? suffixIcon}) {
  return InputDecoration(
    hintText: hintText,
    hintStyle: const TextStyle(color: _kSecondary),
    filled: true,
    fillColor: _kCard,
    suffixIcon: suffixIcon,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _kBorder),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _kPrimary),
    ),
  );
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
        role.toUpperCase(),
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          height: 16 / 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.88,
          color: isAdmin ? Colors.white : _kSecondary,
        ),
      ),
    );
  }
}
