import 'package:cloud_functions/cloud_functions.dart';

class AdminService {
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'asia-south1');

  Future<List<Map<String, dynamic>>> listPendingRequests() async {
    final result = await _functions.httpsCallable('adminListOnboardingRequests').call({
      'status': 'pending',
      'limit': 200,
    });

    final data = result.data;
    if (data is! Map) return const [];
    final items = data['items'];
    if (items is! List) return const [];

    return items
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> approveUser(String uid) async {
    await _functions.httpsCallable('adminModerateUser').call({
      'action': 'approve',
      'targetUid': uid,
    });
  }

  Future<void> rejectUser(String uid) async {
    await _functions.httpsCallable('adminModerateUser').call({
      'action': 'reject',
      'targetUid': uid,
    });
  }

  Future<void> deleteUser(String uid) async {
    await _functions.httpsCallable('adminModerateUser').call({
      'action': 'delete',
      'targetUid': uid,
    });
  }
}
