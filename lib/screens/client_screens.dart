import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../main.dart';
import '../widgets/common_widgets.dart';
import '../providers/providers.dart';
import '../services/notification_service.dart';
import '../models/case_model.dart';
import '../models/reminder_models.dart';
import '../models/task_models.dart';
import '../models/notice_models.dart';

// ==================== CLIENT DASHBOARD ====================
class ClientDashboard extends ConsumerStatefulWidget {
  const ClientDashboard({super.key});

  @override
  ConsumerState<ClientDashboard> createState() => _ClientDashboardState();
}

class _ClientDashboardState extends ConsumerState<ClientDashboard> {
  int _currentNavIndex = 0;
  final Set<String> _seenSosAlertIds = <String>{};
  bool _showSosBlink = false;
  bool _blinkOn = false;
  Timer? _blinkTicker;
  Timer? _blinkStopper;

  void _triggerSosBlink() {
    _blinkTicker?.cancel();
    _blinkStopper?.cancel();

    setState(() {
      _showSosBlink = true;
      _blinkOn = true;
    });

    _blinkTicker = Timer.periodic(const Duration(milliseconds: 220), (_) {
      if (!mounted) return;
      setState(() => _blinkOn = !_blinkOn);
    });

    _blinkStopper = Timer(const Duration(seconds: 3), () {
      _blinkTicker?.cancel();
      if (!mounted) return;
      setState(() {
        _showSosBlink = false;
        _blinkOn = false;
      });
    });
  }

  void _processSosAlerts(
    AsyncValue<List<Map<String, dynamic>>> alertsAsync,
    String currentUid,
  ) {
    alertsAsync.whenData((alerts) {
      for (final alert in alerts) {
        final id = (alert['id'] ?? '').toString();
        if (id.isEmpty || _seenSosAlertIds.contains(id)) continue;

        final timestampRaw = (alert['timestamp'] ?? '').toString();
        final sentAt = DateTime.tryParse(timestampRaw);
        final isRecent = sentAt != null &&
            DateTime.now().difference(sentAt) <= const Duration(minutes: 2);

        _seenSosAlertIds.add(id);

        if (NotificationService.shouldSuppressSosVisual(sosId: id)) {
          continue;
        }

        // Ignore stale SOS alerts to avoid confusion when opening app much later.
        if (!isRecent) continue;

        if ((alert['sentBy'] ?? '').toString() == currentUid) continue;

        _triggerSosBlink();

        if (mounted) {
          final senderName =
              (alert['sentByName'] ?? 'Team member').toString();
          final caseName = (alert['caseName'] ?? 'Unknown case').toString();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('SOS received from $senderName ($caseName)'),
              backgroundColor: AppColors.error,
            ),
          );
        }

        NotificationService.showSOSAlert(
          senderName: (alert['sentByName'] ?? 'Team member').toString(),
          caseName: (alert['caseName'] ?? 'Unknown case').toString(),
          courtRoom: (alert['courtRoom'] ?? 'Unknown courtroom').toString(),
        );
      }
    });
  }

  @override
  void dispose() {
    _blinkTicker?.cancel();
    _blinkStopper?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final sosAlerts = ref.watch(sosAlertsProvider);
    final uid = user?.uid ?? '';
    if (uid.isNotEmpty) {
      _processSosAlerts(sosAlerts, uid);
    }

    final allCases = ref.watch(casesProvider);
    final myCases = allCases.where((c) => c.clientIds.contains(user?.uid) && !c.isClosed).toList();
    myCases.sort((a, b) => (a.nextHearingDate ?? DateTime(2099)).compareTo(b.nextHearingDate ?? DateTime(2099)));
    final activeCase = myCases.isNotEmpty ? myCases.first : null;

    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
            color: AppColors.primary,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome',
                      style: TextStyle(color: AppColors.white.withOpacity(0.6), fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user?.name ?? 'Client',
                      style: const TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.settings, color: AppColors.white, size: 20),
                        onPressed: () => Navigator.pushNamed(context, '/settings-client'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AvatarCircle(
                      initials: user?.initials ?? 'CL',
                      size: 40,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (activeCase != null)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.primary, AppColors.secondary],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withOpacity(0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Your Active Case', style: TextStyle(color: AppColors.white.withOpacity(0.6), fontSize: 12)),
                                    const SizedBox(height: 4),
                                    Text(
                                      activeCase.title,
                                      style: const TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  activeCase.statusText,
                                  style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const Icon(Icons.calendar_today, size: 14, color: AppColors.white),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  activeCase.nextHearingDate != null
                                      ? 'Next hearing: ${DateFormat('MMM dd, yyyy').format(activeCase.nextHearingDate!)}'
                                      : 'Next hearing: TBD',
                                  style: TextStyle(color: AppColors.white.withOpacity(0.85), fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (activeCase == null)
                    const AppCard(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('No active cases assigned yet.'),
                      ),
                    ),
                ],
              ),
            ),
          ),
            ],
          ),
          if (_showSosBlink)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  color: _blinkOn
                      ? AppColors.error.withOpacity(0.32)
                      : Colors.transparent,
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentNavIndex,
        items: const [
          BottomNavItem(icon: Icons.home, label: 'Home'),
          BottomNavItem(icon: Icons.folder, label: 'Cases'),
          BottomNavItem(icon: Icons.description, label: 'Docs'),
          BottomNavItem(icon: Icons.message_outlined, label: 'Messages'),
        ],
        onTap: (index) {
          setState(() => _currentNavIndex = index);
          if (index == 1) Navigator.pushNamed(context, '/client-cases');
          if (index == 2) Navigator.pushNamed(context, '/client-documents');
          if (index == 3) Navigator.pushNamed(context, '/messages');
        },
      ),
    );
  }
}

// ==================== CLIENT CASES ====================
class ClientCasesScreen extends ConsumerWidget {
  const ClientCasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final allCases = ref.watch(casesProvider);
    final myCases = allCases.where((c) => c.clientIds.contains(user?.uid)).toList();

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('My Cases', style: TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                const SearchField(hint: 'Search cases...'),
              ],
            ),
          ),
          Expanded(
            child: myCases.isEmpty
                ? const Center(child: Text('No cases found.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: myCases.length,
                    itemBuilder: (context, index) {
                      final c = myCases[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildCaseCard(
                          context,
                          c,
                          c.title,
                          '${c.courtComplex} • ${c.caseType}',
                          c.nextHearingDate != null ? 'Next: ${DateFormat('MMM dd, yyyy').format(c.nextHearingDate!)}' : 'TBD',
                          c.isClosed ? AppColors.success : AppColors.accent,
                          c.statusText,
                          isResolved: c.isClosed,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCaseCard(
    BuildContext context,
    CaseModel c,
    String title,
    String court,
    String date,
    Color badgeColor,
    String status, {
    bool isResolved = false,
  }) {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/case-progress', arguments: c),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w500, color: AppColors.text))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isResolved ? AppColors.success.withOpacity(0.1) : AppColors.accent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isResolved ? AppColors.success : const Color(0xFFB8942E),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(court, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(isResolved ? Icons.check_circle : Icons.calendar_today, size: 12, color: isResolved ? AppColors.success : AppColors.secondary),
                    const SizedBox(width: 4),
                    Text(date, style: TextStyle(fontSize: 12, color: isResolved ? AppColors.success : AppColors.secondary)),
                  ],
                ),
                Icon(Icons.chevron_right, color: Colors.grey[300]),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== CASE PROGRESS ====================
class CaseProgressScreen extends StatelessWidget {
  const CaseProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ModalRoute.of(context)?.settings.arguments as CaseModel?;

    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: const Center(child: Text('No case selected')),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 24),
            color: AppColors.primary,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 12),
                    Text('Case Progress', style: TextStyle(color: AppColors.white.withOpacity(0.6), fontSize: 14)),
                  ],
                ),
                const SizedBox(height: 16),
                Text(c.title, style: const TextStyle(color: AppColors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                Text(c.courtComplex, style: TextStyle(color: AppColors.white.withOpacity(0.6), fontSize: 14)),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  AppCard(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildTimelineItem(true, 'Case Filed', DateFormat('MMM dd, yyyy').format(c.createdAt), 'Initial petition submitted to court', true),
                        _buildTimelineItem(c.currentStage.isNotEmpty, 'First Hearing', c.lastHearingDate != null ? DateFormat('MMM dd, yyyy').format(c.lastHearingDate!) : 'Pending', 'Case admitted, next date assigned', false),
                        _buildTimelineItem(c.isClosed, 'Current Stage', c.currentStage.isEmpty ? 'Pending' : c.currentStage, 'Ongoing case proceedings', false, isCurrent: !c.isClosed),
                        _buildTimelineItem(c.isClosed, 'Final Judgment', c.decisionDate != null ? DateFormat('MMM dd, yyyy').format(c.decisionDate!) : 'Pending', c.disposalStatus, false, isLast: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pushNamed(context, '/client-documents'),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: AppColors.white),
                          child: const Text('Documents'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pushNamed(context, '/client-calendar'),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.white, foregroundColor: AppColors.primary),
                          child: const Text('Important Dates'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineItem(bool completed, String title, String date, String? description, bool isFirst, {bool isCurrent = false, bool isLast = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: completed ? AppColors.success : (isCurrent ? AppColors.accent : Colors.grey[200]),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: completed
                    ? const Icon(Icons.check, color: AppColors.white, size: 20)
                    : Text(
                        isCurrent ? '3' : '4',
                        style: TextStyle(color: isCurrent ? AppColors.primary : Colors.grey[400], fontWeight: FontWeight.bold),
                      ),
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 48,
                color: completed ? AppColors.success : (isCurrent ? AppColors.accent : Colors.grey[200]),
              ),
          ],
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: isCurrent ? AppColors.accent : (completed ? AppColors.text : Colors.grey[400]),
                  ),
                ),
                Text(
                  date,
                  style: TextStyle(fontSize: 12, color: isCurrent ? AppColors.accent : Colors.grey[500]),
                ),
                if (description != null) ...[
                  const SizedBox(height: 4),
                  Text(description, style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== CLIENT DOCUMENTS ====================
class ClientDocumentsScreen extends ConsumerWidget {
  const ClientDocumentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final myCases = ref.watch(casesProvider)
        .where((c) => c.clientIds.contains(user?.uid))
        .toList();

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text('Case Documents', style: TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Expanded(
            child: myCases.isEmpty
                ? const Center(child: Text('No cases assigned to you yet.'))
                : Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.folder_open, size: 60, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text('No documents uploaded yet', style: const TextStyle(fontSize: 16)),
                        const SizedBox(height: 8),
                        Text(
                          'Documents shared by your legal team\nwill appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[500], fontSize: 14),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ==================== CLIENT CALENDAR ====================
class ClientCalendarScreen extends ConsumerStatefulWidget {
  const ClientCalendarScreen({super.key});

  @override
  ConsumerState<ClientCalendarScreen> createState() => _ClientCalendarScreenState();
}

class _ClientCalendarScreenState extends ConsumerState<ClientCalendarScreen> {
  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final allCases = ref.watch(casesProvider);
    final myCases = allCases.where((c) => c.clientIds.contains(user?.uid)).toList();
    final tasksMap = ref.watch(tasksProvider);
    final allTasks = tasksMap.map((m) => Task.fromMap(m)).toList();

    final upcoming = allTasks
        .where((t) => myCases.any((c) => c.cino == t.caseId) && t.deadline.isAfter(DateTime.now().subtract(const Duration(days: 1))))
        .toList()
      ..sort((a, b) => a.deadline.compareTo(b.deadline));

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text('Hearing Calendar', style: TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppCard(
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(icon: Icon(Icons.chevron_left, color: Colors.grey[400]), onPressed: () {}),
                            const Text('December 2024', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.primary)),
                            IconButton(icon: Icon(Icons.chevron_right, color: Colors.grey[400]), onPressed: () {}),
                          ],
                        ),
                        _buildCalendarGrid(),
                      ],
                    ),
                  ),
                  const Text('Upcoming Hearings & Events', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.primary)),
                  const SizedBox(height: 12),
                  if (upcoming.isEmpty)
                    const AppCard(child: Padding(padding: EdgeInsets.all(20), child: Text('No upcoming events or hearings.')))
                  else
                    ...upcoming.map((t) {
                      final c = myCases.firstWhere(
                          (c) => c.cino == t.caseId,
                          orElse: () => CaseModel(
                              cino: '',
                              title: 'Unknown',
                              courtComplex: '',
                              caseNumber: '',
                              caseType: '',
                              courtRoom: '',
                              currentStage: '',
                              district: '',
                              petitioner: '',
                              respondent: '',
                              state: '',
                              year: DateTime.now().year,
                              isClosed: false,
                              urgencyLevel: 'Normal'));
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: AppCard(
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppColors.accent.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  children: [
                                    Text(DateFormat('dd').format(t.deadline),
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.accent)),
                                    Text(DateFormat('MMM').format(t.deadline),
                                        style: const TextStyle(
                                            fontSize: 12, color: AppColors.accent)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(c.title.isNotEmpty ? c.title : t.title,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w500,
                                            color: AppColors.text),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    Text(t.title,
                                        style: TextStyle(
                                            fontSize: 12, color: Colors.grey[500])),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.access_time,
                                            size: 12, color: AppColors.secondary),
                                        const SizedBox(width: 4),
                                        Text(DateFormat('hh:mm a').format(t.deadline),
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: AppColors.secondary)),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid() {
    final days = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: days.map((d) => Text(d, style: TextStyle(color: Colors.grey[400], fontSize: 12))).toList(),
        ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7),
          itemCount: 28,
          itemBuilder: (context, index) {
            final day = index + 1;
            final isHighlighted = day == 15;
            return Center(
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isHighlighted ? AppColors.accent : null,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(
                    '$day',
                    style: TextStyle(
                      color: isHighlighted ? AppColors.white : AppColors.text,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ==================== LAWYER CONTACT ====================
class LawyerContactScreen extends ConsumerWidget {
  const LawyerContactScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final myCases = ref.watch(casesProvider).where((c) => c.clientIds.contains(user?.uid)).toList();
    
    // Get unique assigned members across all cases
    final assignedIds = <String>{};
    for (var c in myCases) {
      if (c.assignedMemberIds != null) {
        assignedIds.addAll(c.assignedMemberIds);
      }
    }
    
    final allMembersAsync = ref.watch(firmMembersProvider);

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text('Your Legal Team', style: TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Expanded(
            child: allMembersAsync.when(
              data: (firmMembers) {
                final myTeam = firmMembers.where((m) => assignedIds.contains(m.uid)).toList();
                
                if (myTeam.isEmpty) {
                  return const Center(child: Text('No team assigned yet', style: TextStyle(color: Colors.grey)));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: myTeam.length,
                  itemBuilder: (context, index) {
                    final member = myTeam[index];
                    final isLead = member.role == 'lawyer';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      child: AppCard(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            AvatarCircle(
                              initials: member.initials,
                              size: 60,
                              backgroundColor: isLead ? AppColors.primary : AppColors.secondary,
                            ),
                            const SizedBox(height: 12),
                            Text(member.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.text)),
                            Text(isLead ? 'Lead Counsel' : 'Legal Associate', style: TextStyle(color: Colors.grey[500])),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () {},
                                    icon: const Icon(Icons.phone, size: 18),
                                    label: const Text('Call'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.secondary,
                                      foregroundColor: AppColors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => Navigator.pushNamed(context, '/messenger'),
                                    icon: const Icon(Icons.chat, size: 18),
                                    label: const Text('Message'),
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
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== NOTIFICATIONS ====================
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notices = ref.watch(noticesProvider);

    return Scaffold(
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 12),
                    const Text('Notifications', style: TextStyle(color: AppColors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                  ],
                ),
                Text('Mark all read', style: TextStyle(color: AppColors.white.withOpacity(0.6), fontSize: 12)),
              ],
            ),
          ),
          Expanded(
            child: Builder(
              builder: (context) {
                if (notices.isEmpty) {
                  return const Center(
                    child: Text('No notifications yet.', style: TextStyle(color: Colors.grey)),
                  );
                }
                
                final sortedNotices = List<Notice>.from(notices)
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

                return ListView.builder(
                  padding: const EdgeInsets.all(20),
                  itemCount: sortedNotices.length,
                  itemBuilder: (context, index) {
                    final n = sortedNotices[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildNotificationCard(
                        n.priority.icon,
                        n.priority.color,
                        n.title,
                        n.content,
                        n.getTimeAgo(),
                        true, // For now, treat all as unread
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationCard(IconData icon, Color iconColor, String title, String message, String time, bool isUnread) {
    return Opacity(
      opacity: isUnread ? 1.0 : 0.6,
      child: AppCard(
        borderColor: isUnread ? AppColors.accent : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w500, color: isUnread ? AppColors.text : Colors.grey[500], fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(message, style: TextStyle(fontSize: 12, color: isUnread ? Colors.grey[500] : Colors.grey[400])),
                  const SizedBox(height: 4),
                  Text(time, style: TextStyle(fontSize: 11, color: Colors.grey[400])),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Helper
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
