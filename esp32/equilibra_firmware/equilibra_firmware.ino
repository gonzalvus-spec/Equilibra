#include <Wire.h>
#include <math.h>
#include "BluetoothSerial.h"

BluetoothSerial SerialBT;

const int MPU_ADDR = 0x68;

int16_t ax, ay, az;

// =====================================================
// UMBRALES DE DETECCIÓN
// =====================================================

const float UMBRAL_CAIDA_LIBRE = 0.6;
const float UMBRAL_IMPACTO = 2.8;

// =====================================================
// VARIABLES DE DETECCIÓN
// =====================================================

bool detectoCaidaLibre = false;
unsigned long tiempoCaidaLibre = 0;

// =====================================================
// PINES
// =====================================================

const int pinPulsador = 23;
const int pinBuzzer = 4;

const int pinVerde = 17;
const int pinRojo = 5;
const int pinAzul = 18;

// =====================================================
// ESTADOS
// =====================================================

// 0 = Inicio
// 1 = Monitoreando
// 2 = Alarma

int estadoSistema = 0;

unsigned long tiempoInicioVerde = 0;
unsigned long tiempoUltimaLecturaMPU = 0;

// =====================================================
// ACTIVAR ALARMA
// =====================================================

void activarAlarma() {

  estadoSistema = 2;

  // LED rojo
  fijarColor(LOW, HIGH, HIGH);

  // Activar buzzer
  digitalWrite(pinBuzzer, LOW);

  // Enviar señal a App Inventor
  SerialBT.println("ACTIVADA");

  Serial.println("==============================");
  Serial.println("ALARMA ACTIVADA");
  Serial.println("Mensaje Bluetooth enviado: ACTIVADA");
  Serial.println("==============================");
}

// =====================================================
// DESACTIVAR ALARMA
// =====================================================

void desactivarAlarma() {

  estadoSistema = 1;

  // LED azul
  fijarColor(HIGH, HIGH, LOW);

  // Apagar buzzer
  digitalWrite(pinBuzzer, HIGH);

  // Reiniciar detección
  detectoCaidaLibre = false;

  // Enviar señal a App Inventor
  SerialBT.println("DESACTIVADA");

  Serial.println("Alarma desactivada.");
  Serial.println("Mensaje Bluetooth enviado: DESACTIVADA");
}

// =====================================================
// CONFIGURACIÓN
// =====================================================

void setup() {

  Serial.begin(115200);

  // Bluetooth: se mantiene el nombre original
  SerialBT.begin("Varayoc_ESP32");

  Serial.println("Bluetooth iniciado.");
  Serial.println("Nombre: Varayoc_ESP32");

  // MPU6050
  Wire.begin(21, 22);

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0);
  Wire.endTransmission(true);

  // Pines
  pinMode(pinPulsador, INPUT_PULLUP);

  pinMode(pinBuzzer, OUTPUT);
  digitalWrite(pinBuzzer, HIGH);

  pinMode(pinRojo, OUTPUT);
  pinMode(pinVerde, OUTPUT);
  pinMode(pinAzul, OUTPUT);

  // Estado inicial
  estadoSistema = 0;
  tiempoInicioVerde = millis();

  fijarColor(HIGH, LOW, HIGH);

  Serial.println("Sistema iniciado.");
  Serial.println("Estado VERDE durante 5 segundos.");
}

// =====================================================
// LOOP PRINCIPAL
// =====================================================

void loop() {

  unsigned long tiempoActual = millis();

  // ===================================================
  // 1. ESTADOS DEL SISTEMA
  // ===================================================

  switch (estadoSistema) {

    // -------------------------------------------------
    // ESTADO 0: INICIO
    // -------------------------------------------------

    case 0:

      fijarColor(HIGH, LOW, HIGH);
      digitalWrite(pinBuzzer, HIGH);

      if (tiempoActual - tiempoInicioVerde >= 5000) {

        estadoSistema = 1;

        fijarColor(HIGH, HIGH, LOW);

        Serial.println("Sistema en modo MONITOREO.");
      }

      break;

    // -------------------------------------------------
    // ESTADO 1: MONITOREO
    // -------------------------------------------------

    case 1:

      fijarColor(HIGH, HIGH, LOW);
      digitalWrite(pinBuzzer, HIGH);

      break;

    // -------------------------------------------------
    // ESTADO 2: ALARMA
    // -------------------------------------------------

    case 2:

      fijarColor(LOW, HIGH, HIGH);
      digitalWrite(pinBuzzer, LOW);

      // Apagar alarma con botón físico
      if (digitalRead(pinPulsador) == LOW) {

        Serial.println("Alarma apagada con botón físico.");

        desactivarAlarma();

        delay(300);
      }

      break;
  }

  // ===================================================
  // 2. LECTURA DEL MPU6050
  // ===================================================

  if (tiempoActual - tiempoUltimaLecturaMPU >= 50) {

    tiempoUltimaLecturaMPU = tiempoActual;

    Wire.beginTransmission(MPU_ADDR);
    Wire.write(0x3B);
    Wire.endTransmission(false);

    Wire.requestFrom(MPU_ADDR, 6, true);

    // Comprobar que se recibieron los 6 bytes
    if (Wire.available() >= 6) {

      ax = (int16_t)(Wire.read() << 8 | Wire.read());
      ay = (int16_t)(Wire.read() << 8 | Wire.read());
      az = (int16_t)(Wire.read() << 8 | Wire.read());

      float gX = ax / 16384.0;
      float gY = ay / 16384.0;
      float gZ = az / 16384.0;

      float gTotal = sqrt(
        gX * gX +
        gY * gY +
        gZ * gZ
      );

      // ===============================================
      // DETECTAR SOLO EN MODO MONITOREO
      // ===============================================

      if (estadoSistema == 1) {

        // PASO 1: CAÍDA LIBRE
        if (gTotal < UMBRAL_CAIDA_LIBRE) {

          detectoCaidaLibre = true;
          tiempoCaidaLibre = tiempoActual;

          Serial.println("Caida libre detectada.");
        }

        // Cancelar si pasan 700 ms (Intacto)
        if (
          detectoCaidaLibre &&
          tiempoActual - tiempoCaidaLibre > 700
        ) {

          detectoCaidaLibre = false;
        }

        // PASO 2: IMPACTO (Activa la alarma de inmediato)
        if (
          detectoCaidaLibre &&
          gTotal >= UMBRAL_IMPACTO
        ) {

          detectoCaidaLibre = false;

          Serial.println("Impacto detectado. CAIDA CONFIRMADA.");
          activarAlarma();
        }
      }
    }
  }

  // ===================================================
  // 3. RECIBIR COMANDOS DESDE APP INVENTOR
  // ===================================================

  if (SerialBT.available()) {

    String mensaje = SerialBT.readStringUntil('\n');
    mensaje.trim();

    Serial.print("Mensaje recibido de la app: ");
    Serial.println(mensaje);

    // La app puede enviar OFF para apagar la alarma
    if (
      mensaje == "OFF" &&
      estadoSistema == 2
    ) {

      desactivarAlarma();

      Serial.println("Alarma apagada desde Bluetooth.");
    }
  }
}

// =====================================================
// CONTROL DEL LED RGB
// =====================================================

void fijarColor(bool r, bool g, bool b) {

  digitalWrite(pinRojo, r);
  digitalWrite(pinVerde, g);
  digitalWrite(pinAzul, b);
}