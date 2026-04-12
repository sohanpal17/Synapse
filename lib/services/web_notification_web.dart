import 'dart:html' as html;
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;

Future<void> playWebSosBeep({int durationMs = 800}) async {
  try {
    const sampleRate = 44100;
    final sampleCount = (sampleRate * (durationMs / 1000)).round();
    final bytesPerSample = 2;
    final dataSize = sampleCount * bytesPerSample;
    final byteRate = sampleRate * bytesPerSample;
    final totalSize = 44 + dataSize;

    final bytes = Uint8List(totalSize);
    final bd = ByteData.view(bytes.buffer);

    void writeStr(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        bd.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    bd.setUint32(4, totalSize - 8, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // PCM chunk size
    bd.setUint16(20, 1, Endian.little); // PCM format
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, bytesPerSample, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    bd.setUint32(40, dataSize, Endian.little);

    const frequency = 880.0;
    const amplitude = 0.30;
    for (int i = 0; i < sampleCount; i++) {
      final t = i / sampleRate;
      final envelope = (1.0 - (i / sampleCount)).clamp(0.0, 1.0);
      final sample = (32767 * amplitude * envelope *
              math.sin(frequency * 2 * math.pi * t))
          .toInt();
      bd.setInt16(44 + (i * 2), sample, Endian.little);
    }

    final b64 = base64Encode(bytes);
    final audio = html.AudioElement('data:audio/wav;base64,$b64')
      ..volume = 1.0;
    await audio.play();
  } catch (_) {
    // Best effort web-only alert tone.
  }
}

Future<bool> ensureWebPushServiceWorkerReady({
  Duration timeout = const Duration(seconds: 8),
}) async {
  final serviceWorker = html.window.navigator.serviceWorker;
  if (serviceWorker == null) return false;

  try {
    await serviceWorker.register('/firebase-messaging-sw.js');
  } catch (_) {
    // Ignore registration races when another script already registered it.
  }

  try {
    final reg = await serviceWorker.ready.timeout(timeout);

    // Web push subscribe needs an active service worker. Requiring the worker
    // to control the current page can delay token sync until a manual refresh.
    final hasActiveWorker = reg.active != null;
    if (hasActiveWorker) {
      return true;
    }

    // Give a brief extra window for activation handoff.
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (reg.active != null) {
        return true;
      }
    }

    return false;
  } catch (_) {
    return false;
  }
}

Future<String> getWebNotificationPermissionStatus() async {
  if (!html.Notification.supported) return 'unsupported';
  return html.Notification.permission ?? 'default';
}

Future<String> ensureWebNotificationPermission({bool promptIfDefault = true}) async {
  if (!html.Notification.supported) return 'unsupported';
  String permission = html.Notification.permission ?? 'default';
  if (permission == 'default' && promptIfDefault) {
    permission = await html.Notification.requestPermission();
  }
  return permission;
}

Future<void> showWebBrowserNotification({
  required String title,
  required String body,
}) async {
  final permission = await ensureWebNotificationPermission();

  if (permission == 'granted') {
    html.Notification(
      title,
      body: body,
      icon: 'icons/Icon-192.png',
      tag: 'synapse-sos',
    );
  }
}
