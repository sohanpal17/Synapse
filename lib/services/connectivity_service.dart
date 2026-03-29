import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Provides a stream of connectivity changes (true = online, false = offline)
class ConnectivityService {
  static final Connectivity _connectivity = Connectivity();

  /// Stream that emits true when online, false when offline
  static Stream<bool> get onConnectivityChanged {
    return _connectivity.onConnectivityChanged.map(
      (result) => result != ConnectivityResult.none,
    );
  }

  /// Check current connectivity status
  static Future<bool> get isOnline async {
    final result = await _connectivity.checkConnectivity();
    return result != ConnectivityResult.none;
  }
}