/*
 * Runs on the halves: exposes the battery voltage (mV) measured by the
 * zmk,battery sensor as a read-only GATT characteristic, so the dongle can
 * pass it on to the host. Reads return the last sample ZMK took (every
 * CONFIG_ZMK_BATTERY_REPORT_INTERVAL), no extra ADC measurement is made.
 */

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/sys/byteorder.h>

#include <totem_status/uuids.h>

static const struct device *const battery = DEVICE_DT_GET(DT_CHOSEN(zmk_battery));

static ssize_t read_voltage(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                            uint16_t len, uint16_t offset) {
    struct sensor_value voltage;
    uint16_t mv = 0;

    if (device_is_ready(battery) &&
        sensor_channel_get(battery, SENSOR_CHAN_GAUGE_VOLTAGE, &voltage) == 0) {
        mv = voltage.val1 * 1000 + voltage.val2 / 1000;
    }

    uint16_t value = sys_cpu_to_le16(mv);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &value, sizeof(value));
}

/* "zz" so the service sorts after ZMK's own services and doesn't shift their handles. */
BT_GATT_SERVICE_DEFINE(zz_totem_battery_voltage_svc,
                       BT_GATT_PRIMARY_SERVICE(BT_UUID_DECLARE_128(
                           TOTEM_BATTERY_VOLTAGE_SERVICE_UUID)),
                       BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(
                                                  TOTEM_BATTERY_VOLTAGE_CHAR_UUID),
                                              BT_GATT_CHRC_READ, BT_GATT_PERM_READ_ENCRYPT,
                                              read_voltage, NULL, NULL));
