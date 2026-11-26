# AGENTS.md — Mapa de contexto EQUILIBRA

Aplicación Android para detectar caídas con un ESP32 y supervisarlas desde uno o dos teléfonos. Un teléfono actúa como puente Bluetooth–Firebase y otro puede operar como monitor remoto.

## Stack y herramientas

- **App:** Dart `^3.13.0`, Flutter/Material y Android (Gradle Kotlin DSL, Java 17).
- **Firmware:** Arduino/C++ para ESP32, `BluetoothSerial`, I²C y sensor MPU6050.
- **Estado:** `ChangeNotifier`, `AnimatedBuilder` e inyección por constructor; sin gestor externo.
- **Datos:** Firebase Authentication/Realtime Database (`firebase_auth`, `firebase_core`, `firebase_database`) y `shared_preferences`.
- **Dispositivo:** `flutter_classic_bluetooth` (SPP/RFCOMM), `geolocator` y `device_info_plus`.
- **UI:** `flutter_map` + OpenStreetMap, `latlong2`, `intl`, `cool_alert` y `flutter_local_notifications`.
- **Pruebas/calidad:** `flutter_test` y `flutter_lints`.
- `third_party/flare_flutter/` es un parche local requerido por `cool_alert`; no eliminar.

## Arquitectura

```text
lib/
├── main.dart                         # Inicializa servicios y decide entre autenticación o app.
├── app.dart                          # Raíz, selección de modo e inyección de controladores/servicios.
├── controllers/
│   ├── bridge_controller.dart        # Estado y coordinación Bluetooth–ubicación–Firebase del puente.
│   ├── monitor_controller.dart       # Estado remoto, historial, alertas y orden de apagado.
│   └── terminal_controller.dart      # Presencia, roles, revocación y cierre remoto de terminales.
├── screens/
│   ├── mode_selection_screen.dart    # Selección entre estación base y monitor remoto.
│   ├── auth_screen.dart              # Inicio de sesión y registro con correo/contraseña.
│   ├── bluetooth_scan_sheet.dart     # Modal de escaneo, emparejamiento y conexión SPP.
│   ├── linked_devices_sheet.dart     # Gestión de celulares vinculados a la cuenta.
│   ├── bridge_screen.dart            # Conexión local, alarma, ubicación y controles del ESP32.
│   └── monitor_screen.dart           # Vistas de alarma, mapa e historial remoto.
├── services/
│   ├── bluetooth_service.dart        # Descubre el ESP32 emparejado y gestiona SPP/RFCOMM por líneas.
│   ├── firebase_service.dart         # Lectura/escritura de estado, órdenes, presencia e historial.
│   ├── location_service.dart         # Permisos y posición actual del teléfono puente.
│   ├── notification_service.dart     # Permisos y notificaciones locales de alarma.
│   ├── mode_preferences.dart         # Persistencia local del modo elegido.
│   ├── bluetooth_preferences.dart    # Último dispositivo Bluetooth seleccionado.
│   ├── auth_service.dart             # Acceso a Firebase Authentication.
│   ├── terminal_service.dart         # Identidad y presencia de celulares por usuario.
│   ├── app_alerts.dart               # Diálogos visuales con cool_alert.
│   ├── app_permissions.dart          # Solicitud ordenada de notificaciones, ubicación y Bluetooth.
│   ├── background_service.dart       # Configuración/control del servicio en primer plano.
│   ├── android_background_service_client.dart # Canal nativo Android del servicio en segundo plano.
│   ├── background_runtime.dart       # Isolate del servicio: RFCOMM, GPS, latidos y listener remoto.
│   ├── bluetooth_failure.dart        # Error de dominio para operaciones Bluetooth.
│   └── app_logger.dart               # Singleton del historial interno (300 registros con ValueNotifier) y API info/ok/warn/error.
├── models/                           # Modelos inmutables de modo, estados, ubicación, eventos, resultados y LogEntry/LogLevel.
├── widgets/                          # Tarjetas, selector Bluetooth, orbe animado y visor de registros (LogViewerButton/LogViewerSheet).
└── core/
    ├── app_constants.dart            # Nombre Bluetooth, comando OFF y rutas/URL de Firebase.
    ├── background_keys.dart          # Claves de mensajería y canal del servicio en primer plano.
    └── app_theme.dart                # Tema, colores y estilos Material.
firebase/database.rules.json          # Acceso privado a datos por UID autenticado.
esp32/equilibra_firmware/
└── equilibra_firmware.ino            # Detección MPU6050, alarma física y protocolo Bluetooth.
assets/images/logo.png                # Logo de la aplicación.
test/widget_test.dart                 # Prueba del formulario de autenticación.
third_party/flare_flutter/            # Dependencia vendorizada y parcheada.
```

## Flujo de datos / comunicación

- El ESP32 detecta caída/impacto y envía `ACTIVADA` o `DESACTIVADA` al teléfono puente mediante Bluetooth clásico SPP/RFCOMM.
- Firebase Authentication limita la app a una sesión válida y todos los datos viven bajo `usuarios/{uid}`.
- Cada celular mantiene presencia y rol en `terminales/{terminalId}`; una revocación remota cierra su sesión.
- `BridgeController` procesa esas líneas, obtiene la ubicación y publica alarma, presencia, latidos e historial en Firebase Realtime Database. El servicio en primer plano (`flutter_background_service`) mantiene RFCOMM, GPS y el listener remoto cuando la app no está visible.
- `MonitorController` escucha en tiempo real el estado y los últimos 100 eventos de Firebase; el mapa consume teselas externas de OpenStreetMap.
- El monitor solicita apagar escribiendo `comandos/off_request`; el puente envía `OFF` al ESP32 y confirma eliminando la solicitud.
- Ambos modos generan alertas/notificaciones locales; `shared_preferences` conserva el modo y el identificador persistente del terminal.

## Comandos del proyecto

```bash
flutter pub get
flutter run
dart format .
flutter analyze
flutter test
flutter build apk --release
```

## Reglas para el agente

- Ir directo a los archivos indicados en el prompt sin escanear todo el repositorio innecesariamente.
- Respetar el tipado estricto y las convenciones existentes en el proyecto.
- Mantener null-safety, modelos inmutables, `ChangeNotifier` e inyección por constructor.
- No sustituir Bluetooth clásico SPP/RFCOMM por BLE sin una solicitud explícita.
- Actualizar este `AGENTS.md` únicamente cuando se agreguen módulos, rutas o carpetas principales nuevas.
