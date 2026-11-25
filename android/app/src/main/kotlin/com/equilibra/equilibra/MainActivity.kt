package com.equilibra.equilibra

import io.flutter.embedding.android.FlutterActivity

/**
 * Actividad principal.
 *
 * Subclase estándar de `FlutterActivity`: no sobrescribe `configureFlutterEngine`
 * ni `provideFlutterEngine`, y no ejecuta llamadas nativas (wakelocks, flags de
 * ventana, permisos) durante `onCreate`, para que el motor de Flutter pueda
 * crear el isolate y dibujar su primer frame sin interferencias.
 *
 * La pantalla de alarma sobre el bloqueo la resuelve la notificación con
 * `fullScreenIntent` (ver `NotificationService`), no esta actividad.
 */
class MainActivity : FlutterActivity()
