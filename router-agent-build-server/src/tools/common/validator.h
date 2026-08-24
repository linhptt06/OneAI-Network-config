#ifndef ROUTER_AGENT_VALIDATOR_H
#define ROUTER_AGENT_VALIDATOR_H

#include <stdbool.h>
#include <stddef.h>

#define VALIDATOR_INTERFACE_SIZE 16U
#define VALIDATOR_UCI_SECTION_SIZE 64U
#define VALIDATOR_SSID_SIZE 33U
#define VALIDATOR_WIFI_KEY_SIZE 65U

bool validator_interface(const char *value);
bool validator_ipv4(const char *value);
bool validator_netmask(const char *value);
bool validator_optional_gateway(const char *value);
bool validator_uci_section(const char *value);
bool validator_ssid(const char *value);
bool validator_wifi_encryption(const char *value);
bool validator_wifi_key(const char *encryption,
                        const char *key,
                        bool key_was_provided);
bool validator_no_control_characters(const char *value, size_t maximum_length);
bool validator_argument_count(int actual, int expected);

#endif
