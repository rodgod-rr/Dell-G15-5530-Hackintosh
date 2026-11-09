// xs_ns.h: supressor de ruido do "Microfone interno" (G15 5530), subtracao espectral em tempo real, C puro (sem
// Accelerate), para compilar no plug-in XeSpeakers (macOS) e no teste do Linux (tools/xs-ns-teste.c).
//
// Por que: o DMIC do G15 fica ao lado da saida do ventilador; o filtro de 150 Hz do DSP tira o ronco, mas sobra um chiado
// de banda larga (~ -48 dBFS). No Linux quem limpa e o app (WebRTC no navegador); o WhatsApp nativo do macOS grava cru.
// O firmware SOF do G15 nao tem modulo de supressao (so EQ IIR, DC-block, volume, mixer, mux, ASRC).
//
// Como: STFT de 1024 pontos (21,3 ms) com passo de 256 (janela de Hann na analise e na sintese, 75 % de sobreposicao).
// Por faixa de frequencia: potencia suavizada; ruido = minimo dessa potencia no ultimo ~1 s (8 blocos de 24 quadros,
// "minimum statistics"), vezes uma correcao de vies; ganho = max(1 - ALFA * ruido / potencia, PISO), com o ganho de cada
// faixa caindo no maximo 40 % por quadro (evita o "ruido musical"). O mesmo ganho vale para os 2 canais.
// Parametros escolhidos pelo usuario em 28/10 (versao "forte" do teste: ALFA 3, PISO 0,06).
// Gate (28/10): depois da subtracao, se a potencia total (bins 5..399, ~100 Hz a 8 kHz) nao passa de XS_NS_GATE_THR vezes
// o ruido estimado, o quadro e so ruido e o ganho cai (x XS_NS_GATE_REL por quadro) ate XS_NS_GATE_FLOOR (-20 dB); com
// fala abre na hora e segura XS_NS_GATE_HOLD quadros (~100 ms). Medido no silencio: -47 -> -67 dBFS, fala igual.
// Atraso: XS_NS_DELAY = 1024 amostras (21,3 ms) entre a entrada e a saida.
#ifndef XS_NS_H
#define XS_NS_H
#include <stdint.h>

#define XS_NS_N 1024
#define XS_NS_HOP 256
#define XS_NS_BINS (XS_NS_N / 2 + 1)
#define XS_NS_DELAY XS_NS_N
#define XS_NS_SUB 8      // blocos da janela do minimo
#define XS_NS_SUBLEN 24  // quadros por bloco (24 x 5,33 ms = 128 ms; 8 blocos ~ 1 s)

#define XS_NS_GATE_THR 8.0f
#define XS_NS_GATE_FLOOR 0.1f
#define XS_NS_GATE_REL 0.90f
#define XS_NS_GATE_HOLD 20
#define XS_NS_GATE_WARMUP 40    // quadros (~0,2 s) depois do reset antes de o gate poder fechar
#define XS_NS_FILL 48           // quadros (~0,26 s; 29/10: era 64 = 0,34 s; 32 deixa o ruido sem estimar por ~1 s) ignorados depois do reset: janela com zeros + rampa de ganho da captura
#define XS_NS_DEAD 1e-4f        // energia total do quadro (soma dos bins) abaixo disso = silencio digital (inicio da captura)

typedef struct {
    float win[XS_NS_N];
    float costab[XS_NS_N / 2], sintab[XS_NS_N / 2];
    uint16_t rev[XS_NS_N];
    float in[2][XS_NS_N];            // ultimas N amostras de cada canal (in[c][N-1] = a mais nova)
    float ola[2][XS_NS_N];           // soma das sinteses (overlap-add)
    float psmooth[XS_NS_BINS], sub[XS_NS_SUB][XS_NS_BINS], cur[XS_NS_BINS], noise[XS_NS_BINS], gain[XS_NS_BINS];
    int subIdx, subCnt, filled, hopCnt, frames;
    float hop[2][XS_NS_HOP];         // entrada do quadro em montagem
    float outFifo[2][XS_NS_HOP];     // as HOP amostras prontas do ultimo quadro
    float alpha, floor, bias;
    float gateGain; int gateHold;
    int fill, psInit;                // quadros desde o reset (janela ainda com zeros) / psmooth ja iniciado
    float re[2][XS_NS_N], im[2][XS_NS_N];   // espectro do quadro (fora da pilha da thread de IO)
} xs_ns;

void xs_ns_init(xs_ns *s, float alpha, float floor);
void xs_ns_reset(xs_ns *s);          // descontinuidade (IO reiniciou): volta ao silencio, mantem o ruido aprendido
// Processa n quadros intercalados (L R L R ...), in-place; a saida sai atrasada XS_NS_DELAY amostras.
void xs_ns_process(xs_ns *s, float *lr, uint32_t n);

#endif
