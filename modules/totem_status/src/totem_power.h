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
