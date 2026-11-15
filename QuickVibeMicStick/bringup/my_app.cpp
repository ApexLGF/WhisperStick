#include <Arduino.h>
#include <TFT_eSPI.h>
#include <Adafruit_NeoPixel.h>
#include "pin_config.h"
#include "charger_sgm41511.h"

TFT_eSPI display;
Adafruit_NeoPixel pixels(4, PIN_LED_DIN, NEO_GRB + NEO_KHZ800);
int value = 0;
bool lastA = false;
bool lastB = false;
bool ready = false;
uint32_t lastScan = 0;

void redraw() {
    display.fillScreen(TFT_BLACK);
    display.setTextColor(TFT_WHITE, TFT_BLACK);
    display.setTextSize(2);
    display.setCursor(8, 20);
    display.println("My MicStick");
    display.setCursor(8, 60);
    display.printf("Value: %d", value);
}

void setup() {
    pinMode(PIN_PWR_KILL, OUTPUT);
    digitalWrite(PIN_PWR_KILL, LOW);
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
    digitalWrite(PIN_LCD_BL_LOCAL, LOW);
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);
    const bool chargerOK = sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);

    Serial.begin(115200);
    Serial.setTxTimeoutMs(0);
    pixels.begin();
    pixels.clear();
    pixels.show();
    if (!chargerOK) {
        Serial.println("Charger init failed; stop and check hardware.");
        return;
    }
    if (!sgm41511_snapshot().vbusGood) {
        digitalWrite(PIN_PWR_KILL, HIGH);  // 此示例仅在 USB 供电时运行。
        return;
    }
    pinMode(PIN_BUTTON, INPUT_PULLUP);
    pinMode(PIN_BUTTON_B, INPUT_PULLUP);
    display.init();
    display.setRotation(0);
    redraw();
    digitalWrite(PIN_LCD_BL_LOCAL, HIGH);
    ready = true;
}

void loop() {
    if (!ready) { delay(20); return; }
    sgm41511_tick();
    const auto &power = sgm41511_snapshot();
    if (!power.reachable || !power.configured || !power.vbusGood) {
        digitalWrite(PIN_LCD_BL_LOCAL, LOW);
        ready = false;
        digitalWrite(PIN_PWR_KILL, HIGH);
        return;
    }
    if (millis() - lastScan < 30) { delay(1); return; }
    lastScan = millis();
    const bool a = digitalRead(PIN_BUTTON) == LOW;
    const bool b = digitalRead(PIN_BUTTON_B) == LOW;
    const bool changed = (a && !lastA) || (b && !lastB);
    if (a && !lastA) ++value;
    if (b && !lastB) --value;
    lastA = a;
    lastB = b;
    if (changed) redraw();
}
