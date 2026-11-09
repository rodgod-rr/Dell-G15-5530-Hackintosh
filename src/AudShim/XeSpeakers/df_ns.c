#include "df_ns.h"
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <libgen.h>

typedef struct DFState DFState;
static struct {
    DFState *(*create)(const char *, float, const char *);
    size_t (*frameLen)(DFState *);
    float (*process)(DFState *, float *, float *);
    void (*setAtten)(DFState *, float);
    DFState *st;
    volatile int ready;
    volatile float pendAtten; volatile int pend;   // atenuacao pedida por outra thread; aplicada na thread de IO
} D;

void dfns_set_atten(float attenDb) { D.pendAtten = attenDb; __atomic_store_n(&D.pend, 1, __ATOMIC_RELEASE); }
int dfns_ready(void) { return __atomic_load_n(&D.ready, __ATOMIC_ACQUIRE); }

int dfns_load(float attenDb) {
    if (dfns_ready()) return 1;
    Dl_info info;
    if (!dladdr((void *)dfns_load, &info) || !info.dli_fname) return 0;
    char exe[PATH_MAX], lib[PATH_MAX], model[PATH_MAX];
    strlcpy(exe, info.dli_fname, sizeof exe);
    const char *dir = dirname(exe);   // .../Contents/MacOS
    snprintf(lib, sizeof lib, "%s/../Frameworks/libdf.dylib", dir);
    snprintf(model, sizeof model, "%s/../Resources/DeepFilterNet3_onnx.tar.gz", dir);
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) return 0;
    D.create = dlsym(h, "df_create"); D.frameLen = dlsym(h, "df_get_frame_length");
    D.process = dlsym(h, "df_process_frame"); D.setAtten = dlsym(h, "df_set_atten_lim");
    if (!D.create || !D.frameLen || !D.process || !D.setAtten) return 0;
    D.st = D.create(model, attenDb, "error");
    if (!D.st || D.frameLen(D.st) != DFNS_HOP) return 0;
    D.setAtten(D.st, attenDb);
    float z[DFNS_HOP] = {0}, o[DFNS_HOP];
    for (int i = 0; i < 20; i++) D.process(D.st, z, o);   // aquece (alocacoes e caches) antes de ir para a thread de IO
    __atomic_store_n(&D.ready, 1, __ATOMIC_RELEASE);
    return 1;
}

void dfns_reset(dfns *s) { memset(s, 0, sizeof *s); }

void dfns_process(dfns *s, float *lr, uint32_t n) {
    if (__atomic_exchange_n(&D.pend, 0, __ATOMIC_ACQUIRE)) D.setAtten(D.st, D.pendAtten);   // o estado do DFN so e tocado por esta thread
    for (uint32_t i = 0; i < n; i++) {
        float l = lr[2 * i], r = lr[2 * i + 1];
        float m = 0.5f * (l + r);
        s->sumL += (double)l * l; s->sumR += (double)r * r;
        s->in[s->hopCnt] = isfinite(m) ? m : 0.0f;
        lr[2 * i] = lr[2 * i + 1] = s->prev[s->hopCnt];
        s->sumIn += (double)s->in[s->hopCnt] * s->in[s->hopCnt]; s->sumOut += (double)lr[2 * i] * lr[2 * i];
        s->statN++;
        if (++s->hopCnt == DFNS_HOP) {
            D.process(D.st, s->in, s->cur);
            memcpy(s->prev, s->cur, sizeof s->cur);
            s->hopCnt = 0;
        }
    }
}

int dfns_take_stats(dfns *s, float *inDb, float *outDb, float *lDb, float *rDb) {
    if (s->statN < 48000) return 0;
    *inDb = 10.0f * log10f((float)(s->sumIn / s->statN) + 1e-12f);
    *outDb = 10.0f * log10f((float)(s->sumOut / s->statN) + 1e-12f);
    *lDb = 10.0f * log10f((float)(s->sumL / s->statN) + 1e-12f);
    *rDb = 10.0f * log10f((float)(s->sumR / s->statN) + 1e-12f);
    s->sumIn = s->sumOut = s->sumL = s->sumR = 0; s->statN = 0;
    return 1;
}
