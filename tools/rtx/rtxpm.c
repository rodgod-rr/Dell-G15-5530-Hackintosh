// Envia {"RtxPm": n} ao G15Fan (IORegistryEntrySetCFProperties). n: 0 NVRM ->0; 2 NVRM e audio ->0; 1 tudo ->1. So root.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "uso: rtxpm 0|1|2\n"); return 1; }
    int v = atoi(argv[1]);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15Fan"));
    if (!s) { fprintf(stderr, "G15Fan nao achado\n"); return 1; }
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFStringRef k = CFSTR("RtxPm");
    CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&n, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    kern_return_t e = IORegistryEntrySetCFProperties(s, d);
    printf("RtxPm %d -> 0x%x\n", v, e);
    return e ? 1 : 0;
}
