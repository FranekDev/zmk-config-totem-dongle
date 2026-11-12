/*
 * Totem status: reports Win/Mac mode and split battery levels to the host
 * over raw HID (zmk-raw-hid), and lets the host switch Win/Mac mode.
 *
 * Every report is CONFIG_RAW_HID_REPORT_SIZE (32) bytes.
 *
 * Host -> keyboard:
 *   [0] 0xA7 magic
 *   [1] command: 0x01 GET_STATE, 0x02 SET_OS ([2] = 0 mac, 1 win), 0x03 TOGGLE_OS
 *
 * Keyboard -> host (sent on request and whenever something changes):
 *   [0]    0xA7 magic
 *   [1]    0x81 STATE
 *   [2]    protocol version (1)
 *   [3]    1 when the Windows layer is active
 *   [4]    highest active layer index
 *   [5..8] active layer bitmask, little endian
 *   [9]    N = number of peripheral slots
 *   [10..] battery % per peripheral slot (0 = disconnected / unknown)
 */

#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/logging/log.h>

#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/events/battery_state_changed.h>
#include <zmk/events/usb_conn_state_changed.h>
#include <zmk/keymap.h>

#include <raw_hid/events.h>

LOG_MODULE_REGISTER(totem_status, CONFIG_ZMK_LOG_LEVEL);

#define TS_MAGIC 0xA7
#define TS_PROTOCOL_VERSION 1

#define TS_CMD_GET_STATE 0x01
#define TS_CMD_SET_OS 0x02
#define TS_CMD_TOGGLE_OS 0x03

#define TS_REPORT_STATE 0x81

#define TS_WIN_LAYER CONFIG_TOTEM_STATUS_WIN_LAYER

#if defined(CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS)
#define TS_PERIPHERALS CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS
#else
#define TS_PERIPHERALS 0
#endif

#define TS_HEADER_LEN 10
BUILD_ASSERT(TS_HEADER_LEN + TS_PERIPHERALS <= CONFIG_RAW_HID_REPORT_SIZE,
             "Raw HID report too small for all peripheral battery levels");

static uint8_t battery_levels[TS_PERIPHERALS > 0 ? TS_PERIPHERALS : 1];
static int last_sent_win = -1;

/* ---- outgoing state ---------------------------------------------------- */

static void send_state(void) {
    /* Static: the USB driver may DMA from it after raise returns. */
    static uint8_t report[CONFIG_RAW_HID_REPORT_SIZE];
    memset(report, 0, sizeof(report));

    zmk_keymap_layers_state_t layers = zmk_keymap_layer_state();
    bool win = zmk_keymap_layer_active(TS_WIN_LAYER);

    report[0] = TS_MAGIC;
    report[1] = TS_REPORT_STATE;
    report[2] = TS_PROTOCOL_VERSION;
    report[3] = win ? 1 : 0;
    report[4] = zmk_keymap_highest_layer_active();
    report[5] = layers & 0xFF;
    report[6] = (layers >> 8) & 0xFF;
    report[7] = (layers >> 16) & 0xFF;
    report[8] = (layers >> 24) & 0xFF;
    report[9] = TS_PERIPHERALS;
    for (int i = 0; i < TS_PERIPHERALS; i++) {
        report[TS_HEADER_LEN + i] = battery_levels[i];
    }

    last_sent_win = win;
    raise_raw_hid_sent_event(
        (struct raw_hid_sent_event){.data = report, .length = sizeof(report)});
}

static void send_state_work_cb(struct k_work *work) { send_state(); }
static K_WORK_DELAYABLE_DEFINE(send_state_work, send_state_work_cb);

static void schedule_send(k_timeout_t delay) { k_work_reschedule(&send_state_work, delay); }

/* ---- incoming commands ------------------------------------------------- */

struct ts_command {
    uint8_t cmd;
    uint8_t arg;
};

K_MSGQ_DEFINE(ts_cmd_msgq, sizeof(struct ts_command), 4, 1);

static void command_work_cb(struct k_work *work) {
    struct ts_command c;
    while (k_msgq_get(&ts_cmd_msgq, &c, K_NO_WAIT) == 0) {
        switch (c.cmd) {
        case TS_CMD_GET_STATE:
            break;
        case TS_CMD_SET_OS:
            if (c.arg) {
                zmk_keymap_layer_activate(TS_WIN_LAYER, false);
            } else {
                zmk_keymap_layer_deactivate(TS_WIN_LAYER, false);
            }
            break;
        case TS_CMD_TOGGLE_OS:
            zmk_keymap_layer_toggle(TS_WIN_LAYER, false);
            break;
        default:
            LOG_WRN("Unknown totem status command 0x%02x", c.cmd);
            continue;
        }
        send_state();
    }
}
static K_WORK_DEFINE(command_work, command_work_cb);

/* ---- event listeners --------------------------------------------------- */

static int raw_hid_received_listener(const zmk_event_t *eh) {
    const struct raw_hid_received_event *ev = as_raw_hid_received_event(eh);
    if (ev == NULL || ev->length < 2 || ev->data[0] != TS_MAGIC) {
        return ZMK_EV_EVENT_BUBBLE;
    }

    /* May run in USB driver context: copy and defer the real work. */
    struct ts_command c = {.cmd = ev->data[1], .arg = ev->length > 2 ? ev->data[2] : 0};
    if (k_msgq_put(&ts_cmd_msgq, &c, K_NO_WAIT) == 0) {
        k_work_submit(&command_work);
    }
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(totem_status_raw_hid, raw_hid_received_listener);
ZMK_SUBSCRIPTION(totem_status_raw_hid, raw_hid_received_event);

static int state_listener(const zmk_event_t *eh) {
    const struct zmk_layer_state_changed *layer_ev = as_zmk_layer_state_changed(eh);
    if (layer_ev) {
        /* Only push when Win/Mac mode actually changed, not on every NAV/SYM tap. */
        if ((int)zmk_keymap_layer_active(TS_WIN_LAYER) != last_sent_win) {
            schedule_send(K_MSEC(20));
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

#if TS_PERIPHERALS > 0
    const struct zmk_peripheral_battery_state_changed *bat_ev =
        as_zmk_peripheral_battery_state_changed(eh);
    if (bat_ev) {
        if (bat_ev->source < TS_PERIPHERALS) {
            battery_levels[bat_ev->source] = bat_ev->state_of_charge;
            schedule_send(K_MSEC(100));
        }
        return ZMK_EV_EVENT_BUBBLE;
    }
#endif

    const struct zmk_usb_conn_state_changed *usb_ev = as_zmk_usb_conn_state_changed(eh);
    if (usb_ev) {
        /* Give the host time to enumerate before pushing the first report. */
        schedule_send(K_MSEC(1500));
        return ZMK_EV_EVENT_BUBBLE;
    }

    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(totem_status_state, state_listener);
ZMK_SUBSCRIPTION(totem_status_state, zmk_layer_state_changed);
#if TS_PERIPHERALS > 0
ZMK_SUBSCRIPTION(totem_status_state, zmk_peripheral_battery_state_changed);
#endif
ZMK_SUBSCRIPTION(totem_status_state, zmk_usb_conn_state_changed);
