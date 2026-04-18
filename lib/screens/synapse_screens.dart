// Placeholder screens for features not yet implemented
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../main.dart';
import '../models/case_model.dart';
import '../models/user_model.dart';
import '../providers/providers.dart';
import '../services/pdf_service.dart';
import '../services/sos_service.dart';
import '../widgets/common_widgets.dart';

class SynapsePlaceholder extends StatelessWidget {
  const SynapsePlaceholder({super.key});
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Feature coming soon"));
  }
}

// ══════════ COURTROOM SOS ══════════

class CourtroomSOSScreen extends ConsumerStatefulWidget {
  const CourtroomSOSScreen({super.key});

  @override
  ConsumerState<CourtroomSOSScreen> createState() => _CourtroomSOSScreenState();
}

class _CourtroomSOSScreenState extends ConsumerState<CourtroomSOSScreen> {
  bool _isSending = false;
  bool _didInitArgs = false;
  String _recipientCategory = 'all';
  CaseModel? _caseSpecificFromArgs;
  String? _selectedCaseId;
  final Set<String> _selectedMemberIds = <String>{};

  @override
  void initState() {
    super.initState();
    // Start fetching members as soon as screen is created.
    Future<void>.microtask(() {
      ref.read(firmMembersProvider);
    });
  }

  void _initFromArgs(List<CaseModel> activeCases) {
    if (_didInitArgs) return;
    _didInitArgs = true;

    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is CaseModel) {
      _caseSpecificFromArgs = args;
      _selectedCaseId = args.cino;
      _selectedMemberIds.addAll(args.assignedMemberIds);
      return;
    }

    if (activeCases.isNotEmpty) {
      _selectedCaseId = activeCases.first.cino;
    }
  }

  List<UserModel> _eligibleRecipients(
    List<UserModel> members,
    String? currentUid,
    CaseModel? selectedCase,
  ) {
    final availableMembers = members.where((m) => m.uid != currentUid).toList();

    Set<String>? allowedIds;
    if (_caseSpecificFromArgs != null && selectedCase != null) {
      // Case-specific SOS is restricted to the case team only.
      allowedIds = selectedCase.assignedMemberIds.toSet();
    }

    return availableMembers.where((m) {
      final isLawyer = m.role == 'lawyer' || m.role == 'admin';
      final isIntern = m.role == 'intern';
      final isTeamMember = isLawyer || isIntern;
      if (!isTeamMember) return false;

      if (_recipientCategory == 'lawyer' && !isLawyer) return false;
      if (_recipientCategory == 'intern' && !isIntern) return false;

      if (allowedIds != null && !allowedIds.contains(m.uid)) return false;
      return true;
    }).toList();
  }

  Future<void> _triggerSOS(
    CaseModel effectiveCase,
    String caseLabel,
    List<String> recipientPhones,
  ) async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;

    if (_selectedMemberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one recipient.')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('TRIGGER COURTROOM SOS?'),
        content: Text(
          'Case: $caseLabel\nRecipients selected: ${_selectedMemberIds.length}\n\nThis sends a high-priority emergency SOS alert. Use only in emergencies.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('TRIGGER SOS',
                style: TextStyle(
                    color: AppColors.error, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isSending = true);

    try {
      final result = await SOSService.sendSOS(
        caseId: effectiveCase.cino,
        caseName: effectiveCase.title,
        courtRoom: effectiveCase.courtRoom,
        courtComplex: effectiveCase.courtComplex,
        sentById: user.uid,
        sentByName: user.name,
        recipientIds: _selectedMemberIds.toList(),
        recipientPhones: recipientPhones,
        message: '${user.name} needs immediate help for $caseLabel',
      );

      String successMessage;
      switch (result) {
        case 'sent_online':
          successMessage = 'SOS sent successfully.';
          break;
        case 'sent_sms':
          successMessage = 'SOS sent via SMS fallback.';
          break;
        default:
          successMessage = 'SOS queued and will send when connection is available.';
      }

      if (context.mounted) {
        Navigator.pop(context); // Return to previous screen
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(successMessage),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to send SOS: $e'),
              backgroundColor: AppColors.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cases = ref.watch(casesProvider);
    final activeCases = cases.where((c) => !c.isClosed).toList();
    final currentUser = ref.watch(currentUserProvider);
    final membersAsync = ref.watch(firmMembersProvider);
    final cachedMembers = ref.watch(cachedFirmMembersProvider);
    final resolvedMembers = membersAsync.valueOrNull ?? cachedMembers;

    _initFromArgs(activeCases);

    CaseModel? selectedCase;
    if (_selectedCaseId != null) {
      for (final c in activeCases) {
        if (c.cino == _selectedCaseId) {
          selectedCase = c;
          break;
        }
      }
    }

    final effectiveCase = selectedCase ?? _caseSpecificFromArgs;
    final caseLabel = effectiveCase == null
        ? 'No case selected'
        : '${effectiveCase.title} (${effectiveCase.caseNumber})';
    final recipientPhones = resolvedMembers
      .where((m) => _selectedMemberIds.contains(m.uid))
      .map((m) => m.phone)
      .where((p) => p.trim().isNotEmpty)
      .toList();

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.error, Colors.redAccent],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 16),
                    const Text(
                      'Courtroom Emergency',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.error.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppColors.error.withOpacity(0.25)),
                          ),
                          child: Text(
                            _caseSpecificFromArgs != null
                                ? 'Case-specific SOS: recipients are limited to assigned team members of this case. Use All/Lawyers/Interns to filter the list.'
                                : 'Quick SOS: choose a case and select recipients from internal team categories (All/Lawyers/Interns).',
                            style: const TextStyle(
                              color: AppColors.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Case',
                          style: TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_caseSpecificFromArgs != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 14),
                            decoration: BoxDecoration(
                              color: AppColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: Text(
                              caseLabel,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedCaseId,
                                hint: Text('Select case',
                                    style: TextStyle(color: Colors.grey[500])),
                                isExpanded: true,
                                items: activeCases
                                    .map(
                                      (c) => DropdownMenuItem<String>(
                                        value: c.cino,
                                        child: Text(c.title,
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) {
                                  setState(() {
                                    _selectedCaseId = value;
                                  });
                                },
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        const Text(
                          'Recipient Type',
                          style: TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  if (_recipientCategory == 'all') return;
                                  setState(() {
                                    _recipientCategory = 'all';
                                  });
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                    color: _recipientCategory == 'all'
                                        ? AppColors.primary
                                        : AppColors.white,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: _recipientCategory == 'all'
                                          ? AppColors.primary
                                          : Colors.grey[300]!,
                                    ),
                                  ),
                                  child: Text(
                                    'All',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _recipientCategory == 'all'
                                          ? AppColors.white
                                          : AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  if (_recipientCategory == 'lawyer') return;
                                  setState(() {
                                    _recipientCategory = 'lawyer';
                                  });
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                    color: _recipientCategory == 'lawyer'
                                        ? AppColors.primary
                                        : AppColors.white,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: _recipientCategory == 'lawyer'
                                          ? AppColors.primary
                                          : Colors.grey[300]!,
                                    ),
                                  ),
                                  child: Text(
                                    'Lawyers',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _recipientCategory == 'lawyer'
                                          ? AppColors.white
                                          : AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: GestureDetector(
                                onTap: () {
                                  if (_recipientCategory == 'intern') return;
                                  setState(() {
                                    _recipientCategory = 'intern';
                                  });
                                },
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  decoration: BoxDecoration(
                                    color: _recipientCategory == 'intern'
                                        ? AppColors.primary
                                        : AppColors.white,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: _recipientCategory == 'intern'
                                          ? AppColors.primary
                                          : Colors.grey[300]!,
                                    ),
                                  ),
                                  child: Text(
                                    'Interns',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _recipientCategory == 'intern'
                                          ? AppColors.white
                                          : AppColors.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Recipients',
                              style: TextStyle(
                                color: AppColors.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Builder(
                              builder: (context) {
                                final visibleMembers = _eligibleRecipients(
                                  resolvedMembers,
                                  currentUser?.uid,
                                  effectiveCase,
                                );
                                final allSelected = visibleMembers.isNotEmpty &&
                                    visibleMembers.every((m) =>
                                        _selectedMemberIds.contains(m.uid));
                                return TextButton(
                                  onPressed: visibleMembers.isEmpty
                                      ? null
                                      : () {
                                          setState(() {
                                            if (allSelected) {
                                              for (final m in visibleMembers) {
                                                _selectedMemberIds.remove(m.uid);
                                              }
                                            } else {
                                              for (final m in visibleMembers) {
                                                _selectedMemberIds.add(m.uid);
                                              }
                                            }
                                          });
                                        },
                                  child: Text(
                                    allSelected ? 'Deselect all' : 'Select all',
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        Builder(
                          builder: (context) {
                            final visibleMembers = _eligibleRecipients(
                              resolvedMembers,
                              currentUser?.uid,
                              effectiveCase,
                            );

                            // Keep selection valid for case-specific SOS.
                            final teamMemberIds = resolvedMembers
                              .where((m) =>
                                m.role == 'lawyer' ||
                                m.role == 'admin' ||
                                m.role == 'intern')
                              .map((m) => m.uid)
                              .toSet();
                            _selectedMemberIds
                              .removeWhere((id) => !teamMemberIds.contains(id));

                            if (_caseSpecificFromArgs != null &&
                              effectiveCase != null) {
                              final allowedIds =
                                effectiveCase.assignedMemberIds.toSet();
                              _selectedMemberIds.removeWhere(
                                  (id) => !allowedIds.contains(id));
                            }

                            if (visibleMembers.isEmpty &&
                                membersAsync.isLoading &&
                                cachedMembers.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 18),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }

                            if (visibleMembers.isEmpty) {
                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppColors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.grey[300]!),
                                ),
                                child: const Text(
                                  'No eligible members available.',
                                  style: TextStyle(color: AppColors.textLight),
                                ),
                              );
                            }

                            return Column(
                              children: visibleMembers.map((m) {
                                final isSelected =
                                    _selectedMemberIds.contains(m.uid);
                                return GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      if (isSelected) {
                                        _selectedMemberIds.remove(m.uid);
                                      } else {
                                        _selectedMemberIds.add(m.uid);
                                      }
                                    });
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? AppColors.accent.withOpacity(0.1)
                                          : AppColors.white,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? AppColors.accent
                                            : Colors.grey[300]!,
                                        width: 2,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        AvatarCircle(
                                            initials: m.initials, size: 36),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                m.name,
                                                style: TextStyle(
                                                  color: AppColors.text,
                                                  fontWeight: isSelected
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                ),
                                              ),
                                              Text(
                                                m.role,
                                                style: const TextStyle(
                                                  color: AppColors.textLight,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (isSelected)
                                          const Icon(Icons.check_circle,
                                              color: AppColors.accent),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.error,
                              foregroundColor: AppColors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                            onPressed: _isSending || effectiveCase == null
                                ? null
                              : () => _triggerSOS(effectiveCase, caseLabel, recipientPhones),
                            icon: _isSending
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.white,
                                    ),
                                  )
                                : const Icon(Icons.sos),
                            label: Text(
                                _isSending ? 'Sending SOS...' : 'Send SOS'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════ DOCUMENT GENERATOR ══════════

class DocumentGeneratorScreen extends ConsumerWidget {
  const DocumentGeneratorScreen({super.key});

  Future<void> _generate(BuildContext context, CaseModel c, String type, String lawyerName) async {
    try {
      final bytes = type == 'adjournment'
          ? await PdfService.generateAdjournmentApplication(
              caseData: c,
              reason: 'Professional engagement before another court',
              lawyerName: lawyerName,
            )
          : await PdfService.generateExemptionApplication(
              caseData: c,
              reason: 'Medical emergency / unavoidable circumstances',
              lawyerName: lawyerName,
            );

      final title =
          type == 'adjournment' ? 'Adjournment_Application_${c.caseNumber}' : 'Exemption_Application_${c.caseNumber}';
      await PdfService.previewPdf(bytes, title);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Document generation failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final selectedCase = args is CaseModel ? args : null;
    final currentUser = ref.watch(currentUserProvider);
    final lawyerName = (currentUser?.name ?? 'Advocate').trim().isEmpty
        ? 'Advocate'
        : currentUser!.name;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.secondary],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 16),
                    const Text(
                      'Document Generator',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: selectedCase == null
                      ? const Center(
                          child: Text(
                            'Open Document Generator from a specific case to auto-fill case details.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 16, color: AppColors.textLight),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppCard(
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        selectedCase.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.text,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'Case No: ${selectedCase.caseNumber}',
                                        style: const TextStyle(color: AppColors.textLight),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Court: ${selectedCase.courtRoom}, ${selectedCase.courtComplex}',
                                        style: const TextStyle(color: AppColors.textLight),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => _generate(
                                    context,
                                    selectedCase,
                                    'exemption',
                                    lawyerName,
                                  ),
                                  icon: const Icon(Icons.article_outlined),
                                  label: const Text('Generate Exemption Application'),
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => _generate(
                                    context,
                                    selectedCase,
                                    'adjournment',
                                    lawyerName,
                                  ),
                                  icon: const Icon(Icons.gavel_outlined),
                                  label: const Text('Generate Adjournment Application'),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════ LEGAL TOOLS ══════════

class LegalToolsScreen extends StatelessWidget {
  const LegalToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.secondary],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    _buildBackButton(context),
                    const SizedBox(width: 16),
                    const Text(
                      'Legal Tools',
                      style: TextStyle(
                        color: AppColors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(28),
                      topRight: Radius.circular(28),
                    ),
                  ),
                  child: const Center(
                    child: Text(
                      'Legal Tools\nComing Soon',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 16, color: AppColors.textLight),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
