import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'hive_service.dart';
import 'firestore_service.dart';
import 'notification_service.dart';
import 'sync_service.dart';

const _uuid = Uuid();

/// Handles SOS alerts with multi-layer fallback:
/// 1. Online → Firestore (triggers FCM push)
/// 2. Offline → SMS via system
/// 3. No signal at all → Queue locally + retry
class SOSService {
  /// Send SOS alert with automatic fallback
  /// Returns: 'sent_online', 'sent_sms', or 'queued'
  static Future<String> sendSOS({
    required String caseId,
    required String caseName,
    required String courtRoom,
    required String courtComplex,
    required String sentById,
    required String sentByName,
    required List<String> recipientIds,
    List<String> recipientPhones = const [],
    String? message,
  }) async {
    final sosId = _uuid.v4();
    final sosData = {
      'id': sosId,
      'caseId': caseId,
      'caseName': caseName,
      'courtRoom': courtRoom,
      'courtComplex': courtComplex,
      'sentBy': sentById,
      'sentByName': sentByName,
      'recipientIds': recipientIds,
      'type': 'sos',
      'pushRequested': true,
      'message': message ?? 'Urgent help needed!',
      'timestamp': DateTime.now().toIso8601String(),
      'status': 'sent',
    };

    // Save locally always
    await HiveService.put(HiveService.sosBox, sosId, sosData);

    // ── Layer 1: Try online (Firestore → triggers FCM) ──
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity != ConnectivityResult.none) {
      try {
        await FirestoreService().sendSOS(sosData);
        debugPrint('SOS sent online via Firestore');
        return 'sent_online';
      } catch (e) {
        debugPrint('Online SOS failed: $e');
      }
    }

    // ── Layer 2: Try SMS ──
    final smsBody = '🆘 SOS! Help needed in $courtRoom at $courtComplex. '
        'Case: $caseName. -Synapse ($sentByName)';

    for (final phone in recipientPhones) {
      if (phone.isNotEmpty) {
        try {
          final uri = Uri(
            scheme: 'sms',
            path: phone,
            queryParameters: {'body': smsBody},
          );
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
            debugPrint('SOS sent via SMS to $phone');
            return 'sent_sms';
          }
        } catch (e) {
          debugPrint('SMS SOS failed for $phone: $e');
        }
      }
    }

    // ── Layer 3: Queue for later ──
    await SyncService.queueAction(
      action: 'CREATE',
      collection: 'sos_alerts',
      documentId: sosId,
      data: sosData,
    );

    // Show local notification as confirmation
    await NotificationService.show(
      title: '🆘 SOS Alert Queued',
      body: 'Alert for "$caseName" will be sent when signal is available.',
    );

    debugPrint('SOS queued for later delivery');
    return 'queued';
  }
}