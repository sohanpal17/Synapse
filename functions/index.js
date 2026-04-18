const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();
const ADMIN_EMAIL = 'try1@gmail.com';

function chunk(array, size) {
  const out = [];
  for (let i = 0; i < array.length; i += size) {
    out.push(array.slice(i, i + size));
  }
  return out;
}

function uniqueNonEmptyStrings(values) {
  return Array.from(
    new Set(
      (Array.isArray(values) ? values : [])
        .map((v) => (typeof v === 'string' ? v.trim() : String(v || '').trim()))
        .filter(Boolean)
    )
  );
}

async function getUserIdsByRole(role) {
  const snap = await db.collection('users').where('role', '==', role).get();
  return uniqueNonEmptyStrings(snap.docs.map((d) => d.id));
}

async function getAdminUserIds() {
  const roleAdmins = await getUserIdsByRole('admin');
  if (roleAdmins.length > 0) return roleAdmins;

  const emailAdmins = await db
    .collection('users')
    .where('email', '==', ADMIN_EMAIL)
    .limit(10)
    .get();

  return uniqueNonEmptyStrings(emailAdmins.docs.map((d) => d.id));
}

async function getAllUserIds() {
  const snap = await db.collection('users').get();
  return uniqueNonEmptyStrings(snap.docs.map((d) => d.id));
}

async function getUsersByIds(userIds) {
  const ids = uniqueNonEmptyStrings(userIds);
  if (ids.length === 0) return [];
  const users = [];
  for (const batchIds of chunk(ids, 300)) {
    const refs = batchIds.map((uid) => db.collection('users').doc(uid));
    const snapshots = await db.getAll(...refs);
    for (const snap of snapshots) {
      if (!snap.exists) continue;
      users.push({uid: snap.id, data: snap.data() || {}});
    }
  }
  return users;
}

async function sendPushToUsers({
  title,
  body,
  type,
  userIds,
  excludeUserIds = [],
  data = {},
}) {
  const excluded = new Set(uniqueNonEmptyStrings(excludeUserIds));
  const targets = uniqueNonEmptyStrings(userIds).filter((uid) => !excluded.has(uid));
  if (targets.length === 0) return {successCount: 0, failureCount: 0};

  const users = await getUsersByIds(targets);
  const tokenEntries = [];
  for (const u of users) {
    const tokens = uniqueNonEmptyStrings(u.data.fcmTokens || []);
    for (const token of tokens) {
      tokenEntries.push({uid: u.uid, token});
    }
  }

  if (tokenEntries.length === 0) return {successCount: 0, failureCount: 0};

  const tokens = tokenEntries.map((t) => t.token);
  const dataPayload = {};
  for (const [k, v] of Object.entries(data)) {
    dataPayload[k] = typeof v === 'string' ? v : JSON.stringify(v ?? '');
  }
  dataPayload.type = type;

  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: {title, body},
    data: dataPayload,
    android: {
      priority: 'high',
      ttl: type === 'sos' ? 14400000 : 86400000, // 4h for SOS, 24h for normal (in ms)
      notification: {
        channelId: type === 'sos' ? 'synapse_sos_v10' : 'synapse_main',
        priority: type === 'sos' ? 'max' : 'high',
        sound: type === 'sos' ? undefined : 'default',
        defaultSound: type !== 'sos',
        defaultVibrateTimings: type !== 'sos',
        vibrateTimingsMillis: type === 'sos' ? [0, 3000] : undefined,
      },
    },
    apns: {
      payload: {
        aps: {
          sound: type === 'sos' ? undefined : 'default',
          'content-available': 1,
        },
      },
      headers: {
        'apns-priority': '10',
        'apns-expiration': String(Math.floor(Date.now() / 1000) + (type === 'sos' ? 14400 : 86400)),
      },
    },
    webpush: {
      notification: {
        title,
        body,
        icon: '/icons/Icon-192.png',
        requireInteraction: type === 'sos',
      },
      fcmOptions: {link: '/'},
      headers: {Urgency: 'high', TTL: type === 'sos' ? '14400' : '86400'},
    },
  });

  const invalidByUid = new Map();
  response.responses.forEach((r, idx) => {
    if (r.success) return;
    const code = r.error && r.error.code ? r.error.code : 'unknown';
    if (
      code === 'messaging/invalid-registration-token' ||
      code === 'messaging/registration-token-not-registered'
    ) {
      const entry = tokenEntries[idx];
      if (!entry) return;
      const arr = invalidByUid.get(entry.uid) || [];
      arr.push(entry.token);
      invalidByUid.set(entry.uid, arr);
    }
  });

  if (invalidByUid.size > 0) {
    const updates = [];
    for (const [uid, badTokens] of invalidByUid.entries()) {
      updates.push(
        db.collection('users').doc(uid).update({
          fcmTokens: admin.firestore.FieldValue.arrayRemove(...badTokens),
        })
      );
    }
    await Promise.allSettled(updates);
  }

  return {
    successCount: response.successCount,
    failureCount: response.failureCount,
  };
}

exports.onSosAlertCreated = functions
  .region('asia-south1')
  .firestore
  .document('sos_alerts/{sosId}')
  .onCreate(async (snap, context) => {
  const data = snap.exists ? snap.data() : null;
  if (!data) return;

  if (data.pushRequested === false) {
    functions.logger.info('SOS push skipped: pushRequested=false', {sosId: context.params.sosId});
    return;
  }

  const recipientIds = Array.isArray(data.recipientIds) ? data.recipientIds.filter(Boolean) : [];
  if (recipientIds.length === 0) {
    functions.logger.info('SOS push skipped: no recipients', {sosId: context.params.sosId});
    return;
  }

  const sender = String(data.sentByName || 'Team member');
  const caseName = String(data.caseName || 'Case');
  const courtRoom = String(data.courtRoom || 'Courtroom');
  const response = await sendPushToUsers({
    title: 'SOS ALERT',
    body: `${sender} needs help in ${courtRoom} (${caseName})`,
    type: 'sos',
    userIds: recipientIds,
    excludeUserIds: [String(data.sentBy || '')],
    data: {
      sosId: String(data.id || context.params.sosId),
      caseId: String(data.caseId || ''),
      caseName,
      courtRoom,
      sentBy: String(data.sentBy || ''),
      sentByName: sender,
      timestamp: String(data.timestamp || ''),
    },
  });

  functions.logger.info('SOS push sent', {
    sosId: context.params.sosId,
    recipients: recipientIds.length,
    success: response.successCount,
    failed: response.failureCount,
  });
});

exports.onMessageCreated = functions
  .region('asia-south1')
  .firestore
  .document('chatGroups/{groupId}/messages/{messageId}')
  .onCreate(async (snap, context) => {
    const message = snap.data() || {};
    const groupId = context.params.groupId;
    const groupDoc = await db.collection('chatGroups').doc(groupId).get();
    if (!groupDoc.exists) return;

    const group = groupDoc.data() || {};
    const memberIds = uniqueNonEmptyStrings(group.memberIds || []);
    const senderId = String(message.senderId || '');
    if (memberIds.length === 0) return;

    const senderName = String(message.senderName || 'Team member');
    const groupName = String(group.name || group.title || 'Team Chat');
    const content = String(message.content || '').trim();
    const body = content.isNotEmpty
      ? `${senderName}: ${content.length > 80 ? `${content.substring(0, 80)}...` : content}`
      : `${senderName} sent an attachment in ${groupName}`;

    const response = await sendPushToUsers({
      title: groupName,
      body,
      type: 'message',
      userIds: memberIds,
      excludeUserIds: [senderId],
      data: {
        chatGroupId: groupId,
        messageId: String(message.id || context.params.messageId),
        senderId,
        senderName,
      },
    });

    functions.logger.info('Message push sent', {
      groupId,
      messageId: context.params.messageId,
      recipients: memberIds.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

exports.onTaskCreated = functions
  .region('asia-south1')
  .firestore
  .document('tasks/{taskId}')
  .onCreate(async (snap, context) => {
    const task = snap.data() || {};
    const createdBy = String(task.createdBy || '');
    const title = String(task.title || 'Task');

    const recipientIds = uniqueNonEmptyStrings([
      ...(Array.isArray(task.participantIds) ? task.participantIds : []),
      ...(Array.isArray(task.assignedJuniorIds) ? task.assignedJuniorIds : []),
      String(task.assignedToId || ''),
      ...(Array.isArray(task.assignedToIds) ? task.assignedToIds : []),
    ]);

    const response = await sendPushToUsers({
      title: 'New Task Assigned',
      body: title,
      type: 'task',
      userIds: recipientIds,
      excludeUserIds: [createdBy],
      data: {
        taskId: String(task.id || context.params.taskId),
        caseId: String(task.caseId || ''),
        createdBy,
      },
    });

    functions.logger.info('Task push sent', {
      taskId: context.params.taskId,
      recipients: recipientIds.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

exports.onTaskUpdated = functions
  .region('asia-south1')
  .firestore
  .document('tasks/{taskId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const becameEscalated = before.isEscalated !== true && after.isEscalated === true;
    const becameOverdue = String(before.status || '') !== 'overdue' && String(after.status || '') === 'overdue';
    if (!becameEscalated && !becameOverdue) {
      return;
    }

    const creator = String(after.createdBy || '');
    const title = String(after.title || 'Task');
    const lawyers = await getUserIdsByRole('lawyer');
    const interns = await getUserIdsByRole('intern');
    const recipients = uniqueNonEmptyStrings([...lawyers, ...interns]);

    const response = await sendPushToUsers({
      title: 'Task Escalated',
      body: `${title} is now overdue and escalated.`,
      type: 'escalation',
      userIds: recipients,
      excludeUserIds: [],
      data: {
        taskId: String(after.id || context.params.taskId),
        caseId: String(after.caseId || ''),
        createdBy: creator,
      },
    });

    functions.logger.info('Escalation push sent', {
      taskId: context.params.taskId,
      recipients: recipients.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

exports.onAssignmentCreated = functions
  .region('asia-south1')
  .firestore
  .document('assignments/{assignmentId}')
  .onCreate(async (snap, context) => {
    const assignment = snap.data() || {};
    const createdBy = String(assignment.createdBy || '');
    const title = String(assignment.title || 'Assignment');

    const recipientIds = uniqueNonEmptyStrings([
      ...(Array.isArray(assignment.participantIds) ? assignment.participantIds : []),
      ...(Array.isArray(assignment.assignedToIds) ? assignment.assignedToIds : []),
      String(assignment.assignedToId || ''),
    ]);

    const response = await sendPushToUsers({
      title: 'New Assignment',
      body: title,
      type: 'assignment',
      userIds: recipientIds,
      excludeUserIds: [createdBy],
      data: {
        assignmentId: String(assignment.id || context.params.assignmentId),
        caseId: String(assignment.caseId || ''),
        createdBy,
      },
    });

    functions.logger.info('Assignment push sent', {
      assignmentId: context.params.assignmentId,
      recipients: recipientIds.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

exports.onAssignmentUpdated = functions
  .region('asia-south1')
  .firestore
  .document('assignments/{assignmentId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};

    const beforeStatus = String(before.status || '');
    const afterStatus = String(after.status || '');
    if (!afterStatus || beforeStatus === afterStatus) {
      return;
    }

    const title = String(after.title || 'Assignment');
    const recipientIds = uniqueNonEmptyStrings([
      ...(Array.isArray(after.participantIds) ? after.participantIds : []),
      ...(Array.isArray(after.assignedToIds) ? after.assignedToIds : []),
      String(after.assignedToId || ''),
      String(after.createdBy || ''),
    ]);

    const response = await sendPushToUsers({
      title: 'Assignment Updated',
      body: `${title} marked as ${afterStatus}.`,
      type: 'assignment',
      userIds: recipientIds,
      excludeUserIds: [],
      data: {
        assignmentId: String(after.id || context.params.assignmentId),
        caseId: String(after.caseId || ''),
        status: afterStatus,
      },
    });

    functions.logger.info('Assignment update push sent', {
      assignmentId: context.params.assignmentId,
      status: afterStatus,
      recipients: recipientIds.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

exports.onReminderCreated = functions
  .region('asia-south1')
  .firestore
  .document('reminders/{reminderId}')
  .onCreate(async (snap, context) => {
    const reminder = snap.data() || {};
    const createdBy = String(reminder.createdBy || '');
    const title = String(reminder.title || 'Reminder');
    const visibility = String(reminder.visibility || 'private');

    let recipientIds = [];
    if (visibility === 'lawyers') {
      recipientIds = await getUserIdsByRole('lawyer');
    } else if (visibility === 'interns') {
      recipientIds = await getUserIdsByRole('intern');
    } else if (visibility === 'specificUsers') {
      recipientIds = uniqueNonEmptyStrings(reminder.sharedWithUserIds || []);
    } else if (visibility === 'everyone') {
      recipientIds = await getAllUserIds();
    } else {
      // private reminder: no team push
      recipientIds = [];
    }

    if (recipientIds.length === 0) return;

    const response = await sendPushToUsers({
      title: 'New Reminder',
      body: title,
      type: 'reminder',
      userIds: recipientIds,
      excludeUserIds: [createdBy],
      data: {
        reminderId: String(reminder.id || context.params.reminderId),
        createdBy,
        visibility,
      },
    });

    functions.logger.info('Reminder push sent', {
      reminderId: context.params.reminderId,
      recipients: recipientIds.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

exports.onOnboardingRequestCreated = functions
  .region('asia-south1')
  .firestore
  .document('onboarding_requests/{requestId}')
  .onCreate(async (snap, context) => {
    const req = snap.data() || {};
    const status = String(req.status || '').trim().toLowerCase();
    if (status && status !== 'pending') return;

    const adminIds = await getAdminUserIds();
    if (adminIds.length === 0) {
      functions.logger.info('No admin recipients for onboarding notification', {
        requestId: context.params.requestId,
      });
      return;
    }

    const applicantName = String(req.name || 'New user').trim() || 'New user';
    const applicantRole = String(req.role || 'member').trim() || 'member';

    const response = await sendPushToUsers({
      title: 'New Onboarding Request',
      body: `${applicantName} (${applicantRole}) is waiting for approval.`,
      type: 'onboarding_request',
      userIds: adminIds,
      data: {
        requestId: String(context.params.requestId || ''),
        targetUid: String(req.uid || context.params.requestId || ''),
        applicantName,
        applicantRole,
      },
    });

    functions.logger.info('Onboarding request notification sent', {
      requestId: context.params.requestId,
      recipients: adminIds.length,
      success: response.successCount,
      failed: response.failureCount,
    });
  });

async function assertAdminCaller(context) {
  const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
  if (!callerUid) {
    throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
  }

  const callerDoc = await db.collection('users').doc(callerUid).get();
  const callerData = callerDoc.exists ? callerDoc.data() || {} : {};
  if (String(callerData.role || '').toLowerCase() !== 'admin') {
    const callerEmail = String((context.auth && context.auth.token && context.auth.token.email) || '').toLowerCase();
    if (callerEmail !== ADMIN_EMAIL.toLowerCase()) {
      throw new functions.https.HttpsError('permission-denied', 'Admin access required.');
    }

    // Self-heal admin profile for environments where Firestore rules blocked bootstrap.
    await db.collection('users').doc(callerUid).set(
      {
        uid: callerUid,
        email: callerEmail,
        name: String(callerData.name || 'Platform Admin'),
        role: 'admin',
        approvalStatus: 'approved',
        isActive: true,
      },
      {merge: true}
    );
  }
  return callerUid;
}

exports.adminListOnboardingRequests = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    await assertAdminCaller(context);

    const status = String((data && data.status) || 'pending').trim().toLowerCase();
    const rawLimit = Number((data && data.limit) || 200);
    const limit = Number.isFinite(rawLimit)
      ? Math.max(1, Math.min(500, Math.floor(rawLimit)))
      : 200;

    const snap = await db
      .collection('onboarding_requests')
      .where('status', '==', status)
      .limit(limit)
      .get();

    const items = snap.docs.map((doc) => {
      const d = doc.data() || {};
      return {
        id: doc.id,
        uid: String(d.uid || doc.id),
        name: String(d.name || ''),
        email: String(d.email || ''),
        phone: String(d.phone || ''),
        role: String(d.role || ''),
        status: String(d.status || ''),
        requestedAt: String(d.requestedAt || ''),
      };
    });

    // Safety net: include pending user profiles that missed onboarding_requests doc.
    if (status === 'pending') {
      const pendingUsersSnap = await db
        .collection('users')
        .where('approvalStatus', '==', 'pending')
        .where('isActive', '==', false)
        .limit(limit)
        .get();

      const existingUids = new Set(items.map((x) => String(x.uid || '')));
      for (const doc of pendingUsersSnap.docs) {
        const d = doc.data() || {};
        const rowUid = String(d.uid || doc.id);
        if (!rowUid || existingUids.has(rowUid)) continue;
        items.push({
          id: rowUid,
          uid: rowUid,
          name: String(d.name || ''),
          email: String(d.email || ''),
          phone: String(d.phone || ''),
          role: String(d.role || ''),
          status: 'pending',
          requestedAt: String(d.createdAt || ''),
        });
      }
    }

    items.sort((a, b) => String(b.requestedAt).localeCompare(String(a.requestedAt)));
    return {ok: true, items};
  });

exports.listFirmMembers = functions
  .region('asia-south1')
  .https.onCall(async (_data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    let snap;
    try {
      // Include only internal app roles.
      snap = await db.collection('users').where('role', 'in', ['lawyer', 'intern', 'admin']).get();
    } catch (e) {
      // Fallback for environments where role values are inconsistent.
      functions.logger.warn('listFirmMembers role-filter query failed, falling back to full scan', {
        error: String(e),
      });
      snap = await db.collection('users').get();
    }

    const items = snap.docs
      .map((doc) => {
        const d = doc.data() || {};
        const rawStatus = String(d.approvalStatus || '').trim().toLowerCase();
        const rawActive = d.isActive;
        const isApproved = rawStatus === '' || rawStatus === 'approved';
        const isActive =
          rawActive === undefined ||
          rawActive === null ||
          rawActive === true ||
          String(rawActive).toLowerCase() === 'true';
        return {
          uid: String(d.uid || doc.id),
          name: String(d.name || ''),
          email: String(d.email || ''),
          phone: String(d.phone || ''),
          role: String(d.role || ''),
          approvalStatus: rawStatus || 'approved',
          isActive,
          isApproved,
          initials: String(d.initials || ''),
          createdAt: String(d.createdAt || ''),
        };
      })
      .filter((u) => u.uid && u.isApproved === true && u.isActive === true)
      .map((u) => ({
        uid: u.uid,
        name: u.name,
        email: u.email,
        phone: u.phone,
        role: u.role,
        approvalStatus: u.approvalStatus,
        isActive: u.isActive,
        initials: u.initials,
        createdAt: u.createdAt,
      }));

    return {ok: true, items};
  });

exports.claimDeviceFcmToken = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const token = String((data && data.token) || '').trim();
    if (!token) {
      throw new functions.https.HttpsError('invalid-argument', 'token is required.');
    }

    const holdersSnap = await db
      .collection('users')
      .where('fcmTokens', 'array-contains', token)
      .get();

    const updates = [];
    for (const doc of holdersSnap.docs) {
      if (doc.id === callerUid) continue;
      updates.push(
        doc.ref.update({
          fcmTokens: admin.firestore.FieldValue.arrayRemove(token),
          fcmTokenUpdatedAt: new Date().toISOString(),
        })
      );
    }

    updates.push(
      db.collection('users').doc(callerUid).set(
        {
          fcmTokens: admin.firestore.FieldValue.arrayUnion(token),
          fcmTokenUpdatedAt: new Date().toISOString(),
        },
        {merge: true}
      )
    );

    await Promise.allSettled(updates);

    return {ok: true, uid: callerUid};
  });

exports.unclaimDeviceFcmToken = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const token = String((data && data.token) || '').trim();
    if (!token) {
      throw new functions.https.HttpsError('invalid-argument', 'token is required.');
    }

    await db.collection('users').doc(callerUid).set(
      {
        fcmTokens: admin.firestore.FieldValue.arrayRemove(token),
        fcmTokenUpdatedAt: new Date().toISOString(),
      },
      {merge: true}
    );

    return {ok: true, uid: callerUid};
  });

exports.updateCaseTeamMembers = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const cino = String((data && data.cino) || '').trim();
    const memberIds = uniqueNonEmptyStrings((data && data.memberIds) || []);
    const lawyerIds = uniqueNonEmptyStrings((data && data.lawyerIds) || []);
    const internIds = uniqueNonEmptyStrings((data && data.internIds) || []);
    if (!cino) {
      throw new functions.https.HttpsError('invalid-argument', 'cino is required.');
    }

    const callerDoc = await db.collection('users').doc(callerUid).get();
    const callerRole = String((callerDoc.exists ? callerDoc.data() || {} : {}).role || '').toLowerCase();
    const isCallerAdmin = callerRole === 'admin';

    const snap = await db.collection('cases').where('cino', '==', cino).limit(20).get();
    if (snap.empty) {
      throw new functions.https.HttpsError('not-found', 'Case not found.');
    }

    const targetDoc = snap.docs.find((doc) => {
      const d = doc.data() || {};
      const participants = uniqueNonEmptyStrings(d.participantIds || []);
      const ownerUid = String(d.ownerUid || '').trim();
      return isCallerAdmin || ownerUid === callerUid || participants.includes(callerUid);
    });

    if (!targetDoc) {
      throw new functions.https.HttpsError('permission-denied', 'Not allowed to manage this case team.');
    }

    const existing = targetDoc.data() || {};
    const ownerUid = String(existing.ownerUid || '').trim();
    const nextAssignedMembers = uniqueNonEmptyStrings(memberIds);
    const nextLawyerIds = uniqueNonEmptyStrings(lawyerIds.filter((id) => nextAssignedMembers.includes(id)));
    const nextInternIds = uniqueNonEmptyStrings(internIds.filter((id) => nextAssignedMembers.includes(id)));
    const nextParticipants = uniqueNonEmptyStrings([
      ownerUid,
      ...nextAssignedMembers,
    ]);

    await targetDoc.ref.set(
      {
        assignedLawyerIds: nextLawyerIds,
        assignedInternIds: nextInternIds,
        clientIds: [],
        assignedMemberIds: nextAssignedMembers,
        participantIds: nextParticipants,
        updatedAt: new Date().toISOString(),
      },
      {merge: true}
    );

    return {
      ok: true,
      cino,
      caseDocId: targetDoc.id,
      assignedCount: nextAssignedMembers.length,
    };
  });

async function sendModerationOutcomeNotification({targetUid, action, targetName = ''}) {
  if (!targetUid || (action !== 'approve' && action !== 'reject')) return;

  const normalizedName = String(targetName || '').trim();
  const nameLabel = normalizedName || 'there';
  const isApproved = action === 'approve';

  const title = isApproved ? 'Account Approved' : 'Account Request Rejected';
  const body = isApproved
    ? `Hi ${nameLabel}, your account request has been approved. You can now access the app.`
    : `Hi ${nameLabel}, your account request has been rejected by the admin.`;

  try {
    await sendPushToUsers({
      title,
      body,
      type: 'account_status',
      userIds: [targetUid],
      data: {
        targetUid,
        action,
      },
    });
  } catch (e) {
    functions.logger.warn('Failed to send moderation outcome notification', {
      targetUid,
      action,
      error: String(e),
    });
  }
}

async function deleteDocumentRefsInBatches(refs) {
  if (!Array.isArray(refs) || refs.length === 0) return;
  const chunkSize = 400;
  for (let i = 0; i < refs.length; i += chunkSize) {
    const chunk = refs.slice(i, i + chunkSize);
    const batch = db.batch();
    for (const ref of chunk) {
      batch.delete(ref);
    }
    await batch.commit();
  }
}

function storagePathFromUrl(url, bucketName) {
  const value = String(url || '').trim();
  if (!value) return '';

  if (value.startsWith('gs://')) {
    const withoutScheme = value.replace('gs://', '');
    const firstSlash = withoutScheme.indexOf('/');
    if (firstSlash === -1) return '';
    const bucket = withoutScheme.substring(0, firstSlash);
    if (bucket !== bucketName) return '';
    return decodeURIComponent(withoutScheme.substring(firstSlash + 1));
  }

  const marker = '/o/';
  const markerIndex = value.indexOf(marker);
  if (markerIndex === -1) return '';
  const tail = value.substring(markerIndex + marker.length);
  const queryIndex = tail.indexOf('?');
  const encodedPath = queryIndex === -1 ? tail : tail.substring(0, queryIndex);
  return decodeURIComponent(encodedPath);
}

function collectStoragePathFromUrl(url, storagePaths, bucketName) {
  const path = storagePathFromUrl(url, bucketName);
  if (path) storagePaths.add(path);
}

async function collectFolderPaths(bucket, prefix, storagePaths) {
  if (!prefix) return;
  try {
    const [files] = await bucket.getFiles({prefix});
    for (const file of files) {
      if (file && file.name) {
        storagePaths.add(file.name);
      }
    }
  } catch (e) {
    functions.logger.warn('Failed listing storage folder', {
      prefix,
      error: String(e),
    });
  }
}

async function deleteUserDataEverywhere(uid) {
  if (!uid) return;

  const bucket = admin.storage().bucket();
  const bucketName = bucket.name;
  const storagePaths = new Set();

  // Cases owned by user (and case docs in Storage)
  const ownedCases = await db.collection('cases').where('ownerUid', '==', uid).get();
  for (const doc of ownedCases.docs) {
    const data = doc.data() || {};
    const customDocs = Array.isArray(data.customDocuments) ? data.customDocuments : [];
    for (const entry of customDocs) {
      const item = entry && typeof entry === 'object' ? entry : {};
      collectStoragePathFromUrl(item.url, storagePaths, bucketName);
    }
    const cino = String(data.cino || '').trim();
    if (cino) {
      await collectFolderPaths(bucket, `case_documents/${cino}`, storagePaths);
    }
  }
  await deleteDocumentRefsInBatches(ownedCases.docs.map((d) => d.ref));

  // Remove user from shared case membership
  const memberCases = await db.collection('cases').where('participantIds', 'array-contains', uid).get();
  for (const doc of memberCases.docs) {
    const data = doc.data() || {};
    if (String(data.ownerUid || '').trim() === uid) continue;
    await doc.ref.set(
      {
        participantIds: admin.firestore.FieldValue.arrayRemove(uid),
        assignedLawyerIds: admin.firestore.FieldValue.arrayRemove(uid),
        assignedInternIds: admin.firestore.FieldValue.arrayRemove(uid),
        assignedMemberIds: admin.firestore.FieldValue.arrayRemove(uid),
        clientIds: admin.firestore.FieldValue.arrayRemove(uid),
      },
      {merge: true}
    );
  }

  // Delete owned entities
  const [ownedTasks, ownedAssignments, ownedReminders, ownedNotices, ownedSos] = await Promise.all([
    db.collection('tasks').where('createdBy', '==', uid).get(),
    db.collection('assignments').where('createdBy', '==', uid).get(),
    db.collection('reminders').where('createdBy', '==', uid).get(),
    db.collection('notices').where('authorId', '==', uid).get(),
    db.collection('sos_alerts').where('sentBy', '==', uid).get(),
  ]);

  await Promise.all([
    deleteDocumentRefsInBatches(ownedTasks.docs.map((d) => d.ref)),
    deleteDocumentRefsInBatches(ownedAssignments.docs.map((d) => d.ref)),
    deleteDocumentRefsInBatches(ownedReminders.docs.map((d) => d.ref)),
    deleteDocumentRefsInBatches(ownedNotices.docs.map((d) => d.ref)),
    deleteDocumentRefsInBatches(ownedSos.docs.map((d) => d.ref)),
  ]);

  // Scrub user from shared tasks
  const memberTasks = await db.collection('tasks').where('participantIds', 'array-contains', uid).get();
  for (const doc of memberTasks.docs) {
    const data = doc.data() || {};
    if (String(data.createdBy || '') === uid) continue;
    const updates = {
      participantIds: admin.firestore.FieldValue.arrayRemove(uid),
      assignedJuniorIds: admin.firestore.FieldValue.arrayRemove(uid),
      assignedToIds: admin.firestore.FieldValue.arrayRemove(uid),
    };
    if (String(data.assignedToId || '') === uid) {
      updates.assignedToId = '';
    }
    await doc.ref.set(updates, {merge: true});
  }

  // Scrub user from shared assignments
  const assignmentRefMap = new Map();
  const assignmentSnaps = await Promise.all([
    db.collection('assignments').where('participantIds', 'array-contains', uid).get(),
    db.collection('assignments').where('assignedToIds', 'array-contains', uid).get(),
    db.collection('assignments').where('assignedToId', '==', uid).get(),
  ]);
  for (const snap of assignmentSnaps) {
    for (const doc of snap.docs) {
      assignmentRefMap.set(doc.id, doc.ref);
    }
  }
  for (const ref of assignmentRefMap.values()) {
    const snap = await ref.get();
    if (!snap.exists) continue;
    const data = snap.data() || {};
    if (String(data.createdBy || '') === uid) continue;
    const updates = {
      participantIds: admin.firestore.FieldValue.arrayRemove(uid),
      assignedToIds: admin.firestore.FieldValue.arrayRemove(uid),
    };
    if (String(data.assignedToId || '') === uid) {
      updates.assignedToId = '';
    }
    await ref.set(updates, {merge: true});
  }

  // Delete all messages sent by this user and collect attachment paths
  try {
    const myMessages = await db.collectionGroup('messages').where('senderId', '==', uid).get();
    for (const msg of myMessages.docs) {
      const data = msg.data() || {};
      collectStoragePathFromUrl(data.attachmentUrl, storagePaths, bucketName);
    }
    await deleteDocumentRefsInBatches(myMessages.docs.map((d) => d.ref));
  } catch (e) {
    functions.logger.warn('Failed deleting user messages', {uid, error: String(e)});
  }

  // Remove user from chat groups (delete empty groups)
  const groups = await db.collection('chatGroups').where('memberIds', 'array-contains', uid).get();
  for (const doc of groups.docs) {
    const data = doc.data() || {};
    const memberIds = uniqueNonEmptyStrings(data.memberIds || []);
    if (memberIds.length <= 1) {
      await collectFolderPaths(bucket, `chat_attachments/${doc.id}`, storagePaths);
      const messages = await doc.ref.collection('messages').get();
      for (const msg of messages.docs) {
        const msgData = msg.data() || {};
        collectStoragePathFromUrl(msgData.attachmentUrl, storagePaths, bucketName);
      }
      await deleteDocumentRefsInBatches(messages.docs.map((m) => m.ref));
      await doc.ref.delete();
      continue;
    }

    const updates = {
      memberIds: admin.firestore.FieldValue.arrayRemove(uid),
      participantIds: admin.firestore.FieldValue.arrayRemove(uid),
    };
    if (String(data.createdBy || '') === uid) {
      updates.createdBy = '';
      updates.createdByName = 'Deleted User';
    }
    await doc.ref.set(updates, {merge: true});
  }

  // Remove onboarding artifacts + user profile
  await Promise.allSettled([
    db.collection('onboarding_requests').doc(uid).delete(),
    db.collection('users').doc(uid).delete(),
  ]);

  // Best-effort storage cleanup
  for (const path of storagePaths.values()) {
    try {
      await bucket.file(path).delete({ignoreNotFound: true});
    } catch (e) {
      functions.logger.warn('Failed deleting storage file', {
        uid,
        path,
        error: String(e),
      });
    }
  }
}

async function deleteAuthUserOrThrow(targetUid, contextLabel) {
  try {
    await admin.auth().deleteUser(targetUid);
  } catch (e) {
    const code = String((e && e.code) || '').toLowerCase();
    if (code === 'auth/user-not-found') {
      return;
    }

    functions.logger.error('Failed to delete auth user', {
      targetUid,
      contextLabel,
      error: String(e),
    });
    throw new functions.https.HttpsError(
      'internal',
      'Failed to fully delete account from authentication.'
    );
  }
}

exports.adminModerateUser = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = await assertAdminCaller(context);
    const action = String((data && data.action) || '').trim().toLowerCase();
    const targetUid = String((data && data.targetUid) || '').trim();

    if (!targetUid) {
      throw new functions.https.HttpsError('invalid-argument', 'targetUid is required.');
    }

    if ((action === 'delete' || action === 'reject') && targetUid === callerUid) {
      throw new functions.https.HttpsError('failed-precondition', 'Admin cannot remove own account.');
    }

    const userRef = db.collection('users').doc(targetUid);
    const requestRef = db.collection('onboarding_requests').doc(targetUid);
    const targetUserDoc = await userRef.get();
    const targetUserData = targetUserDoc.exists ? targetUserDoc.data() || {} : {};
    const targetName = String(targetUserData.name || '').trim();

    if (action === 'approve') {
      await userRef.set(
        {
          approvalStatus: 'approved',
          isActive: true,
          approvedAt: admin.firestore.FieldValue.serverTimestamp(),
          approvedBy: callerUid,
        },
        {merge: true}
      );

      await requestRef.set(
        {
          uid: targetUid,
          status: 'approved',
          processedAt: admin.firestore.FieldValue.serverTimestamp(),
          processedBy: callerUid,
        },
        {merge: true}
      );

      await sendModerationOutcomeNotification({
        targetUid,
        action,
        targetName,
      });

      return {ok: true, action, targetUid};
    }

    if (action === 'reject') {
      await sendModerationOutcomeNotification({
        targetUid,
        action,
        targetName,
      });

      await requestRef.set(
        {
          uid: targetUid,
          status: 'rejected',
          processedAt: admin.firestore.FieldValue.serverTimestamp(),
          processedBy: callerUid,
        },
        {merge: true}
      );

      await userRef.delete();
      await deleteAuthUserOrThrow(targetUid, 'reject');

      return {ok: true, action, targetUid};
    }

    if (action === 'delete') {
      await deleteUserDataEverywhere(targetUid);

      await deleteAuthUserOrThrow(targetUid, 'delete');

      return {ok: true, action, targetUid};
    }

    throw new functions.https.HttpsError('invalid-argument', 'Unsupported action.');
  });

exports.deleteOwnAccount = functions
  .region('asia-south1')
  .https.onCall(async (_data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    await deleteUserDataEverywhere(callerUid);
    await deleteAuthUserOrThrow(callerUid, 'self-delete');

    return {ok: true, uid: callerUid};
  });

function normalizeWorkStatus(raw) {
  const status = String(raw || '').trim().toLowerCase();
  if (status === 'completed' || status === 'complete' || status === 'done' || status === 'closed') {
    return 'completed';
  }
  return 'inProgress';
}

exports.updateTaskStatus = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const taskId = String((data && data.taskId) || '').trim();
    const status = normalizeWorkStatus(data && data.status);
    if (!taskId) {
      throw new functions.https.HttpsError('invalid-argument', 'taskId is required.');
    }

    const ref = db.collection('tasks').doc(taskId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new functions.https.HttpsError('not-found', 'Task not found.');
    }

    const task = snap.data() || {};
    const isCreator = String(task.createdBy || '') === callerUid;
    const isParticipant = uniqueNonEmptyStrings(task.participantIds || []).includes(callerUid);
    const isAssigned = uniqueNonEmptyStrings([
      ...(Array.isArray(task.assignedJuniorIds) ? task.assignedJuniorIds : []),
      ...(Array.isArray(task.assignedToIds) ? task.assignedToIds : []),
      String(task.assignedToId || ''),
    ]).includes(callerUid);

    if (!isCreator && !isParticipant && !isAssigned) {
      throw new functions.https.HttpsError('permission-denied', 'Not allowed to update this task status.');
    }

    await ref.set(
      {
        status,
        updatedAt: new Date().toISOString(),
      },
      {merge: true}
    );

    return {ok: true, taskId, status};
  });

exports.updateTaskDetails = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const taskId = String((data && data.taskId) || '').trim();
    const updates = data && typeof data.updates === 'object' && data.updates ? data.updates : {};
    if (!taskId) {
      throw new functions.https.HttpsError('invalid-argument', 'taskId is required.');
    }

    const ref = db.collection('tasks').doc(taskId);
    const [taskSnap, callerDoc] = await Promise.all([
      ref.get(),
      db.collection('users').doc(callerUid).get(),
    ]);

    if (!taskSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Task not found.');
    }

    const task = taskSnap.data() || {};
    const callerRole = String((callerDoc.exists ? callerDoc.data() || {} : {}).role || '').toLowerCase();
    const isAdmin = callerRole === 'admin';
    const isCreator = String(task.createdBy || '') === callerUid;
    if (!isAdmin && !isCreator) {
      throw new functions.https.HttpsError('permission-denied', 'Only task creator can edit this task.');
    }

    const allowed = [
      'title',
      'description',
      'deadline',
      'caseId',
      'visibility',
      'assignedJuniorIds',
      'assignedToIds',
      'assignedToId',
      'assignedToName',
      'participantIds',
      'autoEscalate',
      'status',
      'updatedAt',
    ];

    const payload = {};
    for (const key of allowed) {
      if (Object.prototype.hasOwnProperty.call(updates, key)) {
        payload[key] = updates[key];
      }
    }

    if (Object.prototype.hasOwnProperty.call(payload, 'status')) {
      payload.status = normalizeWorkStatus(payload.status);
    }

    const participants = uniqueNonEmptyStrings([
      String(task.createdBy || ''),
      ...(Array.isArray(payload.participantIds) ? payload.participantIds : []),
      ...(Array.isArray(payload.assignedJuniorIds) ? payload.assignedJuniorIds : []),
      ...(Array.isArray(payload.assignedToIds) ? payload.assignedToIds : []),
      String(payload.assignedToId || ''),
    ]);
    payload.participantIds = participants;
    payload.updatedAt = new Date().toISOString();

    await ref.set(payload, {merge: true});
    return {ok: true, taskId};
  });

exports.updateTaskAssignableFields = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const taskId = String((data && data.taskId) || '').trim();
    const updates = data && typeof data.updates === 'object' && data.updates ? data.updates : {};
    if (!taskId) {
      throw new functions.https.HttpsError('invalid-argument', 'taskId is required.');
    }

    const ref = db.collection('tasks').doc(taskId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new functions.https.HttpsError('not-found', 'Task not found.');
    }

    const task = snap.data() || {};
    const isCreator = String(task.createdBy || '') === callerUid;
    const isAssigned = uniqueNonEmptyStrings([
      ...(Array.isArray(task.assignedJuniorIds) ? task.assignedJuniorIds : []),
      ...(Array.isArray(task.assignedToIds) ? task.assignedToIds : []),
      String(task.assignedToId || ''),
    ]).includes(callerUid);

    if (!isCreator && !isAssigned) {
      throw new functions.https.HttpsError('permission-denied', 'Only task creator/assignee can update these fields.');
    }

    const allowed = ['autoEscalate', 'isEscalated'];
    const payload = {};
    for (const key of allowed) {
      if (Object.prototype.hasOwnProperty.call(updates, key)) {
        payload[key] = updates[key];
      }
    }

    if (Object.keys(payload).length === 0) {
      throw new functions.https.HttpsError('invalid-argument', 'No allowed fields to update.');
    }

    payload.updatedAt = new Date().toISOString();
    await ref.set(payload, {merge: true});
    return {ok: true, taskId};
  });

exports.markTaskViewed = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const taskId = String((data && data.taskId) || '').trim();
    if (!taskId) {
      throw new functions.https.HttpsError('invalid-argument', 'taskId is required.');
    }

    const ref = db.collection('tasks').doc(taskId);
    const [taskSnap, viewerDoc] = await Promise.all([
      ref.get(),
      db.collection('users').doc(callerUid).get(),
    ]);

    if (!taskSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Task not found.');
    }

    const task = taskSnap.data() || {};
    const creatorUid = String(task.createdBy || '');
    const isAssigned = uniqueNonEmptyStrings([
      ...(Array.isArray(task.assignedJuniorIds) ? task.assignedJuniorIds : []),
      ...(Array.isArray(task.assignedToIds) ? task.assignedToIds : []),
      String(task.assignedToId || ''),
    ]).includes(callerUid);

    if (!isAssigned) {
      throw new functions.https.HttpsError('permission-denied', 'Only assignees can mark viewed.');
    }

    const existingViewed = Array.isArray(task.viewedBy) ? task.viewedBy : [];
    const alreadyViewed = existingViewed.some((v) => String((v && v.uid) || '') === callerUid);
    if (alreadyViewed) {
      return {ok: true, taskId, alreadyViewed: true, viewedByCount: existingViewed.length};
    }

    const viewerData = viewerDoc.exists ? viewerDoc.data() || {} : {};
    const viewerName = String((data && data.viewerName) || viewerData.name || 'Team member');
    const now = new Date().toISOString();
    const viewedBy = [...existingViewed, {uid: callerUid, name: viewerName, at: now}];

    await ref.set({
      viewedBy,
      updatedAt: now,
    }, {merge: true});

    if (creatorUid && creatorUid !== callerUid) {
      await db.collection('notifications').add({
        recipientUid: creatorUid,
        senderUid: callerUid,
        senderName: viewerName,
        type: 'task_viewed',
        title: 'Task Viewed',
        body: `${viewerName} viewed your task: ${String(task.title || 'Task')}`,
        relatedId: taskId,
        createdAt: now,
        isRead: false,
      });
    }

    return {ok: true, taskId, viewedByCount: viewedBy.length};
  });

exports.updateAssignmentStatus = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const assignmentId = String((data && data.assignmentId) || '').trim();
    const status = normalizeWorkStatus(data && data.status);
    if (!assignmentId) {
      throw new functions.https.HttpsError('invalid-argument', 'assignmentId is required.');
    }

    const ref = db.collection('assignments').doc(assignmentId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new functions.https.HttpsError('not-found', 'Assignment not found.');
    }

    const assignment = snap.data() || {};
    const isCreator = String(assignment.createdBy || '') === callerUid;
    const isParticipant = uniqueNonEmptyStrings(assignment.participantIds || []).includes(callerUid);
    const isAssigned = uniqueNonEmptyStrings([
      ...(Array.isArray(assignment.assignedToIds) ? assignment.assignedToIds : []),
      String(assignment.assignedToId || ''),
    ]).includes(callerUid);

    if (!isCreator && !isParticipant && !isAssigned) {
      throw new functions.https.HttpsError('permission-denied', 'Not allowed to update this assignment status.');
    }

    await ref.set(
      {
        status,
        updatedAt: new Date().toISOString(),
      },
      {merge: true}
    );

    return {ok: true, assignmentId, status};
  });

exports.updateAssignmentDetails = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const assignmentId = String((data && data.assignmentId) || '').trim();
    const updates = data && typeof data.updates === 'object' && data.updates ? data.updates : {};
    if (!assignmentId) {
      throw new functions.https.HttpsError('invalid-argument', 'assignmentId is required.');
    }

    const ref = db.collection('assignments').doc(assignmentId);
    const [assignmentSnap, callerDoc] = await Promise.all([
      ref.get(),
      db.collection('users').doc(callerUid).get(),
    ]);

    if (!assignmentSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Assignment not found.');
    }

    const assignment = assignmentSnap.data() || {};
    const callerRole = String((callerDoc.exists ? callerDoc.data() || {} : {}).role || '').toLowerCase();
    const isAdmin = callerRole === 'admin';
    const isCreator = String(assignment.createdBy || '') === callerUid;
    if (!isAdmin && !isCreator) {
      throw new functions.https.HttpsError('permission-denied', 'Only assignment creator can edit this assignment.');
    }

    const allowed = [
      'title',
      'description',
      'deadline',
      'tag',
      'caseId',
      'assignedToIds',
      'assignedToId',
      'assignedToName',
      'participantIds',
      'status',
      'updatedAt',
    ];

    const payload = {};
    for (const key of allowed) {
      if (Object.prototype.hasOwnProperty.call(updates, key)) {
        payload[key] = updates[key];
      }
    }

    if (Object.prototype.hasOwnProperty.call(payload, 'status')) {
      payload.status = normalizeWorkStatus(payload.status);
    }

    const participants = uniqueNonEmptyStrings([
      String(assignment.createdBy || ''),
      ...(Array.isArray(payload.participantIds) ? payload.participantIds : []),
      ...(Array.isArray(payload.assignedToIds) ? payload.assignedToIds : []),
      String(payload.assignedToId || ''),
    ]);
    payload.participantIds = participants;
    payload.updatedAt = new Date().toISOString();

    await ref.set(payload, {merge: true});
    return {ok: true, assignmentId};
  });

exports.updateAssignmentAssignableFields = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const assignmentId = String((data && data.assignmentId) || '').trim();
    const updates = data && typeof data.updates === 'object' && data.updates ? data.updates : {};
    if (!assignmentId) {
      throw new functions.https.HttpsError('invalid-argument', 'assignmentId is required.');
    }

    const ref = db.collection('assignments').doc(assignmentId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new functions.https.HttpsError('not-found', 'Assignment not found.');
    }

    const assignment = snap.data() || {};
    const isCreator = String(assignment.createdBy || '') === callerUid;
    const isAssigned = uniqueNonEmptyStrings([
      ...(Array.isArray(assignment.assignedToIds) ? assignment.assignedToIds : []),
      String(assignment.assignedToId || ''),
    ]).includes(callerUid);

    if (!isCreator && !isAssigned) {
      throw new functions.https.HttpsError('permission-denied', 'Only assignment creator/assignee can update these fields.');
    }

    const allowed = ['viewedBy'];
    const payload = {};
    for (const key of allowed) {
      if (Object.prototype.hasOwnProperty.call(updates, key)) {
        payload[key] = updates[key];
      }
    }

    if (Object.keys(payload).length === 0) {
      throw new functions.https.HttpsError('invalid-argument', 'No allowed fields to update.');
    }

    payload.updatedAt = new Date().toISOString();
    await ref.set(payload, {merge: true});
    return {ok: true, assignmentId};
  });

exports.markAssignmentViewed = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const assignmentId = String((data && data.assignmentId) || '').trim();
    if (!assignmentId) {
      throw new functions.https.HttpsError('invalid-argument', 'assignmentId is required.');
    }

    const ref = db.collection('assignments').doc(assignmentId);
    const [assignmentSnap, viewerDoc] = await Promise.all([
      ref.get(),
      db.collection('users').doc(callerUid).get(),
    ]);

    if (!assignmentSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Assignment not found.');
    }

    const assignment = assignmentSnap.data() || {};
    const creatorUid = String(assignment.createdBy || '');
    const isAssigned = uniqueNonEmptyStrings([
      ...(Array.isArray(assignment.assignedToIds) ? assignment.assignedToIds : []),
      String(assignment.assignedToId || ''),
    ]).includes(callerUid);

    if (!isAssigned) {
      throw new functions.https.HttpsError('permission-denied', 'Only assignees can mark viewed.');
    }

    const existingViewed = Array.isArray(assignment.viewedBy) ? assignment.viewedBy : [];
    const alreadyViewed = existingViewed.some((v) => String((v && v.uid) || '') === callerUid);
    if (alreadyViewed) {
      return {ok: true, assignmentId, alreadyViewed: true, viewedByCount: existingViewed.length};
    }

    const viewerData = viewerDoc.exists ? viewerDoc.data() || {} : {};
    const viewerName = String((data && data.viewerName) || viewerData.name || 'Team member');
    const now = new Date().toISOString();
    const viewedBy = [...existingViewed, {uid: callerUid, name: viewerName, at: now}];

    await ref.set({
      viewedBy,
      updatedAt: now,
    }, {merge: true});

    if (creatorUid && creatorUid !== callerUid) {
      await db.collection('notifications').add({
        recipientUid: creatorUid,
        senderUid: callerUid,
        senderName: viewerName,
        type: 'assignment_viewed',
        title: 'Assignment Viewed',
        body: `${viewerName} viewed your assignment: ${String(assignment.title || 'Assignment')}`,
        relatedId: assignmentId,
        createdAt: now,
        isRead: false,
      });
    }

    return {ok: true, assignmentId, viewedByCount: viewedBy.length};
  });

exports.deleteTask = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const taskId = String((data && data.taskId) || '').trim();
    if (!taskId) {
      throw new functions.https.HttpsError('invalid-argument', 'taskId is required.');
    }

    const taskRef = db.collection('tasks').doc(taskId);
    const taskSnap = await taskRef.get();
    if (!taskSnap.exists) {
      return {ok: true, taskId, alreadyDeleted: true};
    }

    const task = taskSnap.data() || {};
    const callerDoc = await db.collection('users').doc(callerUid).get();
    const callerRole = String((callerDoc.exists ? callerDoc.data() || {} : {}).role || '').toLowerCase();
    const isAdmin = callerRole === 'admin';
    const isCreator = String(task.createdBy || '') === callerUid;
    if (!isAdmin && !isCreator) {
      throw new functions.https.HttpsError('permission-denied', 'Only task creator can delete this task.');
    }

    await taskRef.delete();
    return {ok: true, taskId};
  });

exports.deleteAssignment = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const assignmentId = String((data && data.assignmentId) || '').trim();
    if (!assignmentId) {
      throw new functions.https.HttpsError('invalid-argument', 'assignmentId is required.');
    }

    const assignmentRef = db.collection('assignments').doc(assignmentId);
    const assignmentSnap = await assignmentRef.get();
    if (!assignmentSnap.exists) {
      return {ok: true, assignmentId, alreadyDeleted: true};
    }

    const assignment = assignmentSnap.data() || {};
    const callerDoc = await db.collection('users').doc(callerUid).get();
    const callerRole = String((callerDoc.exists ? callerDoc.data() || {} : {}).role || '').toLowerCase();
    const isAdmin = callerRole === 'admin';
    const isCreator = String(assignment.createdBy || '') === callerUid;
    if (!isAdmin && !isCreator) {
      throw new functions.https.HttpsError('permission-denied', 'Only assignment creator can delete this assignment.');
    }

    await assignmentRef.delete();
    return {ok: true, assignmentId};
  });

exports.upsertNotice = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const input = data && typeof data.notice === 'object' && data.notice ? data.notice : {};
    const noticeId = String(input.id || '').trim();
    if (!noticeId) {
      throw new functions.https.HttpsError('invalid-argument', 'notice.id is required.');
    }

    const noticeRef = db.collection('notices').doc(noticeId);
    const [noticeSnap, callerSnap] = await Promise.all([
      noticeRef.get(),
      db.collection('users').doc(callerUid).get(),
    ]);

    const existing = noticeSnap.exists ? noticeSnap.data() || {} : {};
    const callerData = callerSnap.exists ? callerSnap.data() || {} : {};
    const callerRole = String(callerData.role || '').toLowerCase();
    const isAdmin = callerRole === 'admin';

    const effectiveAuthorId = String(existing.authorId || input.authorId || callerUid).trim() || callerUid;
    if (noticeSnap.exists && !isAdmin && effectiveAuthorId !== callerUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only author/admin can update this notice.');
    }

    const title = String(input.title || existing.title || '').trim();
    const content = String(input.content || existing.content || '').trim();
    if (!title || !content) {
      throw new functions.https.HttpsError('invalid-argument', 'Notice title and content are required.');
    }

    const allUserIds = await getAllUserIds();
    const participantIds = uniqueNonEmptyStrings([
      ...allUserIds,
      ...(Array.isArray(existing.participantIds) ? existing.participantIds : []),
      ...(Array.isArray(input.participantIds) ? input.participantIds : []),
      callerUid,
      effectiveAuthorId,
    ]);

    const payload = {
      id: noticeId,
      title,
      content,
      priority: String(input.priority || existing.priority || 'normal'),
      isPinned:
        typeof input.isPinned === 'boolean'
          ? input.isPinned
          : Boolean(existing.isPinned),
      authorId: effectiveAuthorId,
      authorName: String(
        input.authorName ||
          existing.authorName ||
          callerData.name ||
          callerData.fullName ||
          context.auth.token.name ||
          'Team Member'
      ),
      authorRole: String(input.authorRole || existing.authorRole || callerRole || 'member'),
      ownerUid: String(existing.ownerUid || input.ownerUid || effectiveAuthorId || callerUid),
      createdBy: String(existing.createdBy || input.createdBy || effectiveAuthorId || callerUid),
      createdAt: String(existing.createdAt || input.createdAt || new Date().toISOString()),
      updatedAt: new Date().toISOString(),
      participantIds,
    };

    await noticeRef.set(payload, {merge: true});
    return {ok: true, noticeId};
  });

exports.deleteNotice = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const noticeId = String((data && data.noticeId) || '').trim();
    if (!noticeId) {
      throw new functions.https.HttpsError('invalid-argument', 'noticeId is required.');
    }

    const noticeRef = db.collection('notices').doc(noticeId);
    const [noticeSnap, callerSnap] = await Promise.all([
      noticeRef.get(),
      db.collection('users').doc(callerUid).get(),
    ]);
    if (!noticeSnap.exists) {
      return {ok: true, noticeId, alreadyDeleted: true};
    }

    const notice = noticeSnap.data() || {};
    const callerRole = String((callerSnap.exists ? callerSnap.data() || {} : {}).role || '').toLowerCase();
    const isAdmin = callerRole === 'admin';
    const isAuthor = String(notice.authorId || '') === callerUid || String(notice.createdBy || '') === callerUid;
    if (!isAdmin && !isAuthor) {
      throw new functions.https.HttpsError('permission-denied', 'Only notice author can delete this notice.');
    }

    await noticeRef.delete();
    return {ok: true, noticeId};
  });

exports.upsertChatGroup = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const input = data && typeof data.group === 'object' && data.group ? data.group : {};
    const groupId = String(input.id || '').trim();
    if (!groupId) {
      throw new functions.https.HttpsError('invalid-argument', 'group.id is required.');
    }

    const groupRef = db.collection('chatGroups').doc(groupId);
    const existingSnap = await groupRef.get();
    const existing = existingSnap.exists ? existingSnap.data() || {} : {};

    const existingCreator = String(existing.createdBy || '').trim();
    if (existingSnap.exists && existingCreator !== callerUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only chat creator can edit this group.');
    }

    const createdBy = existingCreator || callerUid;
    const createdByName = String(input.createdByName || existing.createdByName || 'Creator');
    const memberIds = uniqueNonEmptyStrings([
      ...(Array.isArray(input.memberIds) ? input.memberIds : []),
      ...(Array.isArray(existing.memberIds) ? existing.memberIds : []),
      createdBy,
      callerUid,
    ]);

    const payload = {
      id: groupId,
      caseId: String(input.caseId || existing.caseId || '').trim() || null,
      name: String(input.name || existing.name || '').trim() || 'Chat',
      description: String(input.description || existing.description || '').trim() || null,
      createdBy,
      createdByName,
      createdAt: String(existing.createdAt || input.createdAt || new Date().toISOString()),
      memberIds,
      memberNames: Array.isArray(input.memberNames) && input.memberNames.length > 0
        ? input.memberNames
        : (Array.isArray(existing.memberNames) ? existing.memberNames : []),
      participantIds: memberIds,
      lastMessage: input.lastMessage || existing.lastMessage || null,
      lastMessageTime: input.lastMessageTime || existing.lastMessageTime || null,
      isTemporary: typeof input.isTemporary === 'boolean' ? input.isTemporary : (existing.isTemporary !== false),
      isGroup: typeof input.isGroup === 'boolean' ? input.isGroup : (existing.isGroup !== false),
      hiddenForUserIds: uniqueNonEmptyStrings(existing.hiddenForUserIds || []),
      clearedAtByUser: Object.assign({}, existing.clearedAtByUser || {}),
      updatedAt: new Date().toISOString(),
    };

    await groupRef.set(payload, {merge: true});
    return {ok: true, groupId};
  });

exports.deleteChatForMe = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const groupId = String((data && data.groupId) || '').trim();
    if (!groupId) {
      throw new functions.https.HttpsError('invalid-argument', 'groupId is required.');
    }

    const groupRef = db.collection('chatGroups').doc(groupId);
    const snap = await groupRef.get();
    if (!snap.exists) return {ok: true, groupId, alreadyDeleted: true};

    const group = snap.data() || {};
    const memberIds = uniqueNonEmptyStrings(group.memberIds || []);
    if (!memberIds.includes(callerUid)) {
      throw new functions.https.HttpsError('permission-denied', 'Not a member of this chat.');
    }

    await groupRef.set(
      {
        hiddenForUserIds: admin.firestore.FieldValue.arrayUnion(callerUid),
        updatedAt: new Date().toISOString(),
      },
      {merge: true}
    );

    return {ok: true, groupId};
  });

exports.clearChatForMe = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const groupId = String((data && data.groupId) || '').trim();
    if (!groupId) {
      throw new functions.https.HttpsError('invalid-argument', 'groupId is required.');
    }

    const groupRef = db.collection('chatGroups').doc(groupId);
    const snap = await groupRef.get();
    if (!snap.exists) return {ok: true, groupId, alreadyDeleted: true};

    const group = snap.data() || {};
    const memberIds = uniqueNonEmptyStrings(group.memberIds || []);
    if (!memberIds.includes(callerUid)) {
      throw new functions.https.HttpsError('permission-denied', 'Not a member of this chat.');
    }

    const clearedAtByUser = Object.assign({}, group.clearedAtByUser || {});
    clearedAtByUser[callerUid] = new Date().toISOString();

    await groupRef.set(
      {
        clearedAtByUser,
        updatedAt: new Date().toISOString(),
      },
      {merge: true}
    );

    return {ok: true, groupId};
  });

exports.deleteChatForEveryone = functions
  .region('asia-south1')
  .https.onCall(async (data, context) => {
    const callerUid = context.auth && context.auth.uid ? context.auth.uid : '';
    if (!callerUid) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required.');
    }

    const groupId = String((data && data.groupId) || '').trim();
    if (!groupId) {
      throw new functions.https.HttpsError('invalid-argument', 'groupId is required.');
    }

    const groupRef = db.collection('chatGroups').doc(groupId);
    const snap = await groupRef.get();
    if (!snap.exists) return {ok: true, groupId, alreadyDeleted: true};

    const group = snap.data() || {};
    if (String(group.createdBy || '').trim() !== callerUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only group creator can delete for everyone.');
    }

    const messages = await groupRef.collection('messages').get();
    await deleteDocumentRefsInBatches(messages.docs.map((d) => d.ref));
    await groupRef.delete();

    return {ok: true, groupId};
  });

/**
 * Scheduled function to check for overdue tasks and escalate them if autoEscalate is true.
 * Runs every hour.
 */
exports.autoEscalateTasks = functions
  .region('asia-south1')
  .pubsub.schedule('every 1 hours')
  .onRun(async (context) => {
    const now = new Date();
    const tasksSnap = await db.collection('tasks')
      .where('autoEscalate', '==', true)
      .where('isEscalated', '==', false)
      .where('status', '!=', 'completed')
      .get();

    if (tasksSnap.empty) {
      return null;
    }

    const promises = [];
    tasksSnap.forEach((doc) => {
      const task = doc.data();
      const deadline = new Date(task.deadline);
      if (deadline < now) {
        // Mark as escalated
        promises.push(doc.ref.update({
          isEscalated: true,
          status: 'overdue',
          updatedAt: now.toISOString(),
        }));
      }
    });

    if (promises.length > 0) {
      await Promise.all(promises);
      functions.logger.info(`Auto-escalated ${promises.length} tasks.`);
    }

    return null;
  });
