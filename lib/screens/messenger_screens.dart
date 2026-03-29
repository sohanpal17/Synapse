import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../widgets/common_widgets.dart';
import '../widgets/card_widgets.dart';
import '../models/messaging_models.dart';
import '../providers/providers.dart';
import '../services/firestore_service.dart';

const int _maxUploadBytes = 25 * 1024 * 1024;

// ==================== MESSENGER SCREEN ====================
class MessengerScreen extends ConsumerStatefulWidget {
  const MessengerScreen({super.key});

  @override
  ConsumerState<MessengerScreen> createState() => _MessengerScreenState();
}

class _MessengerScreenState extends ConsumerState<MessengerScreen> {
  String _formatRoleLabel(String role) {
    if (role.isEmpty) return 'Member';
    return role[0].toUpperCase() + role.substring(1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final canCreateChat = currentUser?.role != 'client';
    final chatGroups = ref.watch(chatGroupsProvider);
    final members = ref.watch(firmMembersProvider).valueOrNull ?? const [];
    final visibleChatGroups = chatGroups.where((g) {
      final hasCaseId = (g.caseId ?? '').trim().isNotEmpty;
      final isCaseChatId = g.id.startsWith('case_chat_');
      final isCaseChatDesc =
          (g.description ?? '').toLowerCase().contains('case chat:');
      return !hasCaseId && !isCaseChatId && !isCaseChatDesc;
    }).toList();

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
                  'Messenger',
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${visibleChatGroups.length} ${visibleChatGroups.length == 1 ? 'Chat' : 'Chats'}',
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
            child: visibleChatGroups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 80,
                            color: Colors.grey[300],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            canCreateChat
                                ? 'No chat groups yet'
                                : 'No conversations yet',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            canCreateChat
                                ? 'Create a new chat to start messaging'
                                : 'A lawyer or intern will start the chat.\nYou can continue the conversation here.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[500],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: visibleChatGroups.length,
                    itemBuilder: (context, index) {
                      final chatGroup = visibleChatGroups[index];
                      final user = ref.read(currentUserProvider);
                      String? directMemberRole;
                      if (chatGroup.memberCount == 2 && user != null) {
                        final otherId = chatGroup.memberIds
                            .firstWhere((id) => id != user.uid, orElse: () => '');
                        if (otherId.isNotEmpty) {
                          final match = members.where((m) => m.uid == otherId);
                          if (match.isNotEmpty) {
                            directMemberRole = _formatRoleLabel(match.first.role);
                          }
                        }
                      }
                      return ChatGroupCard(
                        chatGroup: chatGroup,
                        currentUserId: user?.uid,
                        directMemberRole: directMemberRole,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ChatConversationScreen(
                                chatGroup: chatGroup,
                              ),
                            ),
                          ).then((_) => setState(() {}));
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: canCreateChat
          ? FloatingActionButton.extended(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CreateChatScreen(),
                  ),
                ).then((_) => setState(() {}));
              },
              backgroundColor: AppColors.accent,
              icon: const Icon(Icons.add, color: AppColors.primary),
              label: const Text(
                'New Chat',
                style: TextStyle(
                    color: AppColors.primary, fontWeight: FontWeight.w600),
              ),
            )
          : null,
    );
  }
}

// ==================== CREATE CHAT SCREEN ====================
class CreateChatScreen extends ConsumerStatefulWidget {
  const CreateChatScreen({super.key});

  @override
  ConsumerState<CreateChatScreen> createState() => _CreateChatScreenState();
}

class _CreateChatScreenState extends ConsumerState<CreateChatScreen> {
  final _nameController = TextEditingController();
  final Set<String> _selectedMemberIds = {};
  bool _isGroupChat = true; // true for Group, false for Direct

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _createChat() {
    // For group chats, name is required
    if (_isGroupChat && _nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a chat name')),
      );
      return;
    }

    if (_selectedMemberIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(_isGroupChat
                ? 'Please select at least one member'
                : 'Please select a recipient')),
      );
      return;
    }

    if (!_isGroupChat && _selectedMemberIds.length != 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Please select exactly one recipient for direct message')),
      );
      return;
    }

    final user = ref.read(currentUserProvider);
    if (user == null) return;

    // Build member names from firmMembersProvider
    final membersAsync = ref.read(firmMembersProvider);
    final allMembers = membersAsync.valueOrNull ?? [];
    final memberNames = <String>[];
    final memberIds = <String>[
      ..._selectedMemberIds,
      user.uid,
    ].toSet().toList();

    if (!_isGroupChat && memberIds.length != 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Direct message requires exactly 2 members')),
      );
      return;
    }

    for (final id in memberIds) {
      final match = allMembers.where((m) => m.uid == id);
      if (match.isNotEmpty) {
        memberNames.add(match.first.name);
      } else if (id == user.uid) {
        memberNames.add(user.name);
      } else {
        memberNames.add('Member');
      }
    }

    final directRecipientId = !_isGroupChat
        ? memberIds.firstWhere((id) => id != user.uid, orElse: () => '')
        : '';
    final directRecipientName = !_isGroupChat
        ? (allMembers.where((m) => m.uid == directRecipientId).isNotEmpty
            ? allMembers.firstWhere((m) => m.uid == directRecipientId).name
            : 'Direct message')
        : '';

    final chatName =
        _isGroupChat ? _nameController.text.trim() : directRecipientName;

    final chatGroup = ChatGroup(
      id: const Uuid().v4(),
      name: chatName,
      description: null,
      memberIds: memberIds,
      memberNames: memberNames,
      createdBy: user.uid,
      createdByName: user.name,
      createdAt: DateTime.now(),
    );

    ref.read(chatGroupsProvider.notifier).addChatGroup(chatGroup);

    final chatType = _isGroupChat ? 'Group chat' : 'Direct message';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$chatType "$chatName" created with ${_selectedMemberIds.length} ${_selectedMemberIds.length == 1 ? 'member' : 'members'}',
          style: const TextStyle(color: AppColors.white),
        ),
        backgroundColor: AppColors.success,
      ),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(firmMembersProvider);
    final teamMembers = membersAsync.valueOrNull ?? [];

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
                  'Create Chat',
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
                  // Chat Type Selector
                  const Text(
                    'Chat Type',
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
                          onTap: () {
                            setState(() {
                              _isGroupChat = true;
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: _isGroupChat
                                  ? AppColors.primary
                                  : AppColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _isGroupChat
                                    ? AppColors.primary
                                    : Colors.grey[300]!,
                                width: 2,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.group,
                                  color: _isGroupChat
                                      ? AppColors.white
                                      : AppColors.primary,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Group Chat',
                                  style: TextStyle(
                                    color: _isGroupChat
                                        ? AppColors.white
                                        : AppColors.primary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
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
                          onTap: () {
                            setState(() {
                              _isGroupChat = false;
                              // Clear multiple selections for direct message
                              if (_selectedMemberIds.length > 1) {
                                _selectedMemberIds.clear();
                              }
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: !_isGroupChat
                                  ? AppColors.primary
                                  : AppColors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: !_isGroupChat
                                    ? AppColors.primary
                                    : Colors.grey[300]!,
                                width: 2,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.person,
                                  color: !_isGroupChat
                                      ? AppColors.white
                                      : AppColors.primary,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Direct Message',
                                  style: TextStyle(
                                    color: !_isGroupChat
                                        ? AppColors.white
                                        : AppColors.primary,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Chat Name (only for group chats)
                  if (_isGroupChat) ...[
                    const Text(
                      'Chat Name',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        hintText: 'Enter chat group name',
                        hintStyle: TextStyle(color: Colors.grey[400]),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.grey[300]!),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.primary, width: 2),
                        ),
                        contentPadding: const EdgeInsets.all(16),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const SizedBox(height: 4),
                  ],

                  // Member Selection
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _isGroupChat ? 'Select Members' : 'Select Recipient',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                      if (_selectedMemberIds.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_selectedMemberIds.length} selected',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Select All Checkbox (only for group chats)
                  if (_isGroupChat)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          if (_selectedMemberIds.length == teamMembers.length) {
                            _selectedMemberIds.clear();
                          } else {
                            _selectedMemberIds
                                .addAll(teamMembers.map((m) => m.uid));
                          }
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: AppCard(
                          child: Row(
                            children: [
                              Checkbox(
                                value: _selectedMemberIds.length ==
                                    teamMembers.length,
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedMemberIds.addAll(
                                          teamMembers.map((m) => m.uid));
                                    } else {
                                      _selectedMemberIds.clear();
                                    }
                                  });
                                },
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                activeColor: AppColors.primary,
                              ),
                              const SizedBox(width: 12),
                              const Icon(Icons.select_all,
                                  color: AppColors.primary),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'Select All',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Member List
                  ...teamMembers.map((member) {
                    final isSelected = _selectedMemberIds.contains(member.uid);
                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedMemberIds.remove(member.uid);
                          } else {
                            // For direct messages, only allow one selection
                            if (!_isGroupChat) {
                              _selectedMemberIds.clear();
                            }
                            _selectedMemberIds.add(member.uid);
                          }
                        });
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: AppCard(
                          child: Row(
                            children: [
                              Checkbox(
                                value: isSelected,
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      // For direct messages, only allow one selection
                                      if (!_isGroupChat) {
                                        _selectedMemberIds.clear();
                                      }
                                      _selectedMemberIds.add(member.uid);
                                    } else {
                                      _selectedMemberIds.remove(member.uid);
                                    }
                                  });
                                },
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                activeColor: AppColors.primary,
                              ),
                              const SizedBox(width: 12),
                              CircleAvatar(
                                backgroundColor: AppColors.primary,
                                radius: 20,
                                child: Text(
                                  member.name.isNotEmpty
                                      ? member.name
                                          .substring(0, 1)
                                          .toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: AppColors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      member.name,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.text,
                                      ),
                                    ),
                                    Text(
                                      member.role,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),

                  const SizedBox(height: 32),

                  // Create Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _createChat,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        _isGroupChat
                            ? 'Create Group Chat'
                            : 'Start Direct Message',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== CHAT CONVERSATION SCREEN ====================
class ChatConversationScreen extends ConsumerStatefulWidget {
  final ChatGroup chatGroup;

  const ChatConversationScreen({super.key, required this.chatGroup});

  @override
  ConsumerState<ChatConversationScreen> createState() =>
      _ChatConversationScreenState();
}

class _ChatConversationScreenState
    extends ConsumerState<ChatConversationScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  String? _selectedAttachmentUrl;
  String? _selectedAttachmentType;
  String? _selectedAttachmentName;
  bool _uploadingAttachment = false;

  String _formatRoleLabel(String role) {
    if (role.isEmpty) return 'Member';
    return role[0].toUpperCase() + role.substring(1).toLowerCase();
  }

  Future<void> _openAttachment(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid attachment URL.')),
      );
      return;
    }

    final opened = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open attachment.')),
      );
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty &&
        _selectedAttachmentUrl == null) return;

    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final msg = ChatMessage(
      id: const Uuid().v4(),
      chatGroupId: widget.chatGroup.id,
      senderId: user.uid,
      senderName: user.name,
      senderRole: user.role,
      content: _messageController.text.trim(),
      timestamp: DateTime.now(),
      attachmentUrl: _selectedAttachmentUrl,
      attachmentType: _selectedAttachmentType,
      attachmentName: _selectedAttachmentName,
    );

    await FirestoreService().sendMessage(msg.toMap());
    _messageController.clear();
    setState(() {
      _selectedAttachmentUrl = null;
      _selectedAttachmentType = null;
      _selectedAttachmentName = null;
    });
  }

  void _pickAttachment() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image, color: AppColors.primary),
              title: const Text('Image'),
              onTap: () async {
                Navigator.pop(context);
                await _pickAndUploadAttachment(
                  allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
                  attachmentType: 'image',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf, color: AppColors.error),
              title: const Text('PDF Document'),
              onTap: () async {
                Navigator.pop(context);
                await _pickAndUploadAttachment(
                  allowedExtensions: const ['pdf'],
                  attachmentType: 'pdf',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.description, color: AppColors.primary),
              title: const Text('Word Document'),
              onTap: () async {
                Navigator.pop(context);
                await _pickAndUploadAttachment(
                  allowedExtensions: const ['doc', 'docx'],
                  attachmentType: 'doc',
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadAttachment({
    required List<String> allowedExtensions,
    required String attachmentType,
  }) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: false,
        allowedExtensions: allowedExtensions,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final picked = result.files.first;
      final bytes = picked.bytes;
      if (bytes == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read selected file.')),
        );
        return;
      }
      if (picked.size > _maxUploadBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is too large. Maximum allowed size is 25 MB.'),
          ),
        );
        return;
      }

      setState(() => _uploadingAttachment = true);

      final safeName = picked.name.replaceAll(' ', '_');
      final storagePath =
          'chat_attachments/${widget.chatGroup.id}/${DateTime.now().millisecondsSinceEpoch}_$safeName';
      final refStorage = FirebaseStorage.instance.ref(storagePath);

      String contentType;
      switch (attachmentType) {
        case 'image':
          contentType = 'image/*';
          break;
        case 'pdf':
          contentType = 'application/pdf';
          break;
        default:
          contentType = 'application/octet-stream';
      }

      await refStorage.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );
      final downloadUrl = await refStorage.getDownloadURL();

      if (!mounted) return;
      setState(() {
        _selectedAttachmentUrl = downloadUrl;
        _selectedAttachmentType = attachmentType;
        _selectedAttachmentName = picked.name;
      });
    } catch (e) {
      if (!mounted) return;
      final err = e.toString();
      if (kIsWeb && (err.contains('CORS') || err.contains('preflight'))) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Upload blocked by Firebase Storage CORS. Configure bucket CORS for localhost and try again.'),
          ),
        );
        return;
      }
      if (err.contains('403') ||
          err.toLowerCase().contains('forbidden') ||
          err.toLowerCase().contains('permission')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Attachment upload blocked by Firebase Storage Rules (403). Allow authenticated write access to chat_attachments/* in Storage Rules.'),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attachment upload failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _uploadingAttachment = false);
      }
    }
  }

  void _deleteChat() {
    final user = ref.read(currentUserProvider);
    if (user == null || user.uid != widget.chatGroup.createdBy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the group creator can delete chat.')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chat'),
        content:
            Text('Are you sure you want to delete "${widget.chatGroup.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(chatGroupsProvider.notifier)
                  .deleteChatGroup(widget.chatGroup.id);
              Navigator.pop(context); // Close dialog
              Navigator.pop(context); // Close chat screen
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Chat deleted'),
                  backgroundColor: AppColors.error,
                ),
              );
            },
            child:
                const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditGroupNameDialog(ChatGroup chatGroup) async {
    final user = ref.read(currentUserProvider);
    if (user == null || user.uid != chatGroup.createdBy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the group creator can edit group name.')),
      );
      return;
    }

    final controller = TextEditingController(text: chatGroup.name);
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Group Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter group name'),
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

    if (shouldSave != true) return;
    final updatedName = controller.text.trim();
    if (updatedName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name cannot be empty')),
      );
      return;
    }

    final updated = ChatGroup(
      id: chatGroup.id,
      caseId: chatGroup.caseId,
      name: updatedName,
      description: chatGroup.description,
      createdBy: chatGroup.createdBy,
      createdByName: chatGroup.createdByName,
      createdAt: chatGroup.createdAt,
      memberIds: chatGroup.memberIds,
      memberNames: chatGroup.memberNames,
      lastMessage: chatGroup.lastMessage,
      lastMessageTime: chatGroup.lastMessageTime,
      isTemporary: chatGroup.isTemporary,
    );

    await ref.read(chatGroupsProvider.notifier).updateChatGroup(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group name updated')),
    );
  }

  Future<void> _showManageMembersDialog(ChatGroup chatGroup) async {
    final user = ref.read(currentUserProvider);
    if (user == null || user.uid != chatGroup.createdBy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the group creator can manage members.')),
      );
      return;
    }

    final members = ref.read(firmMembersProvider).valueOrNull ?? [];
    final selectedIds = Set<String>.from(chatGroup.memberIds);

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Manage Members'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: members.map((member) {
                final isCreator = member.uid == chatGroup.createdBy;
                final isSelected = selectedIds.contains(member.uid);
                return CheckboxListTile(
                  value: isSelected || isCreator,
                  onChanged: isCreator
                      ? null
                      : (value) {
                          setDialogState(() {
                            if (value == true) {
                              selectedIds.add(member.uid);
                            } else {
                              selectedIds.remove(member.uid);
                            }
                          });
                        },
                  title: Text(member.name),
                  subtitle: Text(_formatRoleLabel(member.role)),
                  controlAffinity: ListTileControlAffinity.leading,
                );
              }).toList(),
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
      ),
    );

    if (shouldSave != true) return;

    selectedIds.add(chatGroup.createdBy);
    final newMemberIds = selectedIds.toList();
    final newMemberNames = <String>[];
    for (final id in newMemberIds) {
      final match = members.where((m) => m.uid == id);
      if (match.isNotEmpty) {
        newMemberNames.add(match.first.name);
      } else if (id == chatGroup.createdBy) {
        newMemberNames.add(chatGroup.createdByName);
      }
    }

    final updated = ChatGroup(
      id: chatGroup.id,
      caseId: chatGroup.caseId,
      name: chatGroup.name,
      description: chatGroup.description,
      createdBy: chatGroup.createdBy,
      createdByName: chatGroup.createdByName,
      createdAt: chatGroup.createdAt,
      memberIds: newMemberIds,
      memberNames: newMemberNames,
      lastMessage: chatGroup.lastMessage,
      lastMessageTime: chatGroup.lastMessageTime,
      isTemporary: chatGroup.isTemporary,
    );

    await ref.read(chatGroupsProvider.notifier).updateChatGroup(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group members updated')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final currentUserId = user?.uid ?? '';
    final chatGroups = ref.watch(chatGroupsProvider);
    final chatGroup = chatGroups.where((g) => g.id == widget.chatGroup.id).isNotEmpty
        ? chatGroups.firstWhere((g) => g.id == widget.chatGroup.id)
        : widget.chatGroup;
    final members = ref.watch(firmMembersProvider).valueOrNull ?? const [];
    final isOwner = currentUserId.isNotEmpty && currentUserId == chatGroup.createdBy;

    String displayName = chatGroup.name;
    String directRoleLabel = '';
    if (chatGroup.memberCount == 2) {
      final otherIndex =
          chatGroup.memberIds.indexWhere((id) => id != currentUserId);
      if (otherIndex != -1 &&
          otherIndex < chatGroup.memberNames.length) {
        displayName =
            chatGroup.memberNames[otherIndex].replaceAll(' (You)', '');
      }
      final otherId =
          chatGroup.memberIds.firstWhere((id) => id != currentUserId, orElse: () => '');
      if (otherId.isNotEmpty) {
        final match = members.where((m) => m.uid == otherId);
        if (match.isNotEmpty) {
          directRoleLabel = _formatRoleLabel(match.first.role);
        }
      }
    }

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
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: const TextStyle(
                              color: AppColors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            chatGroup.memberCount == 2
                                ? (directRoleLabel.isEmpty
                                    ? 'Direct message'
                                    : 'Direct • $directRoleLabel')
                                : '${chatGroup.memberCount} members',
                            style: TextStyle(
                              color: AppColors.white.withOpacity(0.7),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton(
                      icon: const Icon(Icons.more_vert, color: AppColors.white),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'members',
                          child: Row(
                            children: [
                              Icon(Icons.people, size: 20),
                              SizedBox(width: 12),
                              Text('View Members'),
                            ],
                          ),
                        ),
                        if (chatGroup.memberCount > 2 && isOwner)
                          const PopupMenuItem(
                            value: 'edit_name',
                            child: Row(
                              children: [
                                Icon(Icons.edit, size: 20),
                                SizedBox(width: 12),
                                Text('Edit Group Name'),
                              ],
                            ),
                          ),
                        if (chatGroup.memberCount > 2 && isOwner)
                          const PopupMenuItem(
                            value: 'manage_members',
                            child: Row(
                              children: [
                                Icon(Icons.group_add, size: 20),
                                SizedBox(width: 12),
                                Text('Add / Remove Members'),
                              ],
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete,
                                  size: 20, color: AppColors.error),
                              SizedBox(width: 12),
                              Text('Delete Chat',
                                  style: TextStyle(color: AppColors.error)),
                            ],
                          ),
                        ),
                      ],
                      onSelected: (value) {
                        if (value == 'delete') {
                          _deleteChat();
                        } else if (value == 'members') {
                          _showMembersDialog(chatGroup);
                        } else if (value == 'edit_name') {
                          _showEditGroupNameDialog(chatGroup);
                        } else if (value == 'manage_members') {
                          _showManageMembersDialog(chatGroup);
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Messages
          // Messages — real-time stream from Firestore
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: FirestoreService().watchMessages(widget.chatGroup.id),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rawMessages = snapshot.data ?? [];
                final messages =
                    rawMessages.map((m) => ChatMessage.fromMap(m)).toList();

                if (messages.isEmpty) {
                  return Center(
                    child: Text(
                      'No messages yet. Start the conversation!',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[500],
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(20),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final isOwnMessage = message.senderId == currentUserId;

                    return Align(
                      alignment: isOwnMessage
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                        ),
                        child: Column(
                          crossAxisAlignment: isOwnMessage
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            if (!isOwnMessage)
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 12, bottom: 4),
                                child: Text(
                                  '${message.senderName} • ${message.senderRole}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isOwnMessage
                                    ? AppColors.primary
                                    : AppColors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (message.attachmentUrl != null) ...[
                                    GestureDetector(
                                      onTap: () => _openAttachment(
                                          message.attachmentUrl!),
                                      child: Container(
                                        margin:
                                            const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isOwnMessage
                                              ? AppColors.white.withOpacity(0.2)
                                              : AppColors.primary
                                                  .withOpacity(0.1),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              message.attachmentType == 'pdf'
                                                  ? Icons.picture_as_pdf
                                                  : message.attachmentType ==
                                                          'image'
                                                      ? Icons.image
                                                      : Icons.description,
                                              size: 16,
                                              color: isOwnMessage
                                                  ? AppColors.white
                                                  : AppColors.primary,
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                message.attachmentName ??
                                                    'Attachment',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                  color: isOwnMessage
                                                      ? AppColors.white
                                                      : AppColors.text,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Icon(
                                              Icons.open_in_new,
                                              size: 14,
                                              color: isOwnMessage
                                                  ? AppColors.white
                                                  : AppColors.primary,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                  if (message.content.isNotEmpty)
                                    Text(
                                      message.content,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: isOwnMessage
                                            ? AppColors.white
                                            : AppColors.text,
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    message.getTimeDisplay(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isOwnMessage
                                          ? AppColors.white.withOpacity(0.7)
                                          : Colors.grey[500],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),

          // Message Input
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selectedAttachmentUrl != null) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: AppColors.primary.withOpacity(0.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _selectedAttachmentType == 'pdf'
                              ? Icons.picture_as_pdf
                              : _selectedAttachmentType == 'image'
                                  ? Icons.image
                                  : Icons.description,
                          size: 20,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _selectedAttachmentName ?? 'Attachment',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () => setState(() {
                            _selectedAttachmentUrl = null;
                            _selectedAttachmentType = null;
                            _selectedAttachmentName = null;
                          }),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.grey[300],
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close,
                                size: 14, color: Colors.black54),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.attach_file, color: Colors.grey),
                      onPressed: _uploadingAttachment ? null : _pickAttachment,
                    ),
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(
                          hintText: 'Type a message...',
                          hintStyle: TextStyle(color: Colors.grey[400]),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide(color: Colors.grey[300]!),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: const BorderSide(
                                color: AppColors.primary, width: 2),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                        maxLines: null,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      decoration: const BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send, color: AppColors.primary),
                        onPressed: _uploadingAttachment ? null : _sendMessage,
                      ),
                    ),
                  ],
                ),
                if (_uploadingAttachment)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showMembersDialog(ChatGroup chatGroup) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Chat Members'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: chatGroup.memberNames.length,
            itemBuilder: (context, index) {
              final memberName = chatGroup.memberNames[index];
              final initials = memberName.isNotEmpty
                  ? memberName.substring(0, 1).toUpperCase()
                  : '?';

              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary,
                  child: Text(
                    initials,
                    style: const TextStyle(
                        color: AppColors.white, fontWeight: FontWeight.w600),
                  ),
                ),
                title: Text(memberName),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
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
