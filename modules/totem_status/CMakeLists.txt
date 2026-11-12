zephyr_include_directories(include)

if (CONFIG_TOTEM_STATUS)
  zephyr_library_named(totem_status)
  zephyr_library_sources(src/totem_status.c)
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
endif()

if (CONFIG_TOTEM_BATTERY_LIPO)
  zephyr_library_named(totem_battery_lipo)
  zephyr_library_sources(src/battery_lipo.c)
endif()

if (CONFIG_TOTEM_BATTERY_VOLTAGE_SERVICE)
  zephyr_library_named(totem_battery_voltage_service)
  zephyr_library_sources(src/battery_voltage_service.c)
endif()
