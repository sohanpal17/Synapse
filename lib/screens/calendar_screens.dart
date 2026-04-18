import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';
import '../main.dart';
import '../widgets/common_widgets.dart';
import '../widgets/card_widgets.dart';
import '../models/reminder_models.dart';
import '../providers/providers.dart';

// ==================== PERSONAL CALENDAR SCREEN ====================
class PersonalCalendarScreen extends ConsumerStatefulWidget {
  const PersonalCalendarScreen({super.key});

  @override
  ConsumerState<PersonalCalendarScreen> createState() => _PersonalCalendarScreenState();
}

class _PersonalCalendarScreenState extends ConsumerState<PersonalCalendarScreen> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  String _selectedFilter = 'All';
  bool _scopeToSelectedDay = false;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
  }

  List<Reminder> _getMonthReminders(List<Reminder> all) {
    return all.where((r) {
      final d = r.dueDateTime;
      return d.year == _focusedDay.year && d.month == _focusedDay.month;
    }).toList();
  }

  List<Reminder> _getDayReminders(List<Reminder> all) {
    final selected = _selectedDay;
    if (selected == null) return const [];
    return all.where((r) {
      final d = r.dueDateTime;
      return d.year == selected.year &&
          d.month == selected.month &&
          d.day == selected.day;
    }).toList();
  }

  List<Reminder> _getScopedReminders(List<Reminder> all) {
    if (_scopeToSelectedDay && _selectedDay != null) {
      return _getDayReminders(all);
    }
    return _getMonthReminders(all);
  }

  List<Reminder> _getFilteredReminders(List<Reminder> all) {
    final scoped = _getScopedReminders(all);

    switch (_selectedFilter) {
      case 'All':
        return scoped;
      case 'Completed':
        return scoped.where((r) => r.isCompleted).toList();
      case 'Incomplete':
      default:
        return scoped.where((r) => !r.isCompleted).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allReminders = ref.watch(remindersProvider);
    final scopedReminders = _getScopedReminders(allReminders);
    final filteredReminders = _getFilteredReminders(allReminders);
    final incompleteCount = scopedReminders.where((r) => !r.isCompleted).length;

    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Column(
              children: [
                Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 12),
                    const Text(
                      'My Calendar',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Filter Chips
                Row(
                  children: [
                    _buildFilterChip('All', null),
                    const SizedBox(width: 8),
                    _buildFilterChip('Incomplete', incompleteCount),
                    const SizedBox(width: 8),
                    _buildFilterChip('Completed', null),
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
                  // Calendar
                  AppCard(
                    child: TableCalendar(
                      firstDay: DateTime.utc(2020, 1, 1),
                      lastDay: DateTime.utc(2030, 12, 31),
                      focusedDay: _focusedDay,
                      calendarFormat: _calendarFormat,
                      selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                      onDaySelected: (selectedDay, focusedDay) {
                        setState(() {
                          _selectedDay = selectedDay;
                          _focusedDay = focusedDay;
                          _scopeToSelectedDay = true;
                        });
                      },
                      onFormatChanged: (format) {
                        setState(() => _calendarFormat = format);
                      },
                      onPageChanged: (focusedDay) {
                        setState(() {
                          _focusedDay = focusedDay;
                          _selectedDay = focusedDay;
                          _scopeToSelectedDay = false;
                        });
                      },
                      calendarStyle: CalendarStyle(
                        todayDecoration: BoxDecoration(
                          color: AppColors.accent.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        selectedDecoration: const BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                        markerDecoration: const BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      headerStyle: const HeaderStyle(
                        formatButtonVisible: false,
                        titleCentered: true,
                        titleTextStyle: TextStyle(
                          color: AppColors.primary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      calendarBuilders: CalendarBuilders(
                        markerBuilder: (context, date, events) {
                          final dayReminders = allReminders.where((r) =>
                              r.dueDateTime.year == date.year &&
                              r.dueDateTime.month == date.month &&
                              r.dueDateTime.day == date.day).toList();
                          if (dayReminders.isNotEmpty) {
                            // Pick the most urgent color
                            Color mostUrgent = const Color(0xFF4CAF50);
                            for (final r in dayReminders) {
                              final c = r.getUrgencyColor();
                              if (c == const Color(0xFFE53935)) { mostUrgent = c; break; }
                              if (c == const Color(0xFFFF9800)) mostUrgent = c;
                            }
                            return Positioned(
                              bottom: 1,
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: mostUrgent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            );
                          }
                          return null;
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Reminders List
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _selectedFilter == 'Incomplete'
                            ? 'Incomplete Tasks ($incompleteCount)'
                            : _selectedFilter == 'Completed'
                                ? 'Completed Tasks'
                                : 'All Reminders (${scopedReminders.length})',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (filteredReminders.isEmpty)
                    AppCard(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            _selectedFilter == 'Incomplete'
                                ? 'No incomplete reminders. Great job! 🎉'
                                : _selectedFilter == 'Completed'
                                    ? 'No completed reminders yet.'
                                    : 'No reminders yet. Tap + to create one.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[500],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    ...filteredReminders.map((reminder) {
                      return ReminderCard(
                        reminder: reminder,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ReminderDetailScreen(reminder: reminder),
                            ),
                          );
                        },
                        onCheckChanged: (value) {
                          final updated = reminder.copyWith(
                            isCompleted: value ?? false,
                            completedAt: (value ?? false) ? DateTime.now() : null,
                          );
                          ref.read(remindersProvider.notifier).updateReminder(updated);
                        },
                      );
                    }).toList(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const CreateReminderScreen(),
            ),
          ).then((_) => setState(() {}));
        },
        backgroundColor: AppColors.accent,
        icon: const Icon(Icons.add, color: AppColors.primary),
        label: const Text(
          'Add Reminder',
          style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, int? count) {
    final isSelected = _selectedFilter == label;
    return GestureDetector(
      onTap: () => setState(() {
        _selectedFilter = label;
        _scopeToSelectedDay = false;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.accent : AppColors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              count != null ? '$label ($count)' : label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isSelected ? AppColors.primary : AppColors.white.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== CREATE REMINDER SCREEN ====================
class CreateReminderScreen extends ConsumerStatefulWidget {
  final Set<String>? initialMemberIds;

  const CreateReminderScreen({super.key, this.initialMemberIds});

  @override
  ConsumerState<CreateReminderScreen> createState() => _CreateReminderScreenState();
}

class _CreateReminderScreenState extends ConsumerState<CreateReminderScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();
  ReminderVisibility _visibility = ReminderVisibility.private;
  Set<String> _selectedUserIds = {};
  bool _selectAll = false;

  List<String> _memberIdsForRole(List<dynamic> members, String role) {
    final target = role.toLowerCase().trim();
    return members
        .where((m) {
          final r = (m.role as String).toLowerCase().trim();
          if (target == 'lawyer') return r == 'lawyer' || r == 'admin';
          return r == target;
        })
        .map<String>((m) => m.uid as String)
        .toList();
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: AppColors.white,
              surface: AppColors.white,
              onSurface: AppColors.text,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _selectTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primary,
              onPrimary: AppColors.white,
              surface: AppColors.white,
              onSurface: AppColors.text,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedTime = picked);
    }
  }

  void _createReminder() {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a title')),
      );
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final members = ref.read(firmMembersProvider).valueOrNull ?? [];

    ReminderVisibility finalVisibility = _visibility;
    Set<String> finalSelectedUserIds = Set<String>.from(_selectedUserIds);

    if (_visibility == ReminderVisibility.lawyers ||
        _visibility == ReminderVisibility.interns) {
      final targetRole = _visibility == ReminderVisibility.lawyers
          ? 'lawyer'
          : 'intern';
      final roleMemberIds = _memberIdsForRole(members, targetRole);

      // If nothing was specifically selected, default to all members of that role.
      if (finalSelectedUserIds.isEmpty) {
        finalSelectedUserIds = roleMemberIds.toSet();
      }

      if (finalSelectedUserIds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _visibility == ReminderVisibility.lawyers
                  ? 'No lawyers available.'
                  : 'No interns available.',
            ),
          ),
        );
        return;
      }

      finalSelectedUserIds = roleMemberIds.toSet();
    }

    // Combine date and time
    final dueDateTime = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedTime.hour,
      _selectedTime.minute,
    );

    final reminder = Reminder(
      id: const Uuid().v4(),
      title: _titleController.text.trim(),
      description: _descriptionController.text.trim(),
      dueDateTime: dueDateTime,
      visibility: finalVisibility,
      sharedWithUserIds: finalSelectedUserIds.toList(),
      createdBy: user.uid,
      createdByName: user.name,
      createdAt: DateTime.now(),
    );

    ref.read(remindersProvider.notifier).addReminder(reminder);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Reminder created: ${_titleController.text}',
          style: const TextStyle(color: AppColors.white),
        ),
        backgroundColor: AppColors.success,
      ),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            color: AppColors.primary,
            child: Row(
              children: [
                _buildBackButton(context),
                const SizedBox(width: 12),
                const Text(
                  'Create Reminder',
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  const Text(
                    'Title',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _titleController,
                    decoration: InputDecoration(
                      hintText: 'Enter reminder title',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.primary, width: 2),
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Description
                  const Text(
                    'Description',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _descriptionController,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Enter reminder description (optional)',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.primary, width: 2),
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Date & Time
                  const Text(
                    'Due Date & Time',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: _selectDate,
                          child: AppCard(
                            child: Row(
                              children: [
                                const Icon(Icons.calendar_today, color: AppColors.primary, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  '${_selectedDate.day}/${_selectedDate.month}/${_selectedDate.year}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: _selectTime,
                          child: AppCard(
                            child: Row(
                              children: [
                                const Icon(Icons.access_time, color: AppColors.primary, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  _selectedTime.format(context),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Visibility Dropdown
                  const Text(
                    'Visibility',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<ReminderVisibility>(
                        value: _visibility,
                        isExpanded: true,
                        icon: const Icon(Icons.arrow_drop_down, color: AppColors.primary),
                        items: [
                          ReminderVisibility.private,
                          ReminderVisibility.lawyers,
                          ReminderVisibility.interns,
                        ].map((visibility) {
                          return DropdownMenuItem(
                            value: visibility,
                            child: Row(
                              children: [
                                Icon(visibility.icon, color: AppColors.primary, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  visibility.displayName,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.text,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _visibility = value!;
                            if (_visibility != ReminderVisibility.lawyers &&
                                _visibility != ReminderVisibility.interns) {
                              _selectedUserIds.clear();
                              _selectAll = false;
                            }
                          });
                        },
                      ),
                    ),
                  ),
                  if (_visibility == ReminderVisibility.lawyers ||
                      _visibility == ReminderVisibility.interns) ...[
                    const SizedBox(height: 16),
                    Text(
                      _visibility == ReminderVisibility.lawyers
                          ? 'All Lawyers'
                          : 'All Interns',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (context) {
                        final membersAsync = ref.watch(firmMembersProvider);
                        return membersAsync.when(
                          loading: () => const Center(
                            child: CircularProgressIndicator(),
                          ),
                          error: (_, __) => const Text('Could not load members'),
                          data: (members) {
                            final targetRole =
                                _visibility == ReminderVisibility.lawyers
                                    ? 'lawyer'
                                    : 'intern';
                            final roleMembers = members
                                .where((m) {
                                  final r = m.role.toLowerCase().trim();
                                  if (targetRole == 'lawyer') {
                                    return r == 'lawyer' || r == 'admin';
                                  }
                                  return r == targetRole;
                                })
                                .toList();

                            if (roleMembers.isEmpty) {
                              return Text(
                                _visibility == ReminderVisibility.lawyers
                                    ? 'No lawyers found.'
                                    : 'No interns found.',
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 13,
                                ),
                              );
                            }

                            final allSelected = roleMembers.isNotEmpty &&
                                roleMembers
                                    .every((m) => _selectedUserIds.contains(m.uid));

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AppCard(
                                  child: CheckboxListTile(
                                    value: allSelected,
                                    onChanged: (value) {
                                      setState(() {
                                        _selectAll = value ?? false;
                                        if (_selectAll) {
                                          _selectedUserIds =
                                              roleMembers.map((m) => m.uid).toSet();
                                        } else {
                                          _selectedUserIds.clear();
                                        }
                                      });
                                    },
                                    title: Text(
                                      _visibility == ReminderVisibility.lawyers
                                          ? 'Select All Lawyers'
                                          : 'Select All Interns',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primary,
                                      ),
                                    ),
                                    activeColor: AppColors.primary,
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ...roleMembers.map((member) {
                                  final isSelected =
                                      _selectedUserIds.contains(member.uid);
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedUserIds.remove(member.uid);
                                          } else {
                                            _selectedUserIds.add(member.uid);
                                          }
                                          _selectAll = roleMembers.isNotEmpty &&
                                              roleMembers.every((m) =>
                                                  _selectedUserIds
                                                      .contains(m.uid));
                                        });
                                      },
                                      child: AppCard(
                                        child: Row(
                                          children: [
                                            Checkbox(
                                              value: isSelected,
                                              onChanged: (value) {
                                                setState(() {
                                                  if (value == true) {
                                                    _selectedUserIds
                                                        .add(member.uid);
                                                  } else {
                                                    _selectedUserIds
                                                        .remove(member.uid);
                                                  }
                                                  _selectAll =
                                                      roleMembers.isNotEmpty &&
                                                          roleMembers.every((m) =>
                                                              _selectedUserIds
                                                                  .contains(
                                                                      m.uid));
                                                });
                                              },
                                              activeColor: AppColors.primary,
                                            ),
                                            const SizedBox(width: 12),
                                            AvatarCircle(
                                              initials: member.name.isNotEmpty
                                                  ? member.name
                                                      .substring(0, 1)
                                                      .toUpperCase()
                                                  : '?',
                                              size: 36,
                                              backgroundColor:
                                                  AppColors.primary,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                member.name,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.text,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ],
                  const SizedBox(height: 32),

                  // Create Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _createReminder,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Create Reminder',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
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

// ==================== REMINDER DETAIL SCREEN ====================
class ReminderDetailScreen extends ConsumerStatefulWidget {
  final Reminder reminder;

  const ReminderDetailScreen({super.key, required this.reminder});

  @override
  ConsumerState<ReminderDetailScreen> createState() => _ReminderDetailScreenState();
}

class _ReminderDetailScreenState extends ConsumerState<ReminderDetailScreen> {
  late bool _isCompleted;
  late Reminder _activeReminder;

  @override
  void initState() {
    super.initState();
    _activeReminder = widget.reminder;
    _isCompleted = _activeReminder.isCompleted;
  }

  void _toggleCompletion() {
    setState(() {
      _isCompleted = !_isCompleted;
    });
    // Persist the change
    final updated = _activeReminder.copyWith(
      isCompleted: _isCompleted,
      completedAt: _isCompleted ? DateTime.now() : null,
    );
    setState(() => _activeReminder = updated);
    ref.read(remindersProvider.notifier).updateReminder(updated);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isCompleted ? 'Reminder marked as complete' : 'Reminder marked as incomplete',
        ),
        backgroundColor: _isCompleted ? AppColors.success : AppColors.warning,
      ),
    );
  }

  Future<void> _deleteReminder() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Reminder'),
        content: const Text('This reminder will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(remindersProvider.notifier).deleteReminder(_activeReminder.id);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reminder deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst('Exception: ', '').trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message.isEmpty
                ? 'Reminder can only be deleted by the creator of this reminder'
                : message,
          ),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _editReminder() async {
    final titleController = TextEditingController(text: _activeReminder.title);
    final descriptionController =
        TextEditingController(text: _activeReminder.description);
    DateTime selectedDate = _activeReminder.dueDateTime;
    TimeOfDay selectedTime = TimeOfDay.fromDateTime(_activeReminder.dueDateTime);

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Edit Reminder'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descriptionController,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Description'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: ctx,
                              initialDate: selectedDate,
                              firstDate: DateTime.now().subtract(const Duration(days: 365)),
                              lastDate: DateTime.now().add(const Duration(days: 3650)),
                            );
                            if (picked != null) {
                              setDialogState(() => selectedDate = picked);
                            }
                          },
                          icon: const Icon(Icons.calendar_today),
                          label: Text(
                              '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () async {
                            final picked = await showTimePicker(
                              context: ctx,
                              initialTime: selectedTime,
                            );
                            if (picked != null) {
                              setDialogState(() => selectedTime = picked);
                            }
                          },
                          icon: const Icon(Icons.access_time),
                          label: Text(selectedTime.format(context)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    if (shouldSave != true) return;
    if (titleController.text.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reminder title cannot be empty')),
      );
      return;
    }

    final dueDateTime = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );

    final updated = _activeReminder.copyWith(
      title: titleController.text.trim(),
      description: descriptionController.text.trim(),
      dueDateTime: dueDateTime,
    );

    await ref.read(remindersProvider.notifier).updateReminder(updated);
    if (!mounted) return;
    setState(() => _activeReminder = updated);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reminder updated successfully')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final urgencyColor = _isCompleted ? Colors.grey : _activeReminder.getUrgencyColor();
    final members = ref.watch(firmMembersProvider).valueOrNull ?? const [];

    return Scaffold(
      body: Column(
        children: [
          // Header with color-coded background
          Container(
            padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
            decoration: BoxDecoration(
              color: urgencyColor,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppColors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(Icons.arrow_back, color: AppColors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _activeReminder.title,
                        style: const TextStyle(
                          color: AppColors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _editReminder,
                      icon: const Icon(Icons.edit_outlined, color: AppColors.white),
                      tooltip: 'Edit reminder',
                    ),
                    IconButton(
                      onPressed: _deleteReminder,
                      icon: const Icon(Icons.delete_outline, color: AppColors.white),
                      tooltip: 'Delete reminder',
                    ),
                    if (_activeReminder.visibility != ReminderVisibility.private)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(_activeReminder.visibility.icon, color: AppColors.white, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              _activeReminder.visibility == ReminderVisibility.everyone ? 'Everyone' : 'Shared',
                              style: const TextStyle(
                                color: AppColors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _isCompleted ? 'Completed' : _activeReminder.getUrgencyLabel(),
                    style: const TextStyle(
                      color: AppColors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
                  // Completion Checkbox
                  GestureDetector(
                    onTap: _toggleCompletion,
                    child: AppCard(
                      child: Row(
                        children: [
                          Checkbox(
                            value: _isCompleted,
                            onChanged: (value) => _toggleCompletion(),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            activeColor: AppColors.success,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _isCompleted ? 'Mark as incomplete' : 'Mark as complete',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Description
                  if (_activeReminder.description.isNotEmpty) ...[
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Description',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _activeReminder.description,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Details
                  AppCard(
                    child: Column(
                      children: [
                        _buildDetailRow('Due Date', _activeReminder.getFormattedDueDate()),
                        const Divider(height: 24),
                        _buildDetailRow('Time Remaining', _activeReminder.getTimeRemaining()),
                        const Divider(height: 24),
                        _buildDetailRow('Created By', _activeReminder.createdByName),
                        const Divider(height: 24),
                        _buildDetailRow('For Whom', _buildForWhomText(members)),
                        const Divider(height: 24),
                        _buildDetailRow(
                          'Created On',
                          '${_activeReminder.createdAt.day}/${_activeReminder.createdAt.month}/${_activeReminder.createdAt.year}',
                        ),
                        if (_isCompleted && _activeReminder.completedAt != null) ...[
                          const Divider(height: 24),
                          _buildDetailRow(
                            'Completed On',
                            '${_activeReminder.completedAt!.day}/${_activeReminder.completedAt!.month}/${_activeReminder.completedAt!.year}',
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[600],
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.text,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  String _buildForWhomText(List<dynamic> members) {
    switch (_activeReminder.visibility) {
      case ReminderVisibility.private:
        return 'Only Me';
      case ReminderVisibility.lawyers:
        return 'All Lawyers';
      case ReminderVisibility.interns:
        return 'All Interns';
      case ReminderVisibility.everyone:
        return 'Everyone';
      case ReminderVisibility.specificUsers:
        final targetIds = _activeReminder.sharedWithUserIds.toSet();
        final names = members
            .where((m) => targetIds.contains(m.uid))
            .map<String>((m) => (m.name as String?)?.trim() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
        if (names.isNotEmpty) {
          return names.join(', ');
        }
        if (targetIds.isNotEmpty) {
          return '${targetIds.length} selected member(s)';
        }
        return 'Selected Members';
    }
  }
}

// Helper widget for back button
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
