/* video.h - constants of the output (graphics card, src/video.c).
 *
 * The chipset path of the C builds has lived in the assembler modules
 * (src/kern.h) since the 020+ rework; the functions of the graphics card are in
 * src/vout.h. */
#ifndef CYBERPAK_VIDEO_H
#define CYBERPAK_VIDEO_H

#include <stdint.h>

#define VIDEO_ERR_LIB     -1   /* cybergraphics.library missing / no card   */
#define VIDEO_ERR_WINDOW  -2   /* screen or window                         */
#define VIDEO_ERR_DEPTH   -3   /* depth or format do not fit               */

#define VIDEO_INPUT_NONE       0
#define VIDEO_INPUT_QUIT       1
#define VIDEO_INPUT_PAUSE      2   /* Leertaste */
#define VIDEO_INPUT_FULLSCREEN 3   /* Return    */

#define VIDEO_FS_OK        0
#define VIDEO_FS_NOMODE    1   /* no suitable RTG mode found        */
#define VIDEO_FS_NOSCREEN  2   /* screen could not be opened        */
#define VIDEO_FS_NOWIN     3   /* window could not be opened        */
#define VIDEO_FS_FORMAT    4   /* anderes Pixelformat als im Fenster */

#endif
