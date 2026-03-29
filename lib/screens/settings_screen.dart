import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../models/user_model.dart';
import '../widgets/common_widgets.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  final String userRole;

  const SettingsScreen({super.key, this.userRole = 'Lawyer'});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<void> _showEditProfileDialog(
      BuildContext context, UserModel user) async {
    final nameController = TextEditingController(text: user.name);
    final phoneController = TextEditingController(text: user.phone ?? '');
    bool isLoading = false;

    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Edit Profile'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Full Name'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: phoneController,
                    decoration: const InputDecoration(
                        labelText: 'Phone Number (Optional)'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: isLoading
                    ? null
                    : () async {
                        if (nameController.text.trim().isEmpty) return;
                        setState(() => isLoading = true);
                        try {
                          await ref.read(authServiceProvider).updateProfile(
                                uid: user.uid,
                                name: nameController.text.trim(),
                                phone: phoneController.text.trim().isNotEmpty
                                    ? phoneController.text.trim()
                                    : null,
                              );
                          // Update provider cache synchronously from local Hive
                          final authService = ref.read(authServiceProvider);
                          final updatedUser = authService.getCachedUser();
                          if (updatedUser != null) {
                            ref
                                .read(currentUserProvider.notifier)
                                .setUser(updatedUser);
                          }
                          if (context.mounted) Navigator.pop(c);
                        } catch (e) {
                          setState(() => isLoading = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Error: $e'),
                                  backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                child: isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showChangePasswordDialog(BuildContext context) async {
    final currentPasswordCtrl = TextEditingController();
    final newPasswordCtrl = TextEditingController();
    final confirmPasswordCtrl = TextEditingController();
    bool isLoading = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Change Password'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: currentPasswordCtrl,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Current Password'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: newPasswordCtrl,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'New Password'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: confirmPasswordCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Confirm New Password'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary),
                onPressed: isLoading
                    ? null
                    : () async {
                        if (currentPasswordCtrl.text.isEmpty ||
                            newPasswordCtrl.text.isEmpty ||
                            confirmPasswordCtrl.text.isEmpty) {
                          return;
                        }
                        if (newPasswordCtrl.text != confirmPasswordCtrl.text) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('New passwords do not match')),
                          );
                          return;
                        }

                        setState(() => isLoading = true);
                        try {
                          final user = FirebaseAuth.instance.currentUser;
                          if (user == null || user.email == null)
                            throw Exception('User not found');

                          // 1. Re-authenticate
                          final cred = EmailAuthProvider.credential(
                              email: user.email!,
                              password: currentPasswordCtrl.text);
                          await user.reauthenticateWithCredential(cred);

                          // 2. Change password
                          await user.updatePassword(newPasswordCtrl.text);

                          if (context.mounted) {
                            Navigator.pop(c);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content:
                                      Text('Password updated successfully'),
                                  backgroundColor: AppColors.success),
                            );
                          }
                        } catch (e) {
                          setState(() => isLoading = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Error: $e'),
                                  backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                child: isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.white))
                    : const Text('Update',
                        style: TextStyle(color: AppColors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showDeleteAccountDialog(BuildContext context) async {
    final passwordCtrl = TextEditingController();
    bool isLoading = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Delete Account',
                style: TextStyle(color: AppColors.error)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'This action is permanent and cannot be undone. All your data will be permanently wiped.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm Password to Delete',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style:
                    ElevatedButton.styleFrom(backgroundColor: AppColors.error),
                onPressed: isLoading
                    ? null
                    : () async {
                        if (passwordCtrl.text.isEmpty) return;

                        setState(() => isLoading = true);
                        try {
                          final authService = ref.read(authServiceProvider);
                          final user = FirebaseAuth.instance.currentUser;
                          if (user == null || user.email == null)
                            throw Exception('User not found');

                          // 1. Re-authenticate
                          final cred = EmailAuthProvider.credential(
                              email: user.email!, password: passwordCtrl.text);
                          await user.reauthenticateWithCredential(cred);

                          // 2. Purge cloud data for this user
                          final uidToDelete = user.uid;

                          // Delete all user-owned cloud data before deleting auth identity.
                          await authService.deleteAllUserData(uidToDelete);

                          // Delete Firebase Auth account only after cloud purge succeeds.
                          await user.delete();

                          // 3. Capture container before unmounting UI
                          final container = ProviderScope.containerOf(context);

                          // 4. Clear context immediately so UI doesn't hang
                          if (context.mounted) {
                            Navigator.pushNamedAndRemoveUntil(
                                context, '/login', (route) => false);
                          }

                          // 5. Wipe Hive and unmount providers silently in background
                          Future.microtask(() async {
                            try {
                              await authService.logout();
                            } catch (e) {
                              debugPrint('Post-delete local cleanup failed: $e');
                            }
                            container.invalidate(currentUserProvider);
                            container.invalidate(casesProvider);
                            container.invalidate(tasksProvider);
                            container.invalidate(remindersProvider);
                            container.invalidate(chatGroupsProvider);
                            container.invalidate(noticesProvider);
                          });
                        } catch (e) {
                          setState(() => isLoading = false);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Error: $e'),
                                  backgroundColor: AppColors.error),
                            );
                          }
                        }
                      },
                child: isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.white))
                    : const Text('Permanently Delete',
                        style: TextStyle(color: AppColors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    if (user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text(
                  'Settings',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  // Profile Card
                  AppCard(
                    child: Row(
                      children: [
                        AvatarCircle(
                          initials: user.initials,
                          size: 60,
                          backgroundColor: AppColors.primary,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.text,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.accent.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  user.role.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFFB8942E),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _showEditProfileDialog(context, user),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.secondary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(Icons.edit,
                                color: AppColors.secondary, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Account Section
                  _buildSectionHeader('Account'),
                  const SizedBox(height: 12),
                  _buildSettingsTile(
                    icon: Icons.person_outline,
                    iconColor: AppColors.secondary,
                    title: 'Edit Profile',
                    subtitle: 'Update your personal information',
                    onTap: () => _showEditProfileDialog(context, user),
                  ),
                  const SizedBox(height: 12),
                  _buildSettingsTile(
                    icon: Icons.lock_outline,
                    iconColor: AppColors.accent,
                    title: 'Change Password',
                    subtitle: 'Update your security credentials',
                    onTap: () => _showChangePasswordDialog(context),
                  ),
                  const SizedBox(height: 24),

                  // Support Section
                  _buildSectionHeader('Support'),
                  const SizedBox(height: 12),
                  _buildSettingsTile(
                    icon: Icons.delete_forever,
                    iconColor: AppColors.error,
                    title: 'Delete Account',
                    subtitle: 'Permanently erase all your data',
                    onTap: () => _showDeleteAccountDialog(context),
                  ),
                  const SizedBox(height: 24),

                  // Logout Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _showLogoutDialog(context),
                      icon: const Icon(Icons.logout, size: 20),
                      label: const Text(
                        'Logout',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: AppColors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.grey[500],
          letterSpacing: 1,
        ),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AppCard(
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
            trailing ?? Icon(Icons.chevron_right, color: Colors.grey[300]),
          ],
        ),
      ),
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.logout, color: AppColors.error),
            SizedBox(width: 12),
            Text('Logout', style: TextStyle(color: AppColors.text)),
          ],
        ),
        content: const Text(
          'Are you sure you want to logout from Synapse?',
          style: TextStyle(color: AppColors.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              // 1. Capture references before disposing context
              final authService = ref.read(authServiceProvider);
              final container = ProviderScope.containerOf(context);

              Navigator.pop(context); // Close dialog

              // 2. Instantly navigate to Login so UI doesn't hang
              Navigator.pushNamedAndRemoveUntil(
                context,
                '/login',
                (route) => false,
              );

              // 3. Perform teardown detached from UI
              Future.microtask(() async {
                await authService.logout();
                container.invalidate(currentUserProvider);
                container.invalidate(casesProvider);
                container.invalidate(tasksProvider);
                container.invalidate(remindersProvider);
                container.invalidate(chatGroupsProvider);
                container.invalidate(noticesProvider);
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.white,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}

Widget _buildBackButton(BuildContext context) {
  return Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: AppColors.white.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
    ),
    child: IconButton(
      icon: const Icon(Icons.arrow_back, color: AppColors.white, size: 20),
      onPressed: () => Navigator.pop(context),
    ),
  );
}
