import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import '../config/admin_config.dart';
import 'hive_service.dart';
import 'notification_service.dart';

/// Handles authentication and user management
/// Single firm model — all users belong to firm "synapse_default"
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-south1');
  static const String _firmMembersCacheKey = 'firm_members_cache';
  static List<UserModel> _firmMembersMemoryCache = const [];

  /// Current Firebase user
  User? get currentUser => _auth.currentUser;

  /// Auth state stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  String _normalizePhone(String raw) => raw.replaceAll(RegExp(r'\D'), '');

  bool _isValidPhone10(String raw) => _normalizePhone(raw).length == 10;

  String _buildInitials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    return parts.map((w) => w[0].toUpperCase()).take(2).join();
  }

  List<UserModel> _sortFirmMembers(List<UserModel> members) {
    final sorted = List<UserModel>.from(members);
    sorted.sort((a, b) {
      const order = {'lawyer': 0, 'admin': 0, 'intern': 1};
      return (order[a.role] ?? 3).compareTo(order[b.role] ?? 3);
    });
    return sorted;
  }

  Future<void> _saveFirmMembersCache(List<UserModel> members) async {
    final payload = members.map((m) => m.toMap()).toList();
    await HiveService.saveSetting(_firmMembersCacheKey, payload);
    _firmMembersMemoryCache = members;
  }

  List<UserModel> _readFirmMembersCache() {
    if (_firmMembersMemoryCache.isNotEmpty) {
      return _firmMembersMemoryCache;
    }

    try {
      final raw = HiveService.getSetting(_firmMembersCacheKey);
      if (raw is! List) return const [];

      final members = raw
          .whereType<Map>()
          .map((e) => UserModel.fromMap(Map<String, dynamic>.from(e)))
          .toList();
      _firmMembersMemoryCache = members;
      return members;
    } catch (e) {
      debugPrint('Failed to read firm member cache: $e');
      return const [];
    }
  }

  bool _sameFirmMembers(List<UserModel> a, List<UserModel> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].uid != b[i].uid ||
          a[i].name != b[i].name ||
          a[i].role != b[i].role ||
          a[i].isActive != b[i].isActive ||
          a[i].approvalStatus != b[i].approvalStatus) {
        return false;
      }
    }
    return true;
  }

  // ══════════ REGISTER ══════════

  /// Register a new user with email/password
  /// Role must be: 'lawyer' or 'intern'
  Future<UserModel> register({
    required String name,
    required String email,
    required String password,
    required String role,
    String phone = '',
  }) async {
    final normalizedPhone = _normalizePhone(phone.trim());
    if (!_isValidPhone10(normalizedPhone)) {
      throw Exception('Phone number must be exactly 10 digits.');
    }

    // 1. Create Firebase Auth account
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password.trim(),
    );

    final uid = credential.user!.uid;

    // Immediately cache the real name into the Auth Profile so offline fallbacks
    // don't resort to splitting the email if Firestore is unreachable later.
    try {
      await credential.user!.updateDisplayName(name.trim());
    } catch (e) {
      debugPrint('Failed to set displayName on Firebase user: $e');
    }

    // 2. Build user model
    final user = UserModel(
      uid: uid,
      name: name.trim(),
      email: email.trim(),
      phone: normalizedPhone,
      role: role,
      approvalStatus: 'pending',
      isActive: false,
    );

    // 3. Write user to Firestore (Wait up to 10 seconds to ensure they are created in the cloud)
    try {
      await _db
          .collection('users')
          .doc(uid)
          .set(user.toMap())
          .timeout(const Duration(seconds: 10), onTimeout: () {
        throw Exception('Database connection timed out. Please check your internet or emulator setup.');
      });
    } catch (e) {
      debugPrint('Firestore user write during registration failed: $e');
      // If we completely failed to write the user to the cloud, the app shouldn't let them proceed 
      // because they will be invisible to everyone else.
      throw Exception('Failed to finalize registration in the cloud database. Error: $e');
    }

    try {
      await _db.collection('onboarding_requests').doc(uid).set({
        'uid': uid,
        'name': name.trim(),
        'email': email.trim(),
        'phone': normalizedPhone,
        'role': role,
        'status': 'pending',
        'requestedAt': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Failed to create onboarding request: $e');
      // Roll back partially created account to avoid "registered but invisible" users.
      try {
        await _db.collection('users').doc(uid).delete();
      } catch (_) {}
      try {
        await credential.user?.delete();
      } catch (_) {}
      throw Exception('Failed to submit onboarding request. Error: $e');
    }

    // 4. Always cache locally so app works immediately
    await HiveService.put(HiveService.userBox, 'current_user', user.toMap());

    return user;
  }

  Future<UserModel> loginAsAdmin(String email, String password) async {
    if (email.trim().toLowerCase() != kAdminEmail.toLowerCase() ||
        password != kAdminPassword) {
      throw Exception('Invalid admin credentials.');
    }

    UserCredential credential;
    try {
      credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
        try {
          credential = await _auth.createUserWithEmailAndPassword(
            email: email.trim(),
            password: password.trim(),
          );
        } on FirebaseAuthException catch (createError) {
          if (createError.code == 'email-already-in-use') {
            throw Exception(
              'Admin email already exists with a different password. '
              'Use the existing password or reset/delete this auth user in Firebase Console.'
            );
          }
          rethrow;
        }
      } else {
        rethrow;
      }
    }

    final uid = credential.user!.uid;
    final adminUser = UserModel(
      uid: uid,
      name: 'Platform Admin',
      email: email.trim(),
      role: 'admin',
      approvalStatus: 'approved',
      isActive: true,
    );

    await _db.collection('users').doc(uid).set(
          adminUser.toMap(),
          SetOptions(merge: true),
        );

    await HiveService.put(HiveService.userBox, 'current_user', adminUser.toMap());
    return adminUser;
  }

  // ══════════ LOGIN ══════════

  /// Login with email/password
  Future<UserModel> login(String email, String password) async {
    // 1. Authenticate with Firebase
    final credential = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password.trim(),
    );

    final uid = credential.user!.uid;

    // 2. Try to fetch user profile from Firestore, failing over safely to cache/phantom
    try {
      final doc = await _db.collection('users').doc(uid).get().timeout(const Duration(seconds: 8));
      if (doc.exists) {
        final map = Map<String, dynamic>.from(doc.data()!);
        map.putIfAbsent('uid', () => doc.id);
        final user = UserModel.fromMap(map);
        await _ensurePendingOnboardingRequest(user);
        await HiveService.put(HiveService.userBox, 'current_user', user.toMap());
        return user;
      }
    } catch (e) {
      debugPrint('Firestore fetch failed, trying local cache: $e');
    }

    // 3. Fallback: try local Hive cache
    final cached = getCachedUser();
    if (cached != null && cached.uid == uid) {
      return cached;
    }

    throw Exception('Profile not found for this account. Please sign in again after registration completes.');
  }

  // ══════════ CACHED USER ══════════

  /// Get the locally cached user (works offline)
  UserModel? getCachedUser() {
    final data = HiveService.get(HiveService.userBox, 'current_user');
    if (data == null) return null;
    return UserModel.fromMap(data);
  }

  // ══════════ LOGOUT ══════════

  /// Sign out and clear local data
  Future<void> logout() async {
    await NotificationService.unbindCurrentDeviceToken(
      uid: _auth.currentUser?.uid,
    );
    await _auth.signOut();
    await HiveService.clearAllData();
  }

  /// Permanently delete the current account and all related cloud data.
  Future<void> deleteOwnAccount() async {
    await _functions.httpsCallable('deleteOwnAccount').call();
  }

  // ══════════ FIRM MEMBERS ══════════

  /// Get all members of the firm (for team directory)
  Future<List<UserModel>> getFirmMembers() async {
    final cached = _readFirmMembersCache();
    Future<HttpsCallableResult<dynamic>> loadFromCallable() {
      return _functions
          .httpsCallable(
            'listFirmMembers',
            options: HttpsCallableOptions(
              timeout: const Duration(seconds: 15),
            ),
          )
          .call();
    }

    try {
      HttpsCallableResult<dynamic> result;
      try {
        result = await loadFromCallable();
      } on TimeoutException {
        // One retry helps when Cloud Functions is cold-starting.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        result = await loadFromCallable();
      }

      final data = result.data;
      if (data is! Map) return cached;
      final items = data['items'];
      if (items is! List) return cached;

      final members = items.map((raw) {
        try {
          final map = Map<String, dynamic>.from(raw as Map);
          return UserModel.fromMap(map);
        } catch (e) {
          debugPrint('Failed to parse firm member payload: $e');
          return null;
        }
      }).whereType<UserModel>().toList();

      final sorted = _sortFirmMembers(members);
      await _saveFirmMembersCache(sorted);
      return sorted;
    } catch (e) {
      debugPrint('Failed to load firm members from callable: $e');
      return cached;
    }
  }

  /// Real-time stream of all members of the firm
  Stream<List<UserModel>> watchFirmMembers() async* {
    final cached = _sortFirmMembers(_readFirmMembersCache());
    if (cached.isNotEmpty) {
      yield cached;
    }

    final firstFetch = _sortFirmMembers(await getFirmMembers());
    if (firstFetch.isNotEmpty && !_sameFirmMembers(firstFetch, cached)) {
      yield firstFetch;
    }

    var previous = firstFetch.isNotEmpty ? firstFetch : cached;
    while (true) {
      await Future.delayed(const Duration(seconds: 12));
      final next = _sortFirmMembers(await getFirmMembers());
      if (_sameFirmMembers(next, previous)) {
        continue;
      }
      previous = next;
      yield next;
    }
  }

  /// Get only lawyers
  Future<List<UserModel>> getLawyers() async {
    final snapshot = await _db
        .collection('users')
        .where('role', whereIn: ['lawyer', 'admin'])
        .get();

    return snapshot.docs.map((doc) {
      try {
        return UserModel.fromMap(doc.data());
      } catch (e) {
        return null;
      }
    }).whereType<UserModel>().toList();
  }

  /// Get only interns
  Future<List<UserModel>> getInterns() async {
    final snapshot = await _db
        .collection('users')
        .where('role', isEqualTo: 'intern')
        .get();

    return snapshot.docs.map((doc) {
      try {
        return UserModel.fromMap(doc.data());
      } catch (e) {
        return null;
      }
    }).whereType<UserModel>().toList();
  }

  /// Get team members (lawyers + interns, excluding clients)
  Future<List<UserModel>> getTeamMembers() async {
    final all = await getFirmMembers();
    return all.where((m) => m.isTeamMember).toList();
  }

  /// Return locally cached firm members immediately (memory/Hive), no network.
  List<UserModel> getCachedFirmMembers() {
    return _sortFirmMembers(_readFirmMembersCache());
  }

  // ══════════ USER PROFILE ══════════

  /// Update user profile
  Future<void> updateProfile({
    required String uid,
    String? name,
    String? phone,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) {
      final trimmedName = name.trim();
      updates['name'] = trimmedName;
      updates['initials'] = _buildInitials(trimmedName);
      // Keep Firebase Auth profile synced so login offline fallbacks don't revert
      try {
        await _auth.currentUser?.updateDisplayName(trimmedName);
      } catch (e) {
        debugPrint('Failed to update displayName on Firebase user: $e');
      }
    }
    if (phone != null) {
      final normalizedPhone = _normalizePhone(phone);
      if (!_isValidPhone10(normalizedPhone)) {
        throw Exception('Phone number must be exactly 10 digits.');
      }
      updates['phone'] = normalizedPhone;
      phone = normalizedPhone;
    }

    if (updates.isNotEmpty) {
      // 1. Update local cache FIRST so the UI feels instant
      final cached = getCachedUser();
      if (cached != null && cached.uid == uid) {
        final updated = cached.copyWith(name: name, phone: phone);
        await HiveService.put(
            HiveService.userBox, 'current_user', updated.toMap());
      }

      // 2. Fire-and-forget Firestore update (do not await, prevents UI hang offline)
      _db.collection('users').doc(uid).update(updates).catchError((e) {
        debugPrint('Profile update queued offline: $e');
      });
    }
  }

  /// Get a specific user by ID
  Future<UserModel?> getUserById(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    final map = Map<String, dynamic>.from(doc.data()!);
    map.putIfAbsent('uid', () => doc.id);
    return UserModel.fromMap(map);
  }

  Future<void> _ensurePendingOnboardingRequest(UserModel user) async {
    if (user.isAdmin || user.isApproved || user.isActive) return;

    try {
      final ref = _db.collection('onboarding_requests').doc(user.uid);
      final req = await ref.get();
      if (req.exists) return;

      await ref.set({
        'uid': user.uid,
        'name': user.name,
        'email': user.email,
        'phone': user.phone,
        'role': user.role,
        'status': 'pending',
        'requestedAt': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Failed ensuring onboarding request for ${user.uid}: $e');
    }
  }

  Future<void> _deleteDocumentRefsInBatches(
    List<DocumentReference<Map<String, dynamic>>> refs,
  ) async {
    if (refs.isEmpty) return;
    const chunkSize = 400;
    for (int i = 0; i < refs.length; i += chunkSize) {
      final chunk = refs.skip(i).take(chunkSize);
      final batch = _db.batch();
      for (final ref in chunk) {
        batch.delete(ref);
      }
      await batch.commit();
    }
  }

  void _collectStoragePathFromUrl(
    FirebaseStorage storage,
    String? url,
    Set<String> storagePaths,
  ) {
    final value = (url ?? '').trim();
    if (value.isEmpty) return;
    try {
      storagePaths.add(storage.refFromURL(value).fullPath);
    } catch (e) {
      debugPrint('Failed to parse storage URL for deletion: $e');
    }
  }

  Future<void> _collectFolderPaths(
    FirebaseStorage storage,
    String folderPath,
    Set<String> storagePaths,
  ) async {
    try {
      final listed = await storage.ref().child(folderPath).listAll();
      for (final item in listed.items) {
        storagePaths.add(item.fullPath);
      }
    } catch (e) {
      debugPrint('Failed to list storage folder $folderPath: $e');
    }
  }

  /// Permanently remove all data owned by the user and scrub membership from shared records.
  /// This must be called before deleting the Firebase Auth account.
  Future<void> deleteAllUserData(String uid) async {
    if (uid.trim().isEmpty) return;

    final storage = FirebaseStorage.instance;
    final storagePaths = <String>{};

    // 1) Owned cases + case documents in Storage.
    final ownedCases = await _db
        .collection('cases')
        .where('ownerUid', isEqualTo: uid)
        .get();

    for (final doc in ownedCases.docs) {
      final data = doc.data();
      final rawDocs = data['customDocuments'];

      if (rawDocs is List) {
        for (final entry in rawDocs.whereType<Map>()) {
          _collectStoragePathFromUrl(
            storage,
            entry['url'] as String?,
            storagePaths,
          );
        }
      }

      final cino = (data['cino'] as String? ?? '').trim();
      if (cino.isNotEmpty) {
        await _collectFolderPaths(storage, 'case_documents/$cino', storagePaths);
      }
    }

    await _deleteDocumentRefsInBatches(
      ownedCases.docs.map((d) => d.reference).toList(),
    );

    // 2) Remove user from shared case membership where they are not owner.
    final memberCases = await _db
        .collection('cases')
        .where('participantIds', arrayContains: uid)
        .get();

    for (final doc in memberCases.docs) {
      final ownerUid = (doc.data()['ownerUid'] as String? ?? '').trim();
      if (ownerUid == uid) continue;
      try {
        await doc.reference.update({
          'participantIds': FieldValue.arrayRemove([uid]),
          'assignedLawyerIds': FieldValue.arrayRemove([uid]),
          'assignedInternIds': FieldValue.arrayRemove([uid]),
          'assignedMemberIds': FieldValue.arrayRemove([uid]),
          'clientIds': FieldValue.arrayRemove([uid]),
        });
      } catch (e) {
        debugPrint('Failed to scrub user from case ${doc.id}: $e');
      }
    }

    // 3) Delete user-owned entities.
    final tasksOwned = await _db
        .collection('tasks')
        .where('createdBy', isEqualTo: uid)
        .get();
    await _deleteDocumentRefsInBatches(
      tasksOwned.docs.map((d) => d.reference).toList(),
    );

    final assignmentsOwned = await _db
        .collection('assignments')
        .where('createdBy', isEqualTo: uid)
        .get();
    await _deleteDocumentRefsInBatches(
      assignmentsOwned.docs.map((d) => d.reference).toList(),
    );

    final remindersOwned = await _db
        .collection('reminders')
        .where('createdBy', isEqualTo: uid)
        .get();
    await _deleteDocumentRefsInBatches(
      remindersOwned.docs.map((d) => d.reference).toList(),
    );

    final noticesOwned = await _db
        .collection('notices')
        .where('authorId', isEqualTo: uid)
        .get();
    await _deleteDocumentRefsInBatches(
      noticesOwned.docs.map((d) => d.reference).toList(),
    );

    final sosOwned = await _db
        .collection('sos_alerts')
        .where('sentBy', isEqualTo: uid)
        .get();
    await _deleteDocumentRefsInBatches(
      sosOwned.docs.map((d) => d.reference).toList(),
    );

    // 4) Scrub user membership from shared tasks/assignments they don't own.
    final memberTasks = await _db
        .collection('tasks')
        .where('participantIds', arrayContains: uid)
        .get();
    for (final doc in memberTasks.docs) {
      if ((doc.data()['createdBy'] ?? '').toString() == uid) continue;
      try {
        await doc.reference.update({
          'participantIds': FieldValue.arrayRemove([uid]),
          'assignedJuniorIds': FieldValue.arrayRemove([uid]),
        });
      } catch (e) {
        debugPrint('Failed to scrub user from task ${doc.id}: $e');
      }
    }

    final assignmentRefs = <DocumentReference<Map<String, dynamic>>>{};
    final memberAssignments = await _db
        .collection('assignments')
        .where('participantIds', arrayContains: uid)
        .get();
    assignmentRefs.addAll(memberAssignments.docs.map((d) => d.reference));

    final assignedToMany = await _db
        .collection('assignments')
        .where('assignedToIds', arrayContains: uid)
        .get();
    assignmentRefs.addAll(assignedToMany.docs.map((d) => d.reference));

    final assignedToSingle = await _db
        .collection('assignments')
        .where('assignedToId', isEqualTo: uid)
        .get();
    assignmentRefs.addAll(assignedToSingle.docs.map((d) => d.reference));

    for (final ref in assignmentRefs) {
      try {
        final snap = await ref.get();
        if (!snap.exists) continue;
        final data = snap.data()!;
        if ((data['createdBy'] ?? '').toString() == uid) continue;

        final updates = <String, dynamic>{
          'participantIds': FieldValue.arrayRemove([uid]),
          'assignedToIds': FieldValue.arrayRemove([uid]),
        };
        if ((data['assignedToId'] ?? '').toString() == uid) {
          updates['assignedToId'] = '';
        }
        await ref.update(updates);
      } catch (e) {
        debugPrint('Failed to scrub user from assignment ${ref.id}: $e');
      }
    }

    // 5) Delete chat messages sent by this user and collect their attachment files.
    try {
      final myMessages = await _db
          .collectionGroup('messages')
          .where('senderId', isEqualTo: uid)
          .get();

      for (final msg in myMessages.docs) {
        _collectStoragePathFromUrl(
          storage,
          msg.data()['attachmentUrl'] as String?,
          storagePaths,
        );
      }

      await _deleteDocumentRefsInBatches(
        myMessages.docs.map((d) => d.reference).toList(),
      );
    } catch (e) {
      debugPrint('Failed to delete user messages: $e');
    }

    // 6) Remove user from chat groups. Delete groups only if they become empty.
    final groups = await _db
        .collection('chatGroups')
        .where('memberIds', arrayContains: uid)
        .get();

    for (final doc in groups.docs) {
      final data = doc.data();
      final memberIds = List<String>.from(data['memberIds'] ?? const []);

      if (memberIds.length <= 1) {
        try {
          await _collectFolderPaths(storage, 'chat_attachments/${doc.id}', storagePaths);
          final messages = await doc.reference.collection('messages').get();
          await _deleteDocumentRefsInBatches(
            messages.docs.map((m) => m.reference).toList(),
          );
          await doc.reference.delete();
        } catch (e) {
          debugPrint('Failed to delete chat group ${doc.id}: $e');
        }
        continue;
      }

      final updates = <String, dynamic>{
        'memberIds': FieldValue.arrayRemove([uid]),
        'participantIds': FieldValue.arrayRemove([uid]),
      };
      if ((data['createdBy'] ?? '').toString() == uid) {
        updates['createdBy'] = '';
        updates['createdByName'] = 'Deleted User';
      }

      try {
        await doc.reference.update(updates);
      } catch (e) {
        debugPrint('Failed to update chat membership ${doc.id}: $e');
      }
    }

    // 7) Delete collected storage files.
    for (final path in storagePaths) {
      try {
        await storage.ref().child(path).delete();
      } catch (e) {
        debugPrint('Failed to delete storage file $path: $e');
      }
    }

    // 8) Remove user profile document.
    try {
      await _db.collection('users').doc(uid).delete();
    } catch (e) {
      debugPrint('Failed to delete user profile doc: $e');
      rethrow;
    }
  }

  /// Delete all owned cases and their case documents from cloud storage.
  /// Backward-compatible alias.
  Future<void> deleteOwnedCaseData(String uid) async {
    await deleteAllUserData(uid);
  }

}