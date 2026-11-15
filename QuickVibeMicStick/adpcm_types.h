#ifndef ADPCM_TYPES_H
#define ADPCM_TYPES_H

#include <stdint.h>

typedef struct {
    int16_t prevSample;
    int8_t  index;
} ADPCMState;

#endif
