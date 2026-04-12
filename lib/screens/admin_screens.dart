import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../providers/providers.dart';
import '../services/admin_service.dart';

class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final AdminService _adminService = AdminService();
  late Future<List<Map<String, dynamic>>> _pendingRequestsFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _pendingRequestsFuture = _adminService.listPendingRequests();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _handleAction({
    required String uid,
    required String action,
  }) async {
    try {
      if (action == 'approve') {
        await _adminService.approveUser(uid);
      } else if (action == 'reject') {
        await _adminService.rejectUser(uid);
      } else if (action == 'delete') {
        await _adminService.deleteUser(uid);
      }

      if (!mounted) return;
      setState(() {
        _pendingRequestsFuture = _adminService.listPendingRequests();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Action "$action" completed.'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to $action user: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 12),
            color: AppColors.primary,
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: AppColors.white, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Admin Panel',
                        style: TextStyle(
                          color: AppColors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.admin_panel_settings,
                          color: AppColors.white, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Logged in as ${user?.email ?? 'admin'}',
                    style: TextStyle(color: Colors.grey[300], fontSize: 12),
                  ),
                ),
                const SizedBox(height: 10),
                TabBar(
                  controller: _tabController,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: Colors.grey[300],
                  indicatorColor: AppColors.accent,
                  tabs: const [
                    Tab(text: 'Onboarding Requests'),
                    Tab(text: 'Platform Users'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildPendingRequests(),
                _buildUsersList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingRequests() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _pendingRequestsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Failed to load onboarding requests: ${snapshot.error}'),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _pendingRequestsFuture = _adminService.listPendingRequests();
                      });
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }

        final docs = snapshot.data ?? const <Map<String, dynamic>>[];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No pending requests.'),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _pendingRequestsFuture = _adminService.listPendingRequests();
                    });
                  },
                  child: const Text('Refresh'),
                ),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final data = docs[index];
            final uid = (data['uid'] ?? data['id'] ?? '').toString();
            final name = (data['name'] ?? '').toString();
            final email = (data['email'] ?? '').toString();
            final role = (data['role'] ?? '').toString();

            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? 'Unnamed user' : name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text(email),
                    const SizedBox(height: 4),
                    Text('Role: ${role.isEmpty ? 'unknown' : role}'),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _handleAction(
                              uid: uid,
                              action: 'reject',
                            ),
                            child: const Text('Reject'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => _handleAction(
                              uid: uid,
                              action: 'approve',
                            ),
                            child: const Text('Approve'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildUsersList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = (snapshot.data?.docs ?? [])
            .where((doc) => (doc.data()['role'] ?? '').toString() != 'admin')
            .toList();

        if (docs.isEmpty) {
          return const Center(child: Text('No users found.'));
        }

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final data = docs[index].data();
            final uid = docs[index].id;
            final name = (data['name'] ?? '').toString();
            final email = (data['email'] ?? '').toString();
            final role = (data['role'] ?? '').toString();
            final approvalStatus = (data['approvalStatus'] ?? 'approved').toString();

            return Card(
              child: ListTile(
                title: Text(name.isEmpty ? 'Unnamed user' : name),
                subtitle: Text('$email\nRole: $role | Status: $approvalStatus'),
                isThreeLine: true,
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: AppColors.error),
                  tooltip: 'Remove user',
                  onPressed: () => _handleAction(uid: uid, action: 'delete'),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
