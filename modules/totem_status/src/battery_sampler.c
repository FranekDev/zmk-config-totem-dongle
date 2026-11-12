/*
 * Runs on the halves: keeps the battery reading fresh.
 *
 * ZMK samples the battery once at boot and then every
 * CONFIG_ZMK_BATTERY_REPORT_INTERVAL (60 s), and not at all while the half is
 * idle. One off reading (e.g. the very first one after boot) therefore stays on
 * screen for a minute or more, and plugging/unplugging the cable is only
 * noticed at the next sample.
 *
 * This samples on its own schedule instead: a quick burst after boot and after
 * every USB power change, then every TOTEM_BATTERY_SAMPLER_INTERVAL seconds,
 * idle or not. New values go out the same way ZMK's do (BAS + battery event).
 */

#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/event_manager.h>
#include <zmk/events/battery_state_changed.h>
#include <zmk/workqueue.h>

#include "totem_power.h"

LOG_MODULE_REGISTER(totem_battery_sampler, CONFIG_ZMK_LOG_LEVEL);

static const struct device *const battery = DEVICE_DT_GET(DT_CHOSEN(zmk_battery));

/* How often USB power is checked (no measurement, just a register read). */
#define TICK_MS 2000
/* Gaps between the samples of a burst, in seconds: the reading settles within
 * seconds after boot or after the charger lets go of the cell. */
static const uint8_t burst_s[] = {2, 3, 5, 10, 20};

static uint8_t burst_pos;
static bool last_usb;
static int64_t next_sample_at;

static void sample(void) {
    struct sensor_value soc;
    int rc = sensor_sample_fetch_chan(battery, SENSOR_CHAN_GAUGE_STATE_OF_CHARGE);
    if (rc == 0) {
        rc = sensor_channel_get(battery, SENSOR_CHAN_GAUGE_STATE_OF_CHARGE, &soc);
    }
    if (rc != 0) {
        LOG_DBG("Battery sample failed: %d", rc);
        return;
    }

    uint8_t level = CLAMP(soc.val1, 0, 100);
    if (bt_bas_get_battery_level() != level) {
        bt_bas_set_battery_level(level);
        raise_zmk_battery_state_changed((struct zmk_battery_state_changed){.state_of_charge = level});
    }
}

static void sampler_work_cb(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(sampler_work, sampler_work_cb);

static void sampler_work_cb(struct k_work *work) {
    int64_t now = k_uptime_get();

    bool usb = totem_usb_powered();
    if (usb != last_usb) {
        /* Cable plugged or pulled: the voltage is about to jump. */
        last_usb = usb;
        burst_pos = 0;
        next_sample_at = now + 500;
    }

    if (now >= next_sample_at) {
        sample();
        uint32_t gap_s = burst_pos < ARRAY_SIZE(burst_s) ? burst_s[burst_pos++]
                                                         : CONFIG_TOTEM_BATTERY_SAMPLER_INTERVAL;
        next_sample_at = k_uptime_get() + gap_s * MSEC_PER_SEC;
    }

    int64_t wait = CLAMP(next_sample_at - k_uptime_get(), 10, TICK_MS);
    k_work_schedule_for_queue(zmk_workqueue_lowprio_work_q(), &sampler_work, K_MSEC(wait));
}

static int sampler_init(void) {
    if (!device_is_ready(battery)) {
        return -ENODEV;
    }
    last_usb = totem_usb_powered();
    /* ZMK takes its own first sample right at boot; ours follows shortly after. */
    next_sample_at = k_uptime_get() + burst_s[0] * MSEC_PER_SEC;
    burst_pos = 1;
    k_work_schedule_for_queue(zmk_workqueue_lowprio_work_q(), &sampler_work, K_MSEC(TICK_MS));
    return 0;
}

SYS_INIT(sampler_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
