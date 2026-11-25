# EQUILIBRA · Bluetooth clásico

Aplicación Flutter de asistencia inteligente que se comunica directamente con
un ESP32 mediante **Bluetooth clásico SPP/RFCOMM**. No usa Firebase, Wi-Fi, BLE,
mapas, historial ni servicios en segundo plano.

```text
Sensor SW-420 → ESP32 ── Bluetooth Classic (RFCOMM) ── App Flutter
```

## Flujo

1. Empareja el ESP32 desde los ajustes Bluetooth de Android.
2. Abre EQUILIBRA y elige el módulo en **Dispositivos emparejados**.
3. Conecta el socket SPP.
4. El ESP32 envía líneas `ACTIVADA` o `DESACTIVADA`.
5. **Desactivar alarma** envía la línea `OFF` al ESP32.

Una recepción `ACTIVADA` cambia la tarjeta principal, muestra una alerta y
publica una notificación en el canal `equilibra_alertas`.

## Estructura principal

```text
lib/
├── main.dart
├── app.dart
├── controllers/equilibra_controller.dart
├── models/
│   ├── alarm_status.dart
│   ├── bluetooth_status.dart
│   ├── device_info.dart
│   └── equilibra_event.dart
├── screens/home_screen.dart
├── services/
│   ├── bluetooth_service.dart
│   ├── bluetooth_failure.dart
│   ├── notification_service.dart
│   └── app_alerts.dart
└── widgets/
    ├── alarm_card.dart
    ├── bluetooth_card.dart
    ├── control_panel.dart
    └── device_picker_sheet.dart
```

`BluetoothService` usa `flutter_classic_bluetooth` para comprobar el adaptador,
listar equipos emparejados, abrir RFCOMM, reconstruir líneas y escribir comandos.
`EquilibraController` concentra el estado con `ChangeNotifier`.

## Android

La aplicación solicita `BLUETOOTH_CONNECT` en Android 12+ y conserva
`BLUETOOTH`/`BLUETOOTH_ADMIN` hasta Android 11. También declara
`POST_NOTIFICATIONS` y `VIBRATE`. No requiere Internet ni ubicación.

## Verificación

```bash
flutter pub get
dart format .
flutter analyze
flutter test
flutter build apk --release
```

El firmware SPP está en
`esp32/equilibra_firmware/equilibra_firmware.ino`.
