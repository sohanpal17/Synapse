import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'web_notification_helper.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'hive_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    if (!kIsWeb) {
      await Hive.initFlutter();
      await HiveService.init();

      if (NotificationService._isSosMessage(message)) {
        final data = message.data;
        final sosId = (data['sosId'] ?? data['id'] ?? '').toString();
        final blinkData = {
          'sosId': sosId,
          'sentBy': (data['sentBy'] ?? '').toString(),
          'sentByName': (data['sentByName'] ?? 'Team member').toString(),
          'caseName': (data['caseName'] ?? 'Unknown case').toString(),
          'courtRoom': (data['courtRoom'] ?? '').toString(),
          'receivedAt': DateTime.now().toIso8601String(),
        };
        await HiveService.put(HiveService.sosBox, 'pending_blink_$sosId', blinkData);
      }
    }
  } catch (e) {
    debugPrint('Background FCM handler failed to save SOS: $e');
  }
}

/// Handles both local (offline) and push (online) notifications
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static int _notifId = 0;
  static String _lastSyncedUid = '';
  static String _lastSyncedToken = '';
  static bool _tokenRefreshBound = false;
  static final AudioPlayer _sosBlinkAudioPlayer = AudioPlayer();
  static Timer? _webSosBeepTicker;
  static bool _sosBlinkLoopActive = false;
  static bool _sosBlinkAudioConfigured = false;
  static bool _loggedSosAudioFailure = false;
  static bool _webTokenRetryScheduled = false;
  static final AudioPlayer _sosNotificationAudioPlayer = AudioPlayer();
  static bool _sosNotificationAudioConfigured = false;

  /// Track SOS IDs where in-app audio was already played by the FCM handler.
  /// Prevents dashboards from playing audio again for the same SOS.
  static final Set<String> _sosIdsWithAudioPlayed = <String>{};

  /// Check if audio was already played for this SOS (by FCM foreground handler).
  static bool wasAudioAlreadyPlayed(String sosId) =>
      _sosIdsWithAudioPlayed.contains(sosId);

  /// Mark audio as played for this SOS ID.
  static void markAudioPlayed(String sosId) {
    if (sosId.isNotEmpty) _sosIdsWithAudioPlayed.add(sosId);
  }

  // ── Pending SOS blinks for deferred dashboard consumption ──
  static final List<Map<String, dynamic>> _pendingSosBlinks = [];
  static final StreamController<Map<String, dynamic>> _sosBlinkController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream that active dashboards subscribe to for real-time SOS blink events.
  static Stream<Map<String, dynamic>> get sosBlinkStream =>
      _sosBlinkController.stream;

  /// Consume pending SOS blinks (received while no dashboard was listening).
  /// Returns blinks within the 2-minute window only.
  static List<Map<String, dynamic>> consumePendingSosBlinks() {
    final now = DateTime.now();
    final valid = _pendingSosBlinks.where((b) {
      final receivedAt = b['receivedAt'] as DateTime?;
      if (receivedAt == null) return false;
      return now.difference(receivedAt) <= const Duration(minutes: 2);
    }).toList();
    _pendingSosBlinks.clear();
    return valid;
  }

  /// Store a pending SOS blink from FCM and also persist timestamp to Hive
  /// so that if the app is opened later (within 2 min), the dashboard
  /// can still trigger the blink.
  static void _enqueueSosBlink(Map<String, dynamic> blinkData) {
    _pendingSosBlinks.add(blinkData);
    if (!_sosBlinkController.isClosed) {
      _sosBlinkController.add(blinkData);
    }
    // Persist to Hive so cold-starts within 2 min can trigger blink.
    try {
      final sosId = (blinkData['sosId'] ?? '').toString();
      final receivedAt = (blinkData['receivedAt'] as DateTime?) ?? DateTime.now();
      HiveService.put(HiveService.sosBox, 'pending_blink_$sosId', {
        'sosId': sosId,
        'receivedAt': receivedAt.toIso8601String(),
        ...blinkData,
      });
    } catch (e) {
      debugPrint('Failed to persist pending SOS blink: $e');
    }
  }

  /// Load pending SOS blinks from Hive (for cold-start / reopened app).
  /// Removes expired entries (>2 min old).
  static List<Map<String, dynamic>> loadPendingSosBlinksFromHive() {
    try {
      final now = DateTime.now();
      final allSos = HiveService.getAll(HiveService.sosBox);
      final pending = <Map<String, dynamic>>[];
      for (final entry in allSos) {
        final key = (entry['sosId'] ?? '').toString();
        final receivedAtStr = (entry['receivedAt'] ?? '').toString();
        final receivedAt = DateTime.tryParse(receivedAtStr);
        if (receivedAt == null) continue;
        if (key.isEmpty) continue;
        // Check if within 2-minute window
        if (now.difference(receivedAt) <= const Duration(minutes: 2)) {
          pending.add({
            ...entry,
            'receivedAt': receivedAt,
          });
        } else {
          // Clean up expired entries
          HiveService.delete(HiveService.sosBox, 'pending_blink_$key');
        }
      }
      return pending;
    } catch (e) {
      debugPrint('Failed to load pending SOS blinks from Hive: $e');
      return [];
    }
  }

  /// Mark a pending SOS blink as consumed (remove from Hive).
  static void markSosBlinkConsumed(String sosId) {
    try {
      HiveService.delete(HiveService.sosBox, 'pending_blink_$sosId');
    } catch (_) {}
  }
  static const List<Map<String, String>> _sosBlinkAudioCandidates = [
    {'path': 'audio/sos_alert_3s.wav', 'mime': 'audio/wav'},
    {'path': 'assets/audio/sos_alert_3s.wav', 'mime': 'audio/wav'},
    {'path': 'audio/sos_alert.wav', 'mime': 'audio/wav'},
    {'path': 'assets/audio/sos_alert.wav', 'mime': 'audio/wav'},
    {'path': 'audio/sos_alert.mp3', 'mime': 'audio/mpeg'},
    {'path': 'assets/audio/sos_alert.mp3', 'mime': 'audio/mpeg'},
    {'path': 'audio/sos_alert.ogg', 'mime': 'audio/ogg'},
    {'path': 'assets/audio/sos_alert.ogg', 'mime': 'audio/ogg'},
  ];
  static const String _defaultWebVapidKey =
      'BCBAtoGus_rPj-dZ3epf5s6QZbLvvffq48ZYNbD6ubdMPh1dtO-hJJgmnAXJx7jz3K7awlsLCKrISP--cC6Mvt4';
  static const String _webVapidKey = String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');
  static const String _sosChannelId = 'synapse_sos_v9';
  static const String _sosAndroidSound = 'sos_alert_3s';
  static final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-south1');

  static bool _isMissingCallableError(Object e) {
    final text = e.toString().toLowerCase();
    return text.contains('not-found') ||
        text.contains('unimplemented') ||
        text.contains('unavailable') ||
        text.contains('failed-precondition');
  }

  static Future<void> _claimTokenWithFallback(
    String uid,
    String token,
  ) async {
    try {
      await _functions.httpsCallable('claimDeviceFcmToken').call({
        'token': token,
      });
      return;
    } catch (e) {
      if (!_isMissingCallableError(e)) rethrow;
      // Fallback keeps notifications working even if new callable isn't deployed yet.
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
        'fcmTokenUpdatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
    }
  }

  static Future<void> _unclaimTokenWithFallback(
    String uid,
    String token,
  ) async {
    try {
      await _functions.httpsCallable('unclaimDeviceFcmToken').call({
        'token': token,
      });
      return;
    } catch (e) {
      if (!_isMissingCallableError(e)) rethrow;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmTokens': FieldValue.arrayRemove([token]),
        'fcmTokenUpdatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
    }
  }

  static Future<String?> _getFcmToken() async {
    if (kIsWeb) {
      final swReady = await ensureWebPushServiceWorkerReady();
      if (!swReady) {
        debugPrint(
          'Web push service worker is not active yet; skipping FCM token request for now.',
        );
        return null;
      }

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

    // When user opens the app from an SOS notification, ENQUEUE a blink
    // so the dashboard can show it (instead of suppressing it).
    final sosId = (data['sosId'] ?? data['id'] ?? '').toString();
    final sentBy = (data['sentBy'] ?? '').toString();
    _enqueueSosBlink({
      'sosId': sosId,
      'sentBy': sentBy,
      'sentByName': (data['sentByName'] ?? 'Team member').toString(),
      'caseName': (data['caseName'] ?? 'Unknown case').toString(),
      'courtRoom': (data['courtRoom'] ?? '').toString(),
      'receivedAt': DateTime.now(),
    });
  }

  static bool _isSosMessage(RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] ?? '').toString().toLowerCase();
    final title = (message.notification?.title ?? '').toLowerCase();
    final body = (message.notification?.body ?? '').toLowerCase();
    return type == 'sos' || title.contains('sos') || body.contains('sos');
  }

  /// Initialize notification channels and FCM
  static Future<void> init() async {
    if (kIsWeb) {
      final permission = await getWebNotificationPermissionStatus();
      debugPrint('Web notification permission (startup, no prompt): $permission');

      // Prompt in background so startup is never blocked by browser permission UI.
      Future<void>(() async {
        final promptedPermission = await ensureWebNotificationPermission();
        debugPrint('Web notification permission (after prompt): $promptedPermission');
      });
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
        await androidPlugin.requestNotificationsPermission();

        // Delete old SOS channels so Android picks up new sound settings.
        // Android caches channel settings and won't update them once created.
        for (final oldId in [
          'synapse_sos_v6',
          'synapse_sos_v7',
          'synapse_sos_v8',
        ]) {
          try {
            await androidPlugin.deleteNotificationChannel(oldId);
          } catch (_) {}
        }

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'synapse_main',
            'Synapse Notifications',
            description: 'General notifications',
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            _sosChannelId,
            'SOS Alerts',
            description: 'Urgent SOS alerts from courtroom',
            importance: Importance.max,
            playSound: true,
            sound: RawResourceAndroidNotificationSound(_sosAndroidSound),
            enableVibration: true,
          ),
        );

        await androidPlugin.createNotificationChannel(
          const AndroidNotificationChannel(
            'synapse_deadline',
            'Deadline Reminders',
            description: 'Task and hearing deadline reminders',
            importance: Importance.high,
            playSound: true,
            enableVibration: true,
          ),
        );
      }
    }

    // Firebase Cloud Messaging setup (works on web)
    try {
      if (!kIsWeb) {
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
      } else {
        // Keep web prompt non-blocking to avoid delaying app load.
        Future<void>(() async {
          await FirebaseMessaging.instance.requestPermission(
            alert: true,
            badge: true,
            sound: true,
          );
        });
      }

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final notification = message.notification;
        final data = message.data;
        final isSos = _isSosMessage(message);

        final title = notification?.title ?? (isSos ? 'SOS ALERT' : 'Synapse');
        final body = notification?.body ?? (data['body'] ?? '').toString();

        if (notification != null || isSos || body.isNotEmpty) {
          show(
            title: title,
            body: body,
            channelId: isSos ? _sosChannelId : 'synapse_main',
          );
        }

        if (isSos) {
          final sosId = (data['sosId'] ?? data['id'] ?? '').toString();
          // Enqueue a pending blink so the dashboard can trigger it
          final sentBy = (data['sentBy'] ?? '').toString();
          _enqueueSosBlink({
            'sosId': sosId,
            'sentBy': sentBy,
            'sentByName': (data['sentByName'] ?? 'Team member').toString(),
            'caseName': (data['caseName'] ?? 'Unknown case').toString(),
            'courtRoom': (data['courtRoom'] ?? '').toString(),
            'receivedAt': DateTime.now(),
          });
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
      if (token == null || token.trim().isEmpty) {
        if (kIsWeb && !_webTokenRetryScheduled) {
          _webTokenRetryScheduled = true;
          Future<void>.delayed(const Duration(seconds: 3), () {
            _webTokenRetryScheduled = false;
            syncDeviceTokenForUser(uid);
          });
        }
        return;
      }

      final normalizedToken = token.trim();
      if (_lastSyncedUid == uid && _lastSyncedToken == normalizedToken) return;

      await _claimTokenWithFallback(uid, normalizedToken);

      _lastSyncedUid = uid;
      _lastSyncedToken = normalizedToken;
      _webTokenRetryScheduled = false;

      if (!_tokenRefreshBound) {
        _tokenRefreshBound = true;
        FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
          final activeUid = _lastSyncedUid.trim();
          if (activeUid.isEmpty) return;
          final normalized = newToken.trim();
          if (normalized.isEmpty) return;

          try {
            await _claimTokenWithFallback(activeUid, normalized);
            _lastSyncedToken = normalized;
          } catch (e) {
            debugPrint('Failed to sync refreshed FCM token for user $activeUid: $e');
          }
        });
      }
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (kIsWeb && text.contains('pushmanager') && text.contains('no active service worker')) {
        // Service worker activation can lag behind first auth cycle on web.
        Future<void>.delayed(const Duration(seconds: 3), () {
          syncDeviceTokenForUser(uid);
        });
        return;
      }
      debugPrint('Failed to sync FCM token for user $uid: $e');
    }
  }

  static Future<void> unbindCurrentDeviceToken({String? uid}) async {
    try {
      final activeUid = (uid ?? _lastSyncedUid).trim();
      if (activeUid.isEmpty) return;

      final token = await _getFcmToken();
      if (token == null || token.trim().isEmpty) return;

      await _unclaimTokenWithFallback(activeUid, token.trim());

      _lastSyncedUid = '';
      _lastSyncedToken = '';
    } catch (e) {
      debugPrint('Failed to unbind device FCM token: $e');
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
            channelId == _sosChannelId
                ? 'SOS Alerts'
                : channelId == 'synapse_deadline'
                    ? 'Deadline Reminders'
                    : 'Synapse Notifications',
            importance: channelId == _sosChannelId
                ? Importance.max
                : Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: channelId == _sosChannelId
              ? const RawResourceAndroidNotificationSound(_sosAndroidSound)
              : null,
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
      channelId: _sosChannelId,
    );
  }

  /// Play an in-app SOS WAV sound when the SOS blink overlay starts.
  /// Expected asset path (preferred): assets/audio/sos_alert.wav
  /// Optional web fallbacks: assets/audio/sos_alert.mp3 or assets/audio/sos_alert.ogg
  static Future<void> playSosBlinkAudio() async {
    await startSosBlinkAudioLoop();
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_sosBlinkLoopActive) {
        stopSosBlinkAudioLoop();
      }
    });
  }

  /// Notification-first SOS sound: play immediately for 3 seconds using
  /// a dedicated player so it doesn't conflict with blink audio.
  static Future<void> playSosNotificationAudioFor3Seconds() async {
    try {
      if (kIsWeb) {
        // Use the blink audio loop on web as a fallback
        await startSosBlinkAudioLoop();
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (_sosBlinkLoopActive) stopSosBlinkAudioLoop();
        });
        return;
      }

      // Configure the notification audio player once
      if (!_sosNotificationAudioConfigured) {
        await _sosNotificationAudioPlayer.setPlayerMode(PlayerMode.mediaPlayer);
        await _sosNotificationAudioPlayer.setReleaseMode(ReleaseMode.stop);
        await _sosNotificationAudioPlayer.setVolume(1.0);
        _sosNotificationAudioConfigured = true;
      }

      await _sosNotificationAudioPlayer.stop();

      // Try the 3-second audio file first, then fall back to others
      const candidates = [
        'audio/sos_alert_3s.wav',
        'audio/sos_alert.wav',
        'audio/sos_alert.mp3',
      ];

      Exception? lastError;
      for (final path in candidates) {
        try {
          debugPrint('SOS audio: trying asset $path');
          await _sosNotificationAudioPlayer.play(
            AssetSource(path),
            mode: PlayerMode.mediaPlayer,
          );
          debugPrint('SOS audio: playing $path successfully');

          // Stop after 3 seconds
          Future<void>.delayed(const Duration(seconds: 3), () async {
            try {
              await _sosNotificationAudioPlayer.stop();
            } catch (_) {}
          });
          return;
        } catch (e) {
          debugPrint('SOS audio: failed to play $path: $e');
          lastError = e is Exception ? e : Exception(e.toString());
        }
      }

      if (lastError != null) {
        debugPrint('SOS audio: all candidates failed, last error: $lastError');
      }
    } catch (e) {
      debugPrint('SOS notification audio error: $e');
    }
  }

  static Future<void> startSosBlinkAudioLoop() async {
    _sosBlinkLoopActive = true;
    try {
      if (kIsWeb) {
        // Avoid web codec issues by using a generated tone loop.
        _webSosBeepTicker?.cancel();
        await playWebSosBeep(durationMs: 220);
        _webSosBeepTicker = Timer.periodic(const Duration(milliseconds: 260), (_) {
          if (!_sosBlinkLoopActive) return;
          playWebSosBeep(durationMs: 220);
        });
        return;
      }

      if (!_sosBlinkAudioConfigured) {
        await _sosBlinkAudioPlayer.setPlayerMode(PlayerMode.mediaPlayer);
        await _sosBlinkAudioPlayer.setReleaseMode(ReleaseMode.loop);
        await _sosBlinkAudioPlayer.setVolume(1.0);
        _sosBlinkAudioConfigured = true;
      } else {
        await _sosBlinkAudioPlayer.setReleaseMode(ReleaseMode.loop);
      }

      await _sosBlinkAudioPlayer.stop();

      Exception? lastError;
      for (final candidate in _sosBlinkAudioCandidates) {
        final path = candidate['path']!;
        final mime = candidate['mime'];
        try {
          await _sosBlinkAudioPlayer.play(
            AssetSource(path, mimeType: mime),
            mode: PlayerMode.mediaPlayer,
          );
          _loggedSosAudioFailure = false;
          debugPrint('SOS blink audio: playing $path');
          return;
        } catch (e) {
          lastError = e is Exception ? e : Exception(e.toString());
        }
      }

      if (lastError != null) {
        throw lastError;
      }
    } catch (e) {
      if (!_loggedSosAudioFailure) {
        _loggedSosAudioFailure = true;
        debugPrint(
          'Failed to play SOS blink audio from assets/audio/sos_alert.*: $e',
        );
      }
    }
  }

  static Future<void> stopSosBlinkAudioLoop() async {
    _sosBlinkLoopActive = false;
    _webSosBeepTicker?.cancel();
    _webSosBeepTicker = null;
    if (!kIsWeb) {
      try {
        await _sosBlinkAudioPlayer.stop();
        if (_sosBlinkAudioConfigured) {
          await _sosBlinkAudioPlayer.setReleaseMode(ReleaseMode.stop);
        }
      } catch (_) {
        // Best effort stop.
      }
    }
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