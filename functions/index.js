const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();
const db = admin.firestore();

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
      notification: {
        channelId: type === 'sos' ? 'synapse_sos' : 'synapse_main',
        priority: type === 'sos' ? 'max' : 'high',
        defaultSound: true,
      },
    },
    apns: {
      payload: {
        aps: {sound: 'default'},
      },
      headers: {'apns-priority': '10'},
    },
    webpush: {
      notification: {
        title,
        body,
        icon: '/icons/Icon-192.png',
        requireInteraction: type === 'sos',
      },
      fcmOptions: {link: '/'},
      headers: {Urgency: 'high'},
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
    const groupName = String(group.title || 'Team Chat');
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
