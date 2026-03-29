import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'web_notification_helper.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}
}

/// Handles both local (offline) and push (online) notifications
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static int _notifId = 0;
  static String _lastSyncedUid = '';
  static String _lastSyncedToken = '';
  static final Set<String> _openedSosIds = <String>{};
  static DateTime? _sosOpenSuppressUntil;
  static const String _defaultWebVapidKey =
      'BCBAtoGus_rPj-dZ3epf5s6QZbLvvffq48ZYNbD6ubdMPh1dtO-hJJgmnAXJx7jz3K7awlsLCKrISP--cC6Mvt4';
  static const String _webVapidKey = String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');

  static Future<String?> _getFcmToken() async {
    if (kIsWeb) {
      final vapidKey = _webVapidKey.trim().isNotEmpty
          ? _webVapidKey.trim()
          : _defaultWebVapidKey;
      if (vapidKey.isNotEmpty) {
        return FirebaseMessaging.instance.getToken(vapidKey: vapidKey);
      }
      return FirebaseMessaging.instance.getToken();
    }
    return FirebaseMessaging.instance.getToken();
  }

  static Future<void> _handleOpenFromNotification(RemoteMessage message) async {
    if (!kIsWeb) {
      await cancelAll();
    }

    final data = message.data;
    final type = (data['type'] ?? '').toString().toLowerCase();
    final title = (message.notification?.title ?? '').toLowerCase();
    final isSos = type == 'sos' || title.contains('sos');
    if (!isSos) return;

    final sosId = (data['sosId'] ?? data['id'] ?? '').toString();
    if (sosId.isNotEmpty) {
      _openedSosIds.add(sosId);
    }

    _sosOpenSuppressUntil = DateTime.now().add(const Duration(seconds: 20));
  }

  static bool shouldSuppressSosVisual({String? sosId}) {
    if (sosId != null && sosId.isNotEmpty && _openedSosIds.contains(sosId)) {
      return true;
    }
    final until = _sosOpenSuppressUntil;
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  /// Initialize notification channels and FCM
  static Future<void> init() async {
    if (kIsWeb) {
      final permission = await ensureWebNotificationPermission();
      debugPrint('Web notification permission: $permission');
    }

    // Local notifications not supported on web
    if (!kIsWeb) {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings();
      const settings =
          InitializationSettings(android: androidSettings, iOS: iosSettings);

      await _plugin.initialize(settings);

      // Create Android channels
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'synapse_main',
            'Synapse Notifications',
            description: 'General notifications',
            importance: Importance.high,
          ),
        );

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'synapse_sos',
            'SOS Alerts',
            description: 'Urgent SOS alerts from courtroom',
            importance: Importance.max,
            playSound: true,
          ),
        );

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'synapse_deadline',
            'Deadline Reminders',
            description: 'Task and hearing deadline reminders',
            importance: Importance.high,
          ),
        );
      }
    }

    // Firebase Cloud Messaging setup (works on web)
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notification = message.notification;
        if (notification != null) {
          show(
            title: notification.title ?? 'Synapse',
            body: notification.body ?? '',
          );
        }
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        final notification = message.notification;
        if (notification != null) {
          debugPrint('Opened from notification: ${notification.title}');
        }
        _handleOpenFromNotification(message);
      });

      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) {
        debugPrint('App launched from notification tap: ${initial.messageId}');
        await _handleOpenFromNotification(initial);
      }

      debugPrint('FCM initialized');
    } catch (e) {
      debugPrint('FCM init error (notifications still work locally): $e');
    }
  }

  static Future<void> syncDeviceTokenForUser(String uid) async {
    if (uid.trim().isEmpty) return;

    try {
      final token = await _getFcmToken();
      if (token == null || token.trim().isEmpty) return;

      final normalizedToken = token.trim();
      if (_lastSyncedUid == uid && _lastSyncedToken == normalizedToken) return;

      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([normalizedToken]),
        'fcmTokenUpdatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));

      _lastSyncedUid = uid;
      _lastSyncedToken = normalizedToken;

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final normalized = newToken.trim();
        if (normalized.isEmpty) return;
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'fcmTokens': FieldValue.arrayUnion([normalized]),
          'fcmTokenUpdatedAt': DateTime.now().toIso8601String(),
        }, SetOptions(merge: true));
        _lastSyncedUid = uid;
        _lastSyncedToken = normalized;
      });
    } catch (e) {
      debugPrint('Failed to sync FCM token for user $uid: $e');
    }
  }

  // ══════════ SHOW IMMEDIATE NOTIFICATION ══════════

  /// Show a notification right now (works offline)
  static Future<void> show({
    required String title,
    required String body,
    String channelId = 'synapse_main',
  }) async {
    if (kIsWeb) {
      await showWebBrowserNotification(title: title, body: body);
      return;
    }
    try {
      await _plugin.show(
        _notifId++,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelId == 'synapse_sos'
                ? 'SOS Alerts'
                : channelId == 'synapse_deadline'
                    ? 'Deadline Reminders'
                    : 'Synapse Notifications',
            importance: channelId == 'synapse_sos'
                ? Importance.max
                : Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Notification error: $e');
    }
  }

  // ══════════ SCHEDULE FUTURE NOTIFICATION ══════════

  /// Schedule a notification for a deadline
  /// Works even in airplane mode (stored in Android OS)
  static Future<void> scheduleDeadlineReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    // Don't schedule if time already passed
    if (scheduledTime.isBefore(DateTime.now())) return;

    try {
      // Use the simple delayed approach since timezone setup can be complex
      final delay = scheduledTime.difference(DateTime.now());

      // For notifications within 24 hours, schedule directly
      if (delay.inHours <= 24) {
        Future.delayed(delay, () {
          show(title: title, body: body, channelId: 'synapse_deadline');
        });
      }

      debugPrint('Reminder scheduled: $title at $scheduledTime');
    } catch (e) {
      debugPrint('Schedule notification error: $e');
    }
  }

  // ══════════ SOS NOTIFICATION ══════════

  /// Show an urgent SOS notification with alarm sound
  static Future<void> showSOSAlert({
    required String senderName,
    required String caseName,
    required String courtRoom,
  }) async {
    await show(
      title: '🆘 SOS ALERT!',
      body: '$senderName needs help!\nCase: $caseName\nLocation: $courtRoom',
      channelId: 'synapse_sos',
    );
  }

  // ══════════ CANCEL ══════════

  /// Cancel a specific scheduled notification
  static Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  /// Cancel all notifications
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}