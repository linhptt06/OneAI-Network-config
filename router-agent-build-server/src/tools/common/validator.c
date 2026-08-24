#define _POSIX_C_SOURCE 200809L
#include "validator.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <stdint.h>
#include <string.h>

bool validator_no_control_characters(const char *value, size_t maximum_length)
{
    size_t position;
    size_t length;

    if (value == NULL) {
        return false;
    }
    length = strnlen(value, maximum_length + 1U);
    if ((length == 0U) || (length > maximum_length)) {
        return false;
    }
    for (position = 0U; position < length; position++) {
        if (iscntrl((unsigned char)value[position]) != 0) {
            return false;
        }
    }
    return true;
}

bool validator_interface(const char *value)
{
    size_t position;
    size_t length;

    if (value == NULL) {
        return false;
    }
    length = strnlen(value, VALIDATOR_INTERFACE_SIZE);
    if ((length == 0U) || (length >= VALIDATOR_INTERFACE_SIZE) ||
        (value[0] == '-') || (strstr(value, "..") != NULL)) {
        return false;
    }
    for (position = 0U; position < length; position++) {
        const unsigned char character = (unsigned char)value[position];
        if ((isalnum(character) == 0) && (character != (unsigned char)'_') &&
            (character != (unsigned char)'-') && (character != (unsigned char)'.') &&
            (character != (unsigned char)':')) {
            return false;
        }
    }
    return true;
}

bool validator_ipv4(const char *value)
{
    struct in_addr address;
    return (value != NULL) && (inet_pton(AF_INET, value, &address) == 1);
}

bool validator_netmask(const char *value)
{
    struct in_addr address;
    uint32_t mask;
    uint32_t inverted;

    if ((value == NULL) || (inet_pton(AF_INET, value, &address) != 1)) {
        return false;
    }
    mask = ntohl(address.s_addr);
    inverted = ~mask;
    return (inverted & (inverted + 1U)) == 0U;
}

bool validator_optional_gateway(const char *value)
{
    return (value == NULL) || validator_ipv4(value);
}

bool validator_uci_section(const char *value)
{
    size_t position;
    size_t length;

    if (value == NULL) {
        return false;
    }
    length = strnlen(value, VALIDATOR_UCI_SECTION_SIZE);
    if ((length == 0U) || (length >= VALIDATOR_UCI_SECTION_SIZE) ||
        (value[0] == '-') || (value[0] == '@') || (strstr(value, "..") != NULL)) {
        return false;
    }
    for (position = 0U; position < length; position++) {
        const unsigned char character = (unsigned char)value[position];
        if ((isalnum(character) == 0) && (character != (unsigned char)'_') &&
            (character != (unsigned char)'-')) {
            return false;
        }
    }
    return true;
}

bool validator_ssid(const char *value)
{
    return validator_no_control_characters(value, VALIDATOR_SSID_SIZE - 1U);
}

bool validator_wifi_encryption(const char *value)
{
    static const char *const allowed[] = {
        "none", "psk2", "psk-mixed", "sae", "sae-mixed"
    };
    size_t index;

    if (value == NULL) {
        return false;
    }
    for (index = 0U; index < (sizeof(allowed) / sizeof(allowed[0])); index++) {
        if (strcmp(value, allowed[index]) == 0) {
            return true;
        }
    }
    return false;
}

bool validator_wifi_key(const char *encryption,
                        const char *key,
                        bool key_was_provided)
{
    size_t length;

    if (!validator_wifi_encryption(encryption)) {
        return false;
    }
    if (strcmp(encryption, "none") == 0) {
        return !key_was_provided;
    }
    if (!key_was_provided || (key == NULL)) {
        return false;
    }
    length = strnlen(key, VALIDATOR_WIFI_KEY_SIZE);
    return (length >= 8U) && (length < VALIDATOR_WIFI_KEY_SIZE) &&
           validator_no_control_characters(key, VALIDATOR_WIFI_KEY_SIZE - 1U);
}

bool validator_argument_count(int actual, int expected)
{
    return (actual >= 0) && (actual == expected);
}
