import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_background_service_platform_interface/flutter_background_service_platform_interface.dart';

/// Cliente del servicio en segundo plano limitado al canal nativo de Android.
class AndroidBackgroundServiceClient {
  static const MethodChannel _methodChannel = MethodChannel(
    'id.flutter/background_service/android/method',
    JSONMethodCodec(),
  );
  static const EventChannel _eventChannel = EventChannel(
    'id.flutter/background_service/android/event',
    JSONMethodCodec(),
  );

  final StreamController<dynamic> _events = StreamController.broadcast(
    sync: true,
  );
  StreamSubscription<dynamic>? _eventSubscription;

  Future<void> configure(AndroidConfiguration configuration) async {
    _methodChannel.setMethodCallHandler((call) async {
      if (call.method == 'onReceiveData') {
        _events.add(call.arguments);
      }
    });

    await _eventSubscription?.cancel();
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _events.add,
    );

    final callback = PluginUtilities.getCallbackHandle(configuration.onStart);
    if (callback == null) {
      throw StateError('onStart debe ser una función global o estática.');
    }

    await _methodChannel.invokeMethod<bool>('configure', {
      'background_handle': callback.toRawHandle(),
      'is_foreground_mode': configuration.isForegroundMode,
      'auto_start': configuration.autoStart,
      'auto_start_on_boot': configuration.autoStartOnBoot,
      'initial_notification_content': configuration.initialNotificationContent,
      'initial_notification_title': configuration.initialNotificationTitle,
      'notification_channel_id': configuration.notificationChannelId,
      'foreground_notification_id':
          configuration.foregroundServiceNotificationId,
      'foreground_service_types': configuration.foregroundServiceTypes
          ?.map((type) => type.name)
          .toList(),
    });
  }

  Future<bool> startService() async =>
      await _methodChannel.invokeMethod<bool>('start') ?? false;

  Future<bool> isRunning() async =>
      await _methodChannel.invokeMethod<bool>('isServiceRunning') ?? false;

  void invoke(String method, [Map<String, dynamic>? arguments]) {
    _methodChannel.invokeMethod<void>('sendData', {
      'method': method,
      'args': arguments,
    });
  }

  Stream<Map<String, dynamic>?> on(String method) {
    return _events.stream
        .where((event) => event is Map && event['method'] == method)
        .map((event) {
          final arguments = (event as Map)['args'];
          return arguments == null
              ? null
              : Map<String, dynamic>.from(arguments as Map);
        });
  }
}
