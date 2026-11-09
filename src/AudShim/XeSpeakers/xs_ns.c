// xs_ns.c: supressor de ruido do "Microfone interno" (ver xs_ns.h).
#include "xs_ns.h"
#include <math.h>
#include <string.h>

static void fft(const xs_ns *s, float *re, float *im, int inv) {   // radix-2 iterativa, N = XS_NS_N
    const int n = XS_NS_N;
    for (int i = 0; i < n; i++) {
        int j = s->rev[i];
        if (j > i) { float t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    for (int len = 2; len <= n; len <<= 1) {
        int half = len >> 1, step = n / len;
        for (int i = 0; i < n; i += len)
            for (int k = 0; k < half; k++) {
                float wr = s->costab[k * step], wi = inv ? s->sintab[k * step] : -s->sintab[k * step];
                float xr = re[i + k + half] * wr - im[i + k + half] * wi;
                float xi = re[i + k + half] * wi + im[i + k + half] * wr;
                re[i + k + half] = re[i + k] - xr; im[i + k + half] = im[i + k] - xi;
                re[i + k] += xr; im[i + k] += xi;
            }
    }
}

void xs_ns_reset(xs_ns *s) {
    memset(s->in, 0, sizeof s->in); memset(s->ola, 0, sizeof s->ola);
    memset(s->hop, 0, sizeof s->hop); memset(s->outFifo, 0, sizeof s->outFifo);
    s->hopCnt = 0;
    for (int k = 0; k < XS_NS_BINS; k++) s->gain[k] = 1.0f;
    s->gateGain = 1.0f; s->gateHold = 0; s->fill = 0;
}

void xs_ns_init(xs_ns *s, float alpha, float floor) {
    memset(s, 0, sizeof *s);
    const int n = XS_NS_N;
    int bits = 0; while ((1 << bits) < n) bits++;
    for (int i = 0; i < n; i++) {
        s->win[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * (float)i / (float)n);   // Hann periodica
        int r = 0; for (int b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b);
        s->rev[i] = (uint16_t)r;
    }
    for (int k = 0; k < n / 2; k++) { s->costab[k] = cosf(2.0f * (float)M_PI * k / n); s->sintab[k] = sinf(2.0f * (float)M_PI * k / n); }
    for (int j = 0; j < XS_NS_SUB; j++) for (int k = 0; k < XS_NS_BINS; k++) s->sub[j][k] = INFINITY;
    for (int k = 0; k < XS_NS_BINS; k++) s->cur[k] = INFINITY;
    s->alpha = alpha; s->floor = floor; s->bias = 1.5f;
    xs_ns_reset(s);
}

static void frame(xs_ns *s) {
    static const float olaScale = 1.0f / 1.5f;   // soma de Hann^2 com 75 % de sobreposicao = 1,5
    float (*re)[XS_NS_N] = s->re, (*im)[XS_NS_N] = s->im;
    for (int c = 0; c < 2; c++) {
        memmove(s->in[c], s->in[c] + XS_NS_HOP, (XS_NS_N - XS_NS_HOP) * sizeof(float));
        memcpy(s->in[c] + XS_NS_N - XS_NS_HOP, s->hop[c], XS_NS_HOP * sizeof(float));
        for (int i = 0; i < XS_NS_N; i++) { re[c][i] = s->in[c][i] * s->win[i]; im[c][i] = 0.0f; }
        fft(s, re[c], im[c], 0);
    }
    s->frames++;
    // Depois de um reset a janela de analise ainda tem zeros nos primeiros N/HOP quadros: a potencia quase nula entraria no
    // minimo do ruido e o deixaria ~0 por ~1 s (chiado no comeco de cada gravacao). Nesses quadros nada e aprendido nem aplicado.
    // A captura tambem sobe de ~0 ao nivel normal em ~0,2 s (rampa de ganho do DSP): XS_NS_FILL cobre isso.
    // O inicio da captura tambem vem com ~40 ms de silencio digital (potencia ~1e-9 contra ~3e-3 do ruido): mesmo problema.
    float eTot = 0.0f;
    for (int k = 0; k < XS_NS_BINS; k++) eTot += 0.5f * (re[0][k] * re[0][k] + im[0][k] * im[0][k] + re[1][k] * re[1][k] + im[1][k] * im[1][k]);
    const int fillup = s->fill < XS_NS_FILL || eTot < XS_NS_DEAD;
    if (s->fill < XS_NS_FILL) s->fill++;
    double pTot = 0, nTot = 0;
    for (int k = 0; k < XS_NS_BINS && !fillup; k++) {
        float p = 0.5f * (re[0][k] * re[0][k] + im[0][k] * im[0][k] + re[1][k] * re[1][k] + im[1][k] * im[1][k]) + 1e-20f;
        s->psmooth[k] = !s->psInit ? p : 0.7f * s->psmooth[k] + 0.3f * p;
        if (s->psmooth[k] < s->cur[k]) s->cur[k] = s->psmooth[k];
        float m = s->cur[k];
        for (int j = 0; j < XS_NS_SUB; j++) if (s->sub[j][k] < m) m = s->sub[j][k];
        s->noise[k] = s->bias * m;
        if (k > 4 && k < 400) { pTot += p; nTot += s->noise[k]; }
        float g = 1.0f - s->alpha * s->noise[k] / p;
        if (g < s->floor) g = s->floor;
        if (g < 0.6f * s->gain[k]) g = 0.6f * s->gain[k];   // cai no maximo 40 % por quadro
        s->gain[k] = g;
    }
    if (!fillup) s->psInit = 1;
    if (!fillup && s->frames > XS_NS_GATE_WARMUP) {
        if (pTot > XS_NS_GATE_THR * nTot) { s->gateGain = 1.0f; s->gateHold = XS_NS_GATE_HOLD; }   // fala: abre na hora
        else if (s->gateHold > 0) s->gateHold--;
        else { s->gateGain *= XS_NS_GATE_REL; if (s->gateGain < XS_NS_GATE_FLOOR) s->gateGain = XS_NS_GATE_FLOOR; }
    }
    if (!fillup && ++s->subCnt >= XS_NS_SUBLEN) {   // fecha um bloco da janela do minimo
        memcpy(s->sub[s->subIdx], s->cur, sizeof s->cur);
        s->subIdx = (s->subIdx + 1) % XS_NS_SUB; s->subCnt = 0;
        for (int k = 0; k < XS_NS_BINS; k++) s->cur[k] = INFINITY;
    }
    for (int c = 0; c < 2; c++) {
        for (int k = 0; k < XS_NS_BINS; k++) {
            float g = s->gain[k] * s->gateGain;
            re[c][k] *= g; im[c][k] *= g;
            if (k && k < XS_NS_N / 2) { re[c][XS_NS_N - k] *= g; im[c][XS_NS_N - k] *= g; }
        }
        fft(s, re[c], im[c], 1);
        for (int i = 0; i < XS_NS_N; i++) s->ola[c][i] += re[c][i] * (1.0f / XS_NS_N) * s->win[i] * olaScale;
        memcpy(s->outFifo[c], s->ola[c], XS_NS_HOP * sizeof(float));
        memmove(s->ola[c], s->ola[c] + XS_NS_HOP, (XS_NS_N - XS_NS_HOP) * sizeof(float));
        memset(s->ola[c] + XS_NS_N - XS_NS_HOP, 0, XS_NS_HOP * sizeof(float));
    }
}

void xs_ns_process(xs_ns *s, float *lr, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        int h = s->hopCnt;
        s->hop[0][h] = lr[2 * i]; s->hop[1][h] = lr[2 * i + 1];
        lr[2 * i] = s->outFifo[0][h]; lr[2 * i + 1] = s->outFifo[1][h];
        if (++s->hopCnt == XS_NS_HOP) { frame(s); s->hopCnt = 0; }
    }
}
