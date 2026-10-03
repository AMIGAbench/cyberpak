/* vout.h - output on the graphics card (src/video.c). */
#ifndef CYBERPAK_VOUT_H
#define CYBERPAK_VOUT_H

#include <stdint.h>

/* Is a graphics card usable? 0 = yes; VIDEO_ERR_LIB none (library missing or
 * the Workbench does not live on it); VIDEO_ERR_WINDOW cannot lock the
 * Workbench; VIDEO_ERR_DEPTH below 15 bit (reason: rtg_status()). */
int      rtg_probe(void);
int      rtg_open(uint32_t w, uint32_t h, const char *title);
void     rtg_close(void);
void     rtg_show(const uint8_t *fb, uint32_t stride);
uint32_t rtg_sigmask(void);
int      rtg_handle_input(void);
uint32_t rtg_depth(void);
uint32_t rtg_pixfmt(void);
void     rtg_prefer_hicolor(int on);
int      rtg_is_hicolor(void);
uint32_t rtg_bpp(void);
int      rtg_pix16(void);
int      rtg_toggle_fullscreen(void);
int      rtg_is_fullscreen(void);
int      rtg_fs_error(void);
uint64_t rtg_show_ticks(void);
const char *rtg_status(void);
const char *rtg_hint(void);

#endif
