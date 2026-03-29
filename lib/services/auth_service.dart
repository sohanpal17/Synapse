import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import 'hive_service.dart';

/// Handles authentication and user management
/// Single firm model — all users belong to firm "synapse_default"
class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Current Firebase user
  User? get currentUser => _auth.currentUser;

  /// Auth state stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // ══════════ REGISTER ══════════

  /// Register a new user with email/password
  /// Role must be: 'lawyer', 'intern', or 'client'
  Future<UserModel> register({
    required String name,
    required String email,
    required String password,
    required String role,
    String phone = '',
  }) async {
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
      phone: phone.trim(),
      role: role,
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

    // 4. Always cache locally so app works immediately
    await HiveService.put(HiveService.userBox, 'current_user', user.toMap());

    return user;
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
        final user = UserModel.fromMap(doc.data()!);
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
    await _auth.signOut();
    await HiveService.clearAllData();
  }

  // ══════════ FIRM MEMBERS ══════════

  /// Get all members of the firm (for team directory)
  Future<List<UserModel>> getFirmMembers() async {
    final snapshot = await _db.collection('users').get();
    
    final members = snapshot.docs.map((doc) {
      try {
        return UserModel.fromMap(doc.data());
      } catch (e) {
        debugPrint('Failed to parse user ${doc.id}: $e');
        return null;
      }
    }).whereType<UserModel>().toList();
    
    // Sort: lawyers first, then interns, then clients
    members.sort((a, b) {
      const order = {'lawyer': 0, 'intern': 1, 'client': 2};
      return (order[a.role] ?? 3).compareTo(order[b.role] ?? 3);
    });

    return members;
  }

  /// Real-time stream of all members of the firm
  Stream<List<UserModel>> watchFirmMembers() {
    return _db.collection('users').snapshots().map((snapshot) {
      final members = snapshot.docs.map((doc) {
        try {
          return UserModel.fromMap(doc.data());
        } catch (e) {
          debugPrint('Failed to parse user ${doc.id}: $e');
          return null;
        }
      }).whereType<UserModel>().toList();
      
      members.sort((a, b) {
        const order = {'lawyer': 0, 'intern': 1, 'client': 2};
        return (order[a.role] ?? 3).compareTo(order[b.role] ?? 3);
      });
      
      return members;
    });
  }

  /// Get only lawyers
  Future<List<UserModel>> getLawyers() async {
    final snapshot = await _db
        .collection('users')
        .where('role', isEqualTo: 'lawyer')
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

  // ══════════ USER PROFILE ══════════

  /// Update user profile
  Future<void> updateProfile({
    required String uid,
    String? name,
    String? phone,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) {
      updates['name'] = name;
      // Keep Firebase Auth profile synced so login offline fallbacks don't revert
      try {
        await _auth.currentUser?.updateDisplayName(name.trim());
      } catch (e) {
        debugPrint('Failed to update displayName on Firebase user: $e');
      }
    }
    if (phone != null) updates['phone'] = phone;

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
    return UserModel.fromMap(doc.data()!);
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