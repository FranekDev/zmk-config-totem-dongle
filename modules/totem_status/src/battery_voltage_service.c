/*
 * Runs on the halves: exposes the battery voltage (mV) measured by the
 * zmk,battery sensor as a read-only GATT characteristic, so the dongle can
 * pass it on to the host. Reads return the last sample taken (by ZMK or by
 * battery_sampler.c), no extra ADC measurement is made; the USB flag is live.
 *
 * Value: [0..1] voltage in mV, uint16 little endian
 *        [2]    flags, bit 0 = USB power present (VBUS). On USB the charger drives
 *               the battery pin, so the voltage (and %) says little about the cell.
 *               bit 1 = the charger is charging the cell, bit 2 = bit 1 is valid
 *               (charger status pin available). On USB with bit 1 clear: cell full.
 */

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/init.h>
#include <zephyr/sys/byteorder.h>

#include <totem_status/uuids.h>

#include "totem_power.h"

static const struct device *const battery = DEVICE_DT_GET(DT_CHOSEN(zmk_battery));

#define TOTEM_BATTERY_FLAG_USB BIT(0)
#define TOTEM_BATTERY_FLAG_CHARGING BIT(1)
#define TOTEM_BATTERY_FLAG_CHARGE_KNOWN BIT(2)

static ssize_t read_voltage(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                            uint16_t len, uint16_t offset) {
    struct sensor_value voltage;
    uint16_t mv = 0;

    if (device_is_ready(battery) &&
        sensor_channel_get(battery, SENSOR_CHAN_GAUGE_VOLTAGE, &voltage) == 0) {
        mv = voltage.val1 * 1000 + voltage.val2 / 1000;
    }

    uint8_t value[3];
    sys_put_le16(mv, value);
    value[2] = totem_usb_powered() ? TOTEM_BATTERY_FLAG_USB : 0;
    if (TOTEM_HAS_CHARGE_PIN) {
        value[2] |= TOTEM_BATTERY_FLAG_CHARGE_KNOWN;
        if (totem_charging()) {
            value[2] |= TOTEM_BATTERY_FLAG_CHARGING;
        }
    }
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}

/* "zz" so the service sorts after ZMK's own services and doesn't shift their handles. */
BT_GATT_SERVICE_DEFINE(zz_totem_battery_voltage_svc,
                       BT_GATT_PRIMARY_SERVICE(BT_UUID_DECLARE_128(
                           TOTEM_BATTERY_VOLTAGE_SERVICE_UUID)),
                       BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(
                                                  TOTEM_BATTERY_VOLTAGE_CHAR_UUID),
                                              BT_GATT_CHRC_READ, BT_GATT_PERM_READ_ENCRYPT,
                                              read_voltage, NULL, NULL));

static int totem_battery_voltage_init(void) { return totem_charge_pin_init(); }

SYS_INIT(totem_battery_voltage_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
