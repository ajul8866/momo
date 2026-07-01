/* parse_thing.c — tiny PTv1 format parser with deliberate OOB.
 * Fixture for vuln-target-prep smoke test. NOT production code.
 * Format: magic "PTv1" (4) | len L (u16 LE) | payload (L bytes)
 * Bug: payload memcpy'd into 64-byte stack buffer with no bounds check.
 */
#include <string.h>
#include <stdint.h>

#define FIXED_BUF 64

int parse_thing(const unsigned char *buf, long len) {
    if (len < 6) return 1;
    if (memcmp(buf, "PTv1", 4) != 0) return 2;
    uint16_t L = (uint16_t)(buf[4] | (buf[5] << 8));
    if (len < 6 + L) return 3;
    char dst[FIXED_BUF];
    memcpy(dst, buf + 6, L);   /* BUG: no bounds check — L may exceed FIXED_BUF */
    return 0;
}
