/* rgb16check - the 16-bit output mode against the 32-bit mode.
 *
 * For the 16-bit mode there is no external reference: ffmpeg delivers no
 * 565, and the golden hashes are in RGB32. The check therefore runs
 * against the already verified 32-bit output - and EXACTLY so, not
 * with a tolerance: both paths read the same clamped colour values from
 * the same table, the 16-bit path merely shifts them to their
 * bit position in advance. So every pixel has to be exactly what arises
 * from the 32-bit pixel through the same truncation.
 *
 * All four formats are checked (565/555, each also byte-swapped).
 *
 * Call: rgb16check <file.avi> [format 0..3] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cpu.h"
#include "avi.h"
#include "yuv.h"
#include "codec/cvid.h"

int main(int argc, char **argv)
{
    FILE *f; long n; uint8_t *data, *fb32, *fb16;
    avi_file av; cvid_ctx *c32, *c16;
    uint32_t w,h,s32,s16,nf=0,bad=0; const uint8_t *d; uint32_t len;
    int fmt = argc>2 ? atoi(argv[2]) : 0;

    f=fopen(argv[1],"rb"); if(!f){puts("not readable");return 2;}
    fseek(f,0,SEEK_END); n=ftell(f); fseek(f,0,SEEK_SET);
    data=malloc(n); if(fread(data,1,n,f)!=(size_t)n) return 2; fclose(f);
    if(avi_open(&av,data,(uint32_t)n)){puts("no AVI");return 2;}

    w=av.width&~3u; h=av.height&~3u;
    s32=STRIDE_ALIGN(w*4u); s16=STRIDE_ALIGN(w*2u);
    fb32=calloc((size_t)s32*h,1); fb16=calloc((size_t)s16*h,1);
    c32=cvid_open(w,h,CVID_OUT_RGB32);
    c16=cvid_open(w,h,CVID_OUT_RGB16);
    cvid_set_pix16(c16,fmt);

    while(avi_next_video(&av,&d,&len)){
        uint32_t y,x;
        cvid_decode(c32,d,len,fb32,s32);
        cvid_decode(c16,d,len,fb16,s16);
        for(y=0;y<h;y++){
            const uint8_t *p32=fb32+(size_t)y*s32;
            const uint8_t *p16=fb16+(size_t)y*s16;
            for(x=0;x<w;x++){
                /* memory bytes A,R,G,B */
                uint32_t r=p32[x*4+1], g=p32[x*4+2], b=p32[x*4+3];
                uint32_t want, got;
                switch(fmt&1){
                case 0: want=((r>>3)<<11)|((g>>2)<<5)|(b>>3); break;
                default:want=((r>>3)<<10)|((g>>3)<<5)|(b>>3); break;
                }
                if(fmt>=2) want=((want>>8)&0xff)|((want<<8)&0xff00);
                got=((uint32_t)p16[x*2]<<8)|p16[x*2+1];   /* big-endian reading */
#if !CPU_BIG_ENDIAN
                got=((uint32_t)p16[x*2+1]<<8)|p16[x*2];
#endif
                if(want!=got){ if(bad<3) printf("  frame %u (%u,%u): expected %04x got %04x\n",nf,x,y,want,got); bad++; }
            }
        }
        nf++;
    }
    printf("  format %d: %u frames, %u deviating pixels\n", fmt, nf, bad);
    return bad!=0;
}
