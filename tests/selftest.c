/* selftest - checks the ported tables on every target.
 *
 * Purpose: make a soft-float or rounding deviation between the host and the
 * m68k build visible before any pixel is decoded.
 * On the Amiga the output goes through KPutStr to the serial
 * interface; tools/run.sh evaluates the [OK]/[FAIL] marks.
 */
#include "cpu.h"
#include "plat.h"
#include "yuv.h"

/* An itoa of our own instead of printf: KPutStr is the serial channel, and the
 * Amiga build should have no stdio dependency for this test. */
static char *put_int(char *p, long v)
{
    char tmp[12];
    int n = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { tmp[n++] = (char)('0' + (v % 10)); v /= 10; } while (v);
    while (n) *p++ = tmp[--n];
    return p;
}

int main(void)
{
    char buf[128], *p;
    int rc;

    PLAT_PUTS("[BOOT] CyberPak selftest\n");

    p = buf;
    { const char *s = "  CPU_LEVEL="; while (*s) *p++ = *s++; }
    p = put_int(p, (long)CPU_LEVEL);
    { const char *s = " unaligned="; while (*s) *p++ = *s++; }
    p = put_int(p, (long)CPU_UNALIGNED_OK);
    { const char *s = " mul32="; while (*s) *p++ = *s++; }
    p = put_int(p, (long)CPU_HAS_MUL32);
    *p++ = '\n'; *p = 0;
    PLAT_PUTS(buf);

    rc = yuv_selftest();

    p = buf;
    if (rc == 0) {
        const char *s = "[OK] yuv tables verified\n";
        while (*s) *p++ = *s++;
    } else {
        const char *s = "[FAIL] yuv_selftest rc=";
        while (*s) *p++ = *s++;
        p = put_int(p, (long)rc);
        *p++ = '\n';
    }
    *p = 0;
    PLAT_PUTS(buf);

    return rc != 0;
}
