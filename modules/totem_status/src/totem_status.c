/*
 * Totem status: reports Win/Mac mode and split battery levels to the host
 * over raw HID (zmk-raw-hid), and lets the host switch Win/Mac mode.
 *
 * Every report is CONFIG_RAW_HID_REPORT_SIZE (32) bytes.
 *
 * Host -> keyboard:
 *   [0] 0xA7 magic
 *   [1] command: 0x01 GET_STATE, 0x02 SET_OS ([2] = 0 mac, 1 win), 0x03 TOGGLE_OS,
 *       0x04 GET_KEY_STATS ([2] = chunk index)
 *
 * Keyboard -> host (sent on request and whenever something changes):
 *   [0]    0xA7 magic
 *   [1]    0x81 STATE
 *   [2]    protocol version (6)
 *   [3]    1 when the Windows layer is active
 *   [4]    highest active layer index
 *   [5..8] active layer bitmask, little endian
 *   [9]    N = number of peripheral slots
 *   [10..] battery % per peripheral slot (0 = empty, disconnected or unknown)
 *   [10+N] bitmask of connected peripheral slots (v2+)
 *   [11+N] peripheral slot of the LEFT half, 0xFF while unknown (v3+); learned from
 *          the first key press on a half, since slots follow pairing order
 *   [12+N..] battery voltage in mV per peripheral slot, uint16 little endian,
 *          0 = unknown (v4+, needs the halves to run TOTEM_BATTERY_VOLTAGE_SERVICE)
 *   [12+3N] bitmask of peripheral slots running on USB power (v5+); the battery
 *          reading of such a half is the charger's voltage, not the cell's
 *   [13+3N..] RSSI of each half's link in dBm, int8, 0 = unknown (v6+)
 *
 * Key press counts (reply to GET_KEY_STATS, v6+):
 *   [0]    0xA7 magic
 *   [1]    0x82 KEY_STATS
 *   [2..5] boot id, uint32 LE: random per dongle boot; counts restart from 0 when it changes
 *   [6]    total number of key positions
 *   [7]    first position in this chunk
 *   [8]    number of positions in this chunk (0 when the chunk index is past the end)
 *   [9..]  press count per position, uint32 LE, cumulative since boot
 * Only positions are counted (no order or timing), like a per-key odometer.
 */

#include <stdlib.h>
#include <string.h>

#include <zephyr/sys/byteorder.h>

#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/logging/log.h>

#include <zmk/event_manager.h>
#include <zmk/events/layer_state_changed.h>
#include <zmk/events/battery_state_changed.h>
#include <zmk/events/usb_conn_state_changed.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/keymap.h>
#include <zmk/matrix.h>

#if __has_include(<zephyr/random/random.h>)
#include <zephyr/random/random.h>
#else
#include <zephyr/random/rand32.h>
#endif

#include <raw_hid/events.h>

#include <totem_status/uuids.h>

#if IS_ENABLED(CONFIG_ZMK_SPLIT_BLE)
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/uuid.h>
#include <zmk/ble.h>
#endif

LOG_MODULE_REGISTER(totem_status, CONFIG_ZMK_LOG_LEVEL);

#define TS_MAGIC 0xA7
#define TS_PROTOCOL_VERSION 6

#define TS_CMD_GET_STATE 0x01
#define TS_CMD_SET_OS 0x02
#define TS_CMD_TOGGLE_OS 0x03
#define TS_CMD_GET_KEY_STATS 0x04

#define TS_REPORT_STATE 0x81
#define TS_REPORT_KEY_STATS 0x82

#define TS_WIN_LAYER CONFIG_TOTEM_STATUS_WIN_LAYER

#if defined(CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS)
#define TS_PERIPHERALS CONFIG_ZMK_SPLIT_BLE_CENTRAL_PERIPHERALS
#else
#define TS_PERIPHERALS 0
#endif

#define TS_HEADER_LEN 10
#define TS_VOLTAGE_OFFSET (TS_HEADER_LEN + TS_PERIPHERALS + 2)
#define TS_USB_OFFSET (TS_VOLTAGE_OFFSET + 2 * TS_PERIPHERALS)
#define TS_RSSI_OFFSET (TS_USB_OFFSET + 1)
BUILD_ASSERT(TS_RSSI_OFFSET + TS_PERIPHERALS <= CONFIG_RAW_HID_REPORT_SIZE,
             "Raw HID report too small for all peripheral battery levels");

static uint8_t battery_levels[TS_PERIPHERALS > 0 ? TS_PERIPHERALS : 1];
static uint16_t battery_mv[TS_PERIPHERALS > 0 ? TS_PERIPHERALS : 1];
static uint8_t usb_powered_mask;
static int8_t link_rssi[TS_PERIPHERALS > 0 ? TS_PERIPHERALS : 1];

/* ---- key press counts -------------------------------------------------- */

#define TS_KEY_POSITIONS ZMK_KEYMAP_LEN
BUILD_ASSERT(TS_KEY_POSITIONS <= 255, "Too many key positions for the key stats report");
#define TS_KEY_STATS_HEADER 9
#define TS_KEY_STATS_PER_CHUNK ((CONFIG_RAW_HID_REPORT_SIZE - TS_KEY_STATS_HEADER) / 4)

static uint32_t key_presses[TS_KEY_POSITIONS];
static uint32_t boot_id;
static zmk_keymap_layers_state_t last_sent_layers;

/*
 * Key positions (physical layout order, see totem-layouts.dtsi) on the left half:
 * 0-4, 10-14, 20-25 (incl. the outer pinky key), 32-34.
 */
#define TS_LEFT_POSITIONS                                                                         \
    ((uint64_t)BIT64_MASK(5) | (BIT64_MASK(5) << 10) | (BIT64_MASK(6) << 20) |                     \
     (BIT64_MASK(3) << 32))
#define TS_SLOT_UNKNOWN 0xFF
static uint8_t left_slot = TS_SLOT_UNKNOWN;

/* ---- peripheral connections -------------------------------------------- */

#if TS_PERIPHERALS > 0 && IS_ENABLED(CONFIG_ZMK_SPLIT_BLE)
/* Peripheral slot of a connection we initiated (= a split half), or -1. */
static int peripheral_slot(struct bt_conn *conn) {
    struct bt_conn_info info;
    if (bt_conn_get_info(conn, &info) != 0 || info.role != BT_CONN_ROLE_CENTRAL ||
        info.state != BT_CONN_STATE_CONNECTED) {
        return -1;
    }
    /* Returns the existing slot index for an already bonded peripheral, like ZMK does. */
    int slot = zmk_ble_put_peripheral_addr(bt_conn_get_dst(conn));
    return (slot >= 0 && slot < TS_PERIPHERALS) ? slot : -1;
}

static void mark_connected(struct bt_conn *conn, void *user_data) {
    int slot = peripheral_slot(conn);
    if (slot >= 0) {
        *(uint8_t *)user_data |= BIT(slot);
    }
}

static uint8_t connected_mask(void) {
    uint8_t mask = 0;
    bt_conn_foreach(BT_CONN_TYPE_LE, mark_connected, &mask);
    return mask;
}
#else
static uint8_t connected_mask(void) { return 0; }
#endif

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
    uint8_t connected = connected_mask();
    report[TS_HEADER_LEN + TS_PERIPHERALS] = connected;
    report[TS_HEADER_LEN + TS_PERIPHERALS + 1] = left_slot;
    for (int i = 0; i < TS_PERIPHERALS; i++) {
        if (!(connected & BIT(i))) {
            battery_mv[i] = 0; /* stale once the half is gone */
            usb_powered_mask &= ~BIT(i);
            link_rssi[i] = 0;
        }
        sys_put_le16(battery_mv[i], &report[TS_VOLTAGE_OFFSET + 2 * i]);
        report[TS_RSSI_OFFSET + i] = (uint8_t)link_rssi[i];
    }
    report[TS_USB_OFFSET] = usb_powered_mask;

    last_sent_layers = layers;
    raise_raw_hid_sent_event(
        (struct raw_hid_sent_event){.data = report, .length = sizeof(report)});
}

static void send_key_stats(uint8_t chunk) {
    /* Static: the USB driver may DMA from it after raise returns. The host asks for
     * one chunk at a time and waits for the reply, so it is never reused too early. */
    static uint8_t report[CONFIG_RAW_HID_REPORT_SIZE];
    memset(report, 0, sizeof(report));

    uint32_t first = (uint32_t)chunk * TS_KEY_STATS_PER_CHUNK;
    uint32_t count =
        first < TS_KEY_POSITIONS ? MIN(TS_KEY_STATS_PER_CHUNK, TS_KEY_POSITIONS - first) : 0;
    report[0] = TS_MAGIC;
    report[1] = TS_REPORT_KEY_STATS;
    sys_put_le32(boot_id, &report[2]);
    report[6] = TS_KEY_POSITIONS;
    report[7] = MIN(first, 255);
    report[8] = count;
    for (uint32_t i = 0; i < count; i++) {
        sys_put_le32(key_presses[first + i], &report[TS_KEY_STATS_HEADER + 4 * i]);
    }
    raise_raw_hid_sent_event(
        (struct raw_hid_sent_event){.data = report, .length = sizeof(report)});
}

static void send_state_work_cb(struct k_work *work) { send_state(); }
static K_WORK_DELAYABLE_DEFINE(send_state_work, send_state_work_cb);

static void schedule_send(k_timeout_t delay) { k_work_reschedule(&send_state_work, delay); }

/* ---- own battery polling ----------------------------------------------
 *
 * Workaround for ZMK main: after a half reconnects (e.g. wakes from sleep) the
 * central keeps a stale battery characteristic handle, stops GATT discovery
 * early and never reads/subscribes the battery level again, so it stays 0.
 * We read the Battery Level characteristic by UUID ourselves on a timer, plus
 * the battery voltage our halves expose (TOTEM_BATTERY_VOLTAGE_SERVICE).
 */
#if TS_PERIPHERALS > 0 && IS_ENABLED(CONFIG_ZMK_SPLIT_BLE)

/* The halves sample their battery every CONFIG_ZMK_BATTERY_REPORT_INTERVAL (60 s by default). */
#define TS_BATTERY_POLL_INTERVAL K_SECONDS(60)
#define TS_BATTERY_READ_TIMEOUT_MS 10000

struct ts_read {
    struct bt_gatt_read_params params;
    const struct bt_uuid *uuid;
    void (*handle)(uint8_t slot, const uint8_t *data, uint16_t length);
    uint8_t slot;
    bool busy;
    int64_t started;
};

static void handle_level(uint8_t slot, const uint8_t *data, uint16_t length) {
    /* 0 is a valid reading too: a nearly empty half reports 0%. */
    uint8_t level = data[0];
    if (level <= 100 && battery_levels[slot] != level) {
        LOG_DBG("Polled battery level %d%% for peripheral %d", level, slot);
        battery_levels[slot] = level;
        schedule_send(K_MSEC(100));
    }
}

static void handle_voltage(uint8_t slot, const uint8_t *data, uint16_t length) {
    if (length < 2) {
        return;
    }
    uint16_t mv = sys_get_le16(data);
    if (battery_mv[slot] != mv) {
        LOG_DBG("Polled battery voltage %d mV for peripheral %d", mv, slot);
        battery_mv[slot] = mv;
        schedule_send(K_MSEC(100));
    }

    /* Flags byte: only newer halves send it, older ones count as on battery. */
    uint8_t usb_mask = usb_powered_mask & ~BIT(slot);
    if (length >= 3 && (data[2] & BIT(0))) {
        usb_mask |= BIT(slot);
    }
    if (usb_mask != usb_powered_mask) {
        usb_powered_mask = usb_mask;
        schedule_send(K_MSEC(100));
    }
}

static const struct bt_uuid_128 voltage_uuid = BT_UUID_INIT_128(TOTEM_BATTERY_VOLTAGE_CHAR_UUID);

static struct ts_read level_reads[TS_PERIPHERALS];
static struct ts_read voltage_reads[TS_PERIPHERALS];

static uint8_t read_cb(struct bt_conn *conn, uint8_t err, struct bt_gatt_read_params *params,
                       const void *data, uint16_t length) {
    struct ts_read *r = CONTAINER_OF(params, struct ts_read, params);
    r->busy = false;

    /* Halves with older firmware have no voltage characteristic: that's just an error here. */
    if (!err && data != NULL && length >= 1) {
        r->handle(r->slot, data, length);
    }
    return BT_GATT_ITER_STOP;
}

static void start_read(struct bt_conn *conn, struct ts_read *r, uint8_t slot) {
    if (r->busy && k_uptime_get() - r->started < TS_BATTERY_READ_TIMEOUT_MS) {
        return;
    }

    memset(&r->params, 0, sizeof(r->params));
    r->slot = slot;
    r->params.func = read_cb;
    r->params.handle_count = 0; /* read by UUID */
    r->params.by_uuid.start_handle = BT_ATT_FIRST_ATTRIBUTE_HANDLE;
    r->params.by_uuid.end_handle = BT_ATT_LAST_ATTRIBUTE_HANDLE;
    r->params.by_uuid.uuid = r->uuid;
    r->busy = true;
    r->started = k_uptime_get();

    int err = bt_gatt_read(conn, &r->params);
    if (err) {
        LOG_DBG("Battery read for peripheral %d failed: %d", slot, err);
        r->busy = false;
    }
}

static void poll_peripheral(struct bt_conn *conn, void *user_data) {
    int slot = peripheral_slot(conn);
    if (slot < 0) {
        return;
    }

    level_reads[slot].uuid = BT_UUID_BAS_BATTERY_LEVEL;
    level_reads[slot].handle = handle_level;
    start_read(conn, &level_reads[slot], slot);

    voltage_reads[slot].uuid = &voltage_uuid.uuid;
    voltage_reads[slot].handle = handle_voltage;
    start_read(conn, &voltage_reads[slot], slot);
}

/* ---- link quality ------------------------------------------------------ */

#define TS_RSSI_POLL_INTERVAL K_SECONDS(10)
/* Smaller swings are just noise: don't wake the host for them. */
#define TS_RSSI_REPORT_DELTA 3

static int read_rssi(struct bt_conn *conn, int8_t *rssi) {
    uint16_t handle;
    int err = bt_hci_get_conn_handle(conn, &handle);
    if (err) {
        return err;
    }

    struct net_buf *buf =
        bt_hci_cmd_create(BT_HCI_OP_READ_RSSI, sizeof(struct bt_hci_cp_read_rssi));
    if (!buf) {
        return -ENOBUFS;
    }
    struct bt_hci_cp_read_rssi *cp = net_buf_add(buf, sizeof(*cp));
    cp->handle = sys_cpu_to_le16(handle);

    struct net_buf *rsp;
    err = bt_hci_cmd_send_sync(BT_HCI_OP_READ_RSSI, buf, &rsp);
    if (err) {
        return err;
    }
    const struct bt_hci_rp_read_rssi *rp = (const void *)rsp->data;
    err = rp->status ? -EIO : 0;
    if (!err) {
        *rssi = rp->rssi;
    }
    net_buf_unref(rsp);
    return err;
}

static void poll_rssi(struct bt_conn *conn, void *user_data) {
    int slot = peripheral_slot(conn);
    int8_t rssi;
    if (slot < 0 || read_rssi(conn, &rssi) != 0 || rssi == 127 /* not available */) {
        return;
    }
    /* 0 means unknown in the report; a real link is always below 0 dBm. */
    rssi = MIN(rssi, -1);
    int8_t old = link_rssi[slot];
    if (old == 0 || abs(rssi - old) >= TS_RSSI_REPORT_DELTA) {
        link_rssi[slot] = rssi;
        schedule_send(K_MSEC(100));
    }
}

static void rssi_poll_work_cb(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(rssi_poll_work, rssi_poll_work_cb);

static void rssi_poll_work_cb(struct k_work *work) {
    bt_conn_foreach(BT_CONN_TYPE_LE, poll_rssi, NULL);
    k_work_schedule(&rssi_poll_work, TS_RSSI_POLL_INTERVAL);
}

static void battery_poll_work_cb(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(battery_poll_work, battery_poll_work_cb);

static void battery_poll_work_cb(struct k_work *work) {
    bt_conn_foreach(BT_CONN_TYPE_LE, poll_peripheral, NULL);
    k_work_schedule(&battery_poll_work, TS_BATTERY_POLL_INTERVAL);
}

/* Push the new connection state to the host and read the battery soon after a half connects. */
static void ts_connected(struct bt_conn *conn, uint8_t err) {
    if (!err) {
        schedule_send(K_MSEC(200));
        k_work_reschedule(&battery_poll_work, K_SECONDS(3));
        k_work_reschedule(&rssi_poll_work, K_SECONDS(2));
    }
}

static void ts_disconnected(struct bt_conn *conn, uint8_t reason) { schedule_send(K_MSEC(200)); }

BT_CONN_CB_DEFINE(totem_status_conn_cb) = {
    .connected = ts_connected,
    .disconnected = ts_disconnected,
};

static int totem_status_ble_init(void) {
    k_work_schedule(&battery_poll_work, K_SECONDS(5));
    k_work_schedule(&rssi_poll_work, K_SECONDS(5));
    return 0;
}

SYS_INIT(totem_status_ble_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);

#endif

/* ---- Windows fallback ---------------------------------------------------
 *
 * Start in macOS mode and wait for the macOS app. A host that never sends us a
 * command within CONFIG_TOTEM_STATUS_WIN_FALLBACK_MS has no app: Windows.
 */
#if CONFIG_TOTEM_STATUS_WIN_FALLBACK_MS > 0
static void win_fallback_work_cb(struct k_work *work) {
    LOG_INF("No host app after boot, switching to Windows mode");
    zmk_keymap_layer_activate(TS_WIN_LAYER, false);
    schedule_send(K_MSEC(10));
}
static K_WORK_DELAYABLE_DEFINE(win_fallback_work, win_fallback_work_cb);
#endif

/* ---- incoming commands ------------------------------------------------- */

struct ts_command {
    uint8_t cmd;
    uint8_t arg;
};

K_MSGQ_DEFINE(ts_cmd_msgq, sizeof(struct ts_command), 4, 1);

static void command_work_cb(struct k_work *work) {
    struct ts_command c;
    while (k_msgq_get(&ts_cmd_msgq, &c, K_NO_WAIT) == 0) {
#if CONFIG_TOTEM_STATUS_WIN_FALLBACK_MS > 0
        /* The macOS app is here: stay in macOS mode. */
        k_work_cancel_delayable(&win_fallback_work);
#endif
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
        case TS_CMD_GET_KEY_STATS:
            send_key_stats(c.arg);
            continue; /* no state report */
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
        /* Push every layer change (the app shows the active layer); the short delay
         * coalesces several changes from one key press into a single report. */
        if (zmk_keymap_layer_state() != last_sent_layers) {
            schedule_send(K_MSEC(10));
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

    const struct zmk_position_state_changed *pos_ev = as_zmk_position_state_changed(eh);
    if (pos_ev) {
        if (pos_ev->state && pos_ev->position < TS_KEY_POSITIONS) {
            key_presses[pos_ev->position]++;
        }
        if (pos_ev->state && pos_ev->source < TS_PERIPHERALS && pos_ev->position < 64) {
            bool left = (TS_LEFT_POSITIONS >> pos_ev->position) & 1;
            uint8_t slot = left ? pos_ev->source
                                : (TS_PERIPHERALS == 2 ? 1 - pos_ev->source : TS_SLOT_UNKNOWN);
            if (slot != TS_SLOT_UNKNOWN && slot != left_slot) {
                LOG_DBG("Left half is peripheral slot %d", slot);
                left_slot = slot;
                schedule_send(K_MSEC(100));
            }
        }
        return ZMK_EV_EVENT_BUBBLE;
    }

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
ZMK_SUBSCRIPTION(totem_status_state, zmk_position_state_changed);

static int totem_status_init(void) {
    boot_id = sys_rand32_get();
#if CONFIG_TOTEM_STATUS_WIN_FALLBACK_MS > 0
    k_work_schedule(&win_fallback_work, K_MSEC(CONFIG_TOTEM_STATUS_WIN_FALLBACK_MS));
#endif
    return 0;
}

SYS_INIT(totem_status_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
