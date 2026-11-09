// DeepFilterNet3 (https://github.com/Rikorose/DeepFilterNet, MIT/Apache) como supressor de ruido do microfone (29-31/10).
// A libdf.dylib (Rust, API em C) e o modelo ficam dentro do .driver (Contents/Frameworks e Contents/Resources) e sao
// carregados por dlopen: se faltarem ou falharem, dfns_load devolve 0 e o XeSpeakers usa o xs_ns.
// Mono 48 kHz, quadro de 480 amostras (10 ms). A inferencia roda na propria thread de IO (~2 ms por quadro, pior caso).
#ifndef DF_NS_H
#define DF_NS_H
#include <stdint.h>

#define DFNS_HOP 480
#define DFNS_DELAY 480       // amostras de atraso do nosso buffer de um quadro (a latencia propria do modelo vem alem disso)
#define DFNS_MODEL_LATENCY 960   // estimativa: janela de 20 ms (FFT 960) do DFN3

typedef struct dfns {
    float in[DFNS_HOP], prev[DFNS_HOP], cur[DFNS_HOP];
    int hopCnt;
    double sumIn, sumOut, sumL, sumR; uint32_t statN;   // diagnostico: energia de entrada/saida acumulada
} dfns;

// Carrega a libdf e cria o modelo (lento, ~centenas de ms: chamar fora da thread de IO). Devolve 1 se pronto.
int dfns_load(float attenDb);
int dfns_ready(void);
void dfns_set_atten(float attenDb);   // pode ser chamada de qualquer thread: vale no proximo dfns_process (na thread de IO)
void dfns_reset(dfns *s);
// n quadros estereo intercalados (L R L R ...), in-place: mono = (L+R)/2 nos dois canais; saida atrasada DFNS_DELAY amostras.
void dfns_process(dfns *s, float *lr, uint32_t n);

// A cada ~1 s de audio devolve 1 e os niveis medios (dBFS) de entrada (mono) e saida desse periodo.
int dfns_take_stats(dfns *s, float *inDb, float *outDb, float *lDb, float *rDb);   // lDb/rDb: canais L e R separados (antes do downmix)

#endif
