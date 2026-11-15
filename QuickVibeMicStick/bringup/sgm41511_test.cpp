#include <Arduino.h>

#include "charger_sgm41511.h"
#include "pin_config.h"
#include "sgm41511_regs.h"

void setup() {
    pinMode(PIN_PWR_KILL, OUTPUT);
    digitalWrite(PIN_PWR_KILL, LOW);
    pinMode(PIN_LCD_BL_LOCAL, OUTPUT);
    digitalWrite(PIN_LCD_BL_LOCAL, LOW);
    pinMode(PIN_LED_DIN, OUTPUT);
    digitalWrite(PIN_LED_DIN, LOW);
    pinMode(PIN_BUZZER, OUTPUT);
    digitalWrite(PIN_BUZZER, LOW);

    Serial.begin(115200);
    Serial.setTxTimeoutMs(0);
    delay(50);
    Serial.println("[bringup] SGM41511 V13 power test");
    sgm41511_begin(PIN_CHARGER_SDA, PIN_CHARGER_SCL);
}

void loop() {
    sgm41511_tick();
    static uint32_t lastPrintMs = 0;
    if (millis() - lastPrintMs >= 1000) {
        lastPrintMs = millis();
        const Sgm41511Snapshot &s = sgm41511_snapshot();
        Serial.printf("reachable=%u configured=%u vbus=%u pg=%u chg=%u "
                      "vsys=%u therm=%u vindpm=%u iindpm=%u fault=0x%02X id=0x%02X\n",
                      s.reachable, s.configured, s.vbusGood, s.powerGood,
                      s.chargeState, s.vsysRegulation, s.thermalRegulation,
                      s.vindpmActive, s.iindpmActive, s.fault, s.partInfo);
        for (uint8_t reg = 0; reg < sgm41511::kRegisterCount; ++reg) {
            uint8_t value = 0;
            if (sgm41511_read_register(reg, value)) {
                Serial.printf("%02X:%02X%c", reg, value,
                              reg + 1 == sgm41511::kRegisterCount ? '\n' : ' ');
            }
        }
    }
    delay(10);
}
