/* Shared by the code running on the halves. */
#pragma once

#include <stdbool.h>
#include <zephyr/kernel.h>

#if IS_ENABLED(CONFIG_SOC_SERIES_NRF52X)
#include <hal/nrf_power.h>
#endif

/* USB power present (VBUS). The halves have no USB stack, so ask the SoC directly. */
static inline bool totem_usb_powered(void) {
#if IS_ENABLED(CONFIG_SOC_SERIES_NRF52X) && NRF_POWER_HAS_USBREG
    return nrf_power_usbregstatus_vbusdet_get(NRF_POWER);
#else
    return false;
#endif
}

/*
 * Charger status. On the XIAO nRF52840 the charger's open drain CHG output (the
 * one driving the charge LED) is wired to P0.17: low while it charges the cell,
 * released once the cell is full or without USB power.
 */
#if defined(CONFIG_TOTEM_BATTERY_CHARGE_PIN) && CONFIG_TOTEM_BATTERY_CHARGE_PIN >= 0
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>

#define TOTEM_HAS_CHARGE_PIN 1

static inline int totem_charge_pin_init(void) {
    const struct device *gpio0 = DEVICE_DT_GET(DT_NODELABEL(gpio0));
    if (!device_is_ready(gpio0)) {
        return -ENODEV;
    }
    return gpio_pin_configure(gpio0, CONFIG_TOTEM_BATTERY_CHARGE_PIN, GPIO_INPUT | GPIO_PULL_UP);
}

static inline bool totem_charging(void) {
    return totem_usb_powered() &&
           gpio_pin_get_raw(DEVICE_DT_GET(DT_NODELABEL(gpio0)), CONFIG_TOTEM_BATTERY_CHARGE_PIN) == 0;
}
#else
#define TOTEM_HAS_CHARGE_PIN 0
static inline int totem_charge_pin_init(void) { return 0; }
static inline bool totem_charging(void) { return false; }
#endif
