/* naiveparse.c — tiny NPv1 format parser with a deliberate OOB bug.
 * System-under-test for vuln-mine. NOT production code.
 * Format: magic "NPv1" (4 bytes) | len L (u16 little-endian) | payload (L bytes)
 * Bug: payload is memcpy'd into a fixed 64-byte stack buffer with NO bounds check,
 *      so any L > 64 triggers a stack-buffer-overflow under ASan.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define FIXED_BUF 64

static int parse_np(const uint8_t *data, size_t len) {
    if (len < 6) return 1;                        /* magic(4) + len(2) */
    if (memcmp(data, "NPv1", 4) != 0) return 2;   /* magic gate */
    uint16_t L = (uint16_t)(data[4] | (data[5] << 8));
    if (len < (size_t)(6 + L)) return 3;          /* truncated payload */

    char buf[FIXED_BUF];
    /* DELIBERATE BUG: L is attacker-controlled and never compared to FIXED_BUF. */
    memcpy(buf, data + 6, L);
    volatile char sink = buf[0];                  /* keep buf live */
    (void)sink;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <input.np>\n", argv[0]);
        return 64;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("fopen"); return 65; }
    if (fseek(f, 0, SEEK_END) != 0) { perror("fseek"); fclose(f); return 66; }
    long sz = ftell(f);
    if (sz < 0) { perror("ftell"); fclose(f); return 67; }
    rewind(f);
    uint8_t *buf = malloc((size_t)sz ? (size_t)sz : 1);
    if (!buf) { fclose(f); return 68; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf); fclose(f); return 69;
    }
    fclose(f);
    int rc = parse_np(buf, (size_t)sz);
    free(buf);
    return rc;
}
