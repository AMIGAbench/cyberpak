# Derived build image for CyberPak.
#
# apollocrossdev:latest supplies the complete toolchain (m68k-amigaos-gcc
# 6.5.0b, vasmm68k_mot 2.0d with AMMX, NDK), but 712 NDK headers are
# -rw------- and owned by root. We build as the calling user, so that the
# objects produced do not belong to root -- so make them readable once.
FROM apollocrossdev:latest

RUN chmod -R a+rX /opt/ApolloCrossDev/Compilers/GCC-6.50-Patched \
 && command -v make >/dev/null 2>&1 || (apt-get update && apt-get install -y --no-install-recommends make && rm -rf /var/lib/apt/lists/*)
