/*
 * GATT UUIDs shared by the halves (battery voltage service) and the dongle.
 */

#pragma once

#include <zephyr/bluetooth/uuid.h>

/* 7a6c3e10-5b2d-4f8e-9a41-c3d2e1f0a000 */
#define TOTEM_BATTERY_VOLTAGE_SERVICE_UUID                                                        \
    BT_UUID_128_ENCODE(0x7a6c3e10, 0x5b2d, 0x4f8e, 0x9a41, 0xc3d2e1f0a000)

/* 7a6c3e10-5b2d-4f8e-9a41-c3d2e1f0a001: battery voltage in mV, uint16 little endian */
#define TOTEM_BATTERY_VOLTAGE_CHAR_UUID                                                           \
    BT_UUID_128_ENCODE(0x7a6c3e10, 0x5b2d, 0x4f8e, 0x9a41, 0xc3d2e1f0a001)
