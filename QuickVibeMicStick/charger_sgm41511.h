#pragma once

#include <stdint.h>
#include "sgm41511_regs.h"

struct Sgm41511Snapshot {
    bool reachable;
    bool configured;
    bool vbusGood;
    bool powerGood;
    bool thermalRegulation;
    bool vsysRegulation;
    bool vindpmActive;
    bool iindpmActive;
    uint8_t chargeState;  // 0=not charging, 1=precharge, 2=fast charge, 3=terminated
    uint8_t fault;
    sgm41511::NtcFault ntcFault;
    uint8_t partInfo;
    // Raw status bytes are retained for post-mortem power diagnostics. V14
    // also has a real GPIO7 battery ADC, so status and voltage complement each other.
    uint8_t reg08SystemStatus;
    uint8_t reg09FaultStatus;
    uint8_t reg0aInputStatus;
    uint32_t updatedMs;
};

// Starts GPIO8/GPIO40 I2C and applies the V14 charging policy. Safe to call on
// every cold boot; all writes are masked and verified.
bool sgm41511_begin(uint8_t sdaPin, uint8_t sclPin);
void sgm41511_tick();
const Sgm41511Snapshot &sgm41511_snapshot();

// Ship Mode is a two-phase irreversible operation. prepare configures and
// verifies immediate BATFET turn-off while BATFET_DIS remains clear. commit is
// the final I2C write; on success the battery rail disappears and normally no
// subsequent firmware instruction is observable.
bool sgm41511_prepare_ship_mode();
void sgm41511_cancel_ship_mode();
bool sgm41511_commit_ship_mode();

// Diagnostics/bring-up only.
bool sgm41511_read_register(uint8_t reg, uint8_t &value);
bool sgm41511_write_register(uint8_t reg, uint8_t value);
