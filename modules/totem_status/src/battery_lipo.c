/*
 * Battery sensor wrapper: reads the voltage from another battery sensor and
 * converts it to a state of charge using a typical LiPo discharge curve.
 *
 * ZMK's own conversion is a straight line from 3.45 V (0%) to 4.2 V (100%),
 * which reads too high in the flat middle of the curve and hits 0% while the
 * cell still has usable charge left.
 */

#define DT_DRV_COMPAT totem_battery_lipo

#include <errno.h>

#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(totem_battery_lipo, CONFIG_SENSOR_LOG_LEVEL);

struct lipo_config {
    const struct device *source;
};

struct lipo_data {
    uint16_t millivolts;
    uint8_t state_of_charge;
};

/* Resting voltage -> state of charge of a typical single-cell LiPo, descending. */
static const struct {
    uint16_t mv;
    uint8_t pct;
} curve[] = {
    {4200, 100}, {4150, 95}, {4110, 90}, {4080, 85}, {4020, 80}, {3980, 75}, {3950, 70},
    {3910, 65},  {3870, 60}, {3850, 55}, {3840, 50}, {3820, 45}, {3800, 40}, {3790, 35},
    {3770, 30},  {3750, 25}, {3730, 20}, {3710, 15}, {3690, 10}, {3610, 5},  {3300, 0},
};

/* Readings per sample, each takes the source ~10 ms (voltage divider settle time). */
#define LIPO_READINGS 5

static uint8_t lipo_mv_to_pct(uint16_t mv) {
    if (mv >= curve[0].mv) {
        return 100;
    }
    for (size_t i = 1; i < ARRAY_SIZE(curve); i++) {
        if (mv >= curve[i].mv) {
            /* Linear interpolation between the two surrounding points. */
            uint32_t span_mv = curve[i - 1].mv - curve[i].mv;
            uint32_t span_pct = curve[i - 1].pct - curve[i].pct;
            return curve[i].pct + (mv - curve[i].mv) * span_pct / span_mv;
        }
    }
    return 0;
}

static int lipo_sample_fetch(const struct device *dev, enum sensor_channel chan) {
    const struct lipo_config *cfg = dev->config;
    struct lipo_data *data = dev->data;

    if (chan != SENSOR_CHAN_GAUGE_VOLTAGE && chan != SENSOR_CHAN_GAUGE_STATE_OF_CHARGE &&
        chan != SENSOR_CHAN_ALL) {
        return -ENOTSUP;
    }
    if (!device_is_ready(cfg->source)) {
        return -ENODEV;
    }

    /* Median of a few readings: a single off reading (ADC calibration on the first
     * conversion, a radio burst pulling the cell down) must not become the result. */
    uint16_t mv[LIPO_READINGS];
    for (size_t i = 0; i < ARRAY_SIZE(mv); i++) {
        int rc = sensor_sample_fetch_chan(cfg->source, SENSOR_CHAN_GAUGE_VOLTAGE);
        if (rc != 0) {
            return rc;
        }

        struct sensor_value voltage;
        rc = sensor_channel_get(cfg->source, SENSOR_CHAN_GAUGE_VOLTAGE, &voltage);
        if (rc != 0) {
            return rc;
        }

        /* Insert in ascending order. */
        uint16_t v = voltage.val1 * 1000 + voltage.val2 / 1000;
        size_t j = i;
        for (; j > 0 && mv[j - 1] > v; j--) {
            mv[j] = mv[j - 1];
        }
        mv[j] = v;
    }

    data->millivolts = mv[ARRAY_SIZE(mv) / 2];
    data->state_of_charge = lipo_mv_to_pct(data->millivolts);
    LOG_DBG("%d mV => %d%%", data->millivolts, data->state_of_charge);
    return 0;
}

static int lipo_channel_get(const struct device *dev, enum sensor_channel chan,
                            struct sensor_value *val) {
    const struct lipo_data *data = dev->data;

    switch (chan) {
    case SENSOR_CHAN_GAUGE_VOLTAGE:
        val->val1 = data->millivolts / 1000;
        val->val2 = (data->millivolts % 1000) * 1000;
        return 0;
    case SENSOR_CHAN_GAUGE_STATE_OF_CHARGE:
        val->val1 = data->state_of_charge;
        val->val2 = 0;
        return 0;
    default:
        return -ENOTSUP;
    }
}

static const struct sensor_driver_api lipo_api = {
    .sample_fetch = lipo_sample_fetch,
    .channel_get = lipo_channel_get,
};

static int lipo_init(const struct device *dev) { return 0; }

#define LIPO_INIT(n)                                                                              \
    static struct lipo_data lipo_data_##n;                                                        \
    static const struct lipo_config lipo_config_##n = {                                           \
        .source = DEVICE_DT_GET(DT_INST_PHANDLE(n, battery)),                                     \
    };                                                                                            \
    DEVICE_DT_INST_DEFINE(n, lipo_init, NULL, &lipo_data_##n, &lipo_config_##n, POST_KERNEL,      \
                          CONFIG_SENSOR_INIT_PRIORITY, &lipo_api);

DT_INST_FOREACH_STATUS_OKAY(LIPO_INIT)
