#!/bin/bash
# Crash no driver de VIDEO do WhateverXe-Graphics (AppleIntelTGLGraphicsVADriver 16.0.32), imagem +0x1336f3: ponteiro NULL.
# VTPixelTransferSession (Vision/Preview/Fotos/mediaanalysisd/WebKit.GPU) -> AppleGVA -> funcao em 0x133690, que grava
# "obj+0x2cb0" em [obj+0x920]->8 e em [obj+0x910]->8 sem checar; neste chip o objeto em +0x910 nunca e criado (NULL).
#   antes (13 bytes em 0x1336f3):  48 89 57 08 | 8b 45 e4 | 48 83 c4 30 | 5d c3     mov %rdx,8(%rdi); mov -0x1c(%rbp),%eax; add $0x30,%rsp; pop %rbp; ret
#   depois:                        48 85 ff | 74 04 | 48 89 57 08 | c9 | c3 | 90 90 test %rdi,%rdi; je +4; mov %rdx,8(%rdi); leave; ret; nop nop
# (eax ainda guarda o retorno de 0x125e10 e nada o altera ate ali, por isso o 'mov -0x1c(%rbp),%eax' foi dispensado; leave == add+pop)
# 2o ponto (mesmo objeto): a funcao 0x130dc0 escolhe o objeto de engine por indice, "obj->slot[0x910 + obj->0x9bc*8]", e passa a
# 0x126520, que grava em ->0x48 (NULL: crash em +0x126561). Agora, se o slot for NULL, a funcao devolve o erro 5 pelo MESMO caminho de erro
# que ela ja usa (0x130e5d: movl $5,-0x1c(%rbp); jmp epilogo), e o VideoToolbox pode cair para o caminho de software:
#   antes (21 bytes em 0x130e84): 8b 88 bc 09 00 00 | 83 c1 00 | 89 c9 | 89 ca | 48 8b bc d0 10 09 00 00
#   depois:                       8b 90 bc 09 00 00 | 48 8b bc d0 10 09 00 00 | 48 85 ff | 74 c6 | 90 90
#   (movl 0x9bc(%rax),%edx; movq 0x910(%rax,%rdx,8),%rdi; test %rdi,%rdi; je 0x130e5d; nop nop)
# 3o ponto (a CORRECAO de verdade, 05/11): a tabela de 16 funcoes que AVD_CreateAVDAccelerator entrega ao AppleGVA (tools/macos-metaltest/xe-vatrace.dylib). Em memoria,
#   trocar [0x78] (driver+0x15f96), [0x18] (+0x13e43) ou [0x08] por um stub que falha deixa as 6 conversoes do xe-vtpt corretas (o AppleGVA aceita a falha e o
#   VideoToolbox converte por software). MAS [0x08] = driver+0x135d9 e a criacao do contexto do DISPOSITIVO (dlsym AVD_Create..., IOAccelDeviceCreateWithAPIProperty "GVA",
#   calloc 0xAAC0): usada tambem pela decodificacao; falhar nela mandou a decodificacao para SOFTWARE (medido: contextVideoCount 0, CPU 238% em vez de 38%). Por isso o 3o patch fica
#   em [0x78]: 0x15f96 (funcao por operacao, que ja valida os argumentos e devolve erro 5):
#   antes (6 bytes): 55 48 89 e5 41 57 (push rbp; mov rsp,rbp; push r15)   depois: b8 05 00 00 00 c3 (mov $5,%eax; ret). Alternativa se a decodificacao sofrer: [0x18] em 0x13e43 (mesmos bytes).
#   Os patches 1 e 2 ficam inalcancaveis (inofensivos). Conferir depois: xe-vtpt (6 com conteudo), xe-avdec (1,2 s, CPU ~38%), tools/macos-hwdecode-test.py (contextVideoCount 3).
# Experimental: se aparecer outro NULL do mesmo objeto em outro ponto, o crash muda de lugar.
#   sudo bash macos-patch-wex-va.sh            aplica
#   sudo bash macos-patch-wex-va.sh semavc     hardware LIGADO menos a decodificacao AVC (que sai errada): codificacao H.264 e decodificacao HEVC por hardware, H.264 decodificado por software
#   sudo bash macos-patch-wex-va.sh avcfix     hardware de video TODO ligado + CONSERTO do H.264 (06/11, item 7, 44-45): o 'definir parametro' do CHAL_AVCDecoder
#                                              (0x2282f0) guardava em this+0x390 o ponteiro da chave 6, que no Tahoe aponta uma estrutura (nao um vetor de int por fatia);
#                                              x[1] virava metade de um endereco e corrompia a fatia 1. NOP no 'movq %rax,0x390(%rcx)' (0x228358): x[i] = 0.
#   sudo bash macos-patch-wex-va.sh sps        NAO USAR (06/11): o TGLVA do WhateverXe ja desloca o SPS; com este patch desloca 2x e o VTDecoderXPCService cai
#   sudo bash macos-patch-wex-va.sh semhw      DESLIGA o hardware de video (decodificacao e codificacao por software, imagem certa): 0x135d9 falha a criacao do dispositivo
#   sudo bash macos-patch-wex-va.sh sem3       so os patches 1 e 2 (sem o 3): para testar se o patch 3 atrapalha a decodificacao por hardware do Safari
#   sudo bash macos-patch-wex-va.sh remove     volta o driver original
#   VA_BIN=/caminho/copia bash macos-patch-wex-va.sh seco    aplica numa copia (sem sudo, sem assinar) para conferir
set -euo pipefail
B=/Library/GPUBundles/AppleIntelTGLGraphicsVADriver.bundle
BIN=${VA_BIN:-$B/Contents/MacOS/AppleIntelTGLGraphicsVADriver}
BK=/Library/G15-uhd/wex-va-original
# off:original:novo
PATCHES="1336f3:488957088b45e44883c4305dc3:4885ff740448895708c9c39090 130e84:8b88bc09000083c10089c989ca488bbcd010090000:8b90bc090000488bbcd0100900004885ff74c69090 15f96:554889e54157:b805000000c3"
rd() { od -An -tx1 -j "$2" -N"$3" "$1" | tr -d " \n"; }
wr() { printf "$(echo "$3" | sed 's/../\\x&/g')" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
# aplica (ou so confere) todos os patches em $1; retorna 0 se tudo certo
aplica() { local f=$1 mode=$2 done=0 total=0 t o orig new n
  for t in $PATCHES; do total=$((total+1)); o=$((0x${t%%:*})); orig=$(echo "$t" | cut -d: -f2); new=$(echo "$t" | cut -d: -f3); n=$(( ${#orig} / 2 )); v=$(rd "$f" $o $n)
    if [ "$v" = "$new" ]; then done=$((done+1)); continue; fi
    [ "$v" = "$orig" ] || { echo "bytes inesperados em 0x$(printf %x $o) ($v): driver diferente, nada feito"; return 1; }
    [ "$mode" = conferir ] || { wr "$f" $o "$new"; [ "$(rd "$f" $o $n)" = "$new" ] || { echo "falhou a conferencia em 0x$(printf %x $o)"; return 1; }; }
  done; [ "$done" = "$total" ] && return 2; return 0; }
if [ "${1:-}" = remove ]; then
    [ -f "$BK/driver" ] || { echo "sem backup em $BK"; exit 1; }
    cp -p "$BK/driver" "$BIN" && codesign -f -s - "$B" >/dev/null 2>&1; rm -rf "$BK"; echo "VA: driver original de volta (vale para os proximos apps)"; exit 0
fi
if [ "${1:-}" = semhw ]; then   # 05/11: o decodificador H.264 de HARDWARE devolve quadros errados (planos zerados/ruido; HEVC esta certo): enquanto nao se acha o conserto, tudo por software
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES="135d9:554889e54157:b807000000c3"; T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: hardware de video DESLIGADO (so 0x135d9). REINICIE o Safari e qualquer app de video. Para voltar aos 3 patches: sudo bash $0   (ou 'remove' para o original)"; exit 0
fi
if [ "${1:-}" = semavc ]; then   # 06/11: hardware de video LIGADO (codificacao H.264 e decodificacao HEVC por hardware, que funcionam), mas a CRIACAO do contexto de DECODIFICACAO AVC falha (a decodificacao H.264 por hardware devolve imagem errada) e o VideoToolbox cai em software
  # A funcao 'CreateContexts' (slot [0x18], 0x13e43) constroi o MFXAVCDecodeContext (ctor 0x227b70, 0x3b8 bytes) em DOIS pontos: 0x141eb (classe 0x80, subtipo 2) e 0x144f6 (mascara 0x200).
  # Cada ponto comeca com: mov %esi,%r12d; mov $0x3b8,%edi; call new...  Trocado por: mov $5,%eax; jmp 0x14f62 (o rotulo de erro 'AVDInitAVCDecodeContext err = %d', que devolve %eax=5 pelo caminho normal de falha).
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES="1336f3:488957088b45e44883c4305dc3:4885ff740448895708c9c39090 130e84:8b88bc09000083c10089c989ca488bbcd010090000:8b90bc090000488bbcd0100900004885ff74c69090 15f96:554889e54157:b805000000c3 141eb:4189f4bfb8030000e8e0:b805000000e96d0d0000 144f6:4189f4bfb8030000e8d5:b805000000e9620a0000"
  T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: hardware de video LIGADO, decodificacao AVC por SOFTWARE (patches 1-3 + criacao do contexto AVC falha). REINICIE Safari/apps de video. Voltar: sudo bash $0 semhw (tudo software) ou sudo bash $0 (hardware total)"; exit 0
fi
if [ "${1:-}" = avcfix ]; then   # 06/11: hardware de video TODO ligado (3 patches) + o driver nao guarda o ponteiro da chave 5/6/9 em this+0x390
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES="$PATCHES 228358:48898190030000:0f1f8000000000"
  T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: hardware de video LIGADO com o CONSERTO do H.264 (patches 1-3 + 0x228358). REINICIE Safari/apps de video. Voltar: sudo bash $0 semavc"; exit 0
fi
if [ "${1:-}" = avcfix-vame ]; then   # 06/11 TESTE FairPlay: avcfix + o driver procura o VAME do TIGER LAKE (o nome do Ice Lake 'AppleIntelICLGraphicsVAME'
  # vinha copiado do driver ICL e nao existe no sistema -> 'ME not loaded'). Troca 'ICL' por 'TGL' nas 2 strings (0x243615+10, 0x243645+10).
  # Precisa do /Library/GPUBundles/AppleIntelTGLGraphicsVAME.bundle (tools/macos-vame-teste.sh instala e remove).
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES="$PATCHES 228358:48898190030000:0f1f8000000000 24361f:49434c:54474c 24364f:49434c:54474c"
  T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: avcfix + VAME do TGL (teste FairPlay). Voltar: sudo bash $0 avcfix"; exit 0
fi
if [ "${1:-}" = avcfix-vame-k7 ] || [ "${1:-}" = avcfix-vame-sem3 ]; then   # 06/11 TESTE FairPlay: o 'setParam 5' era o PATCH 3 (0x15f96 = Gen75IntelGVASetDriverParameter
  # sempre 'erro 5'). Sem o patch 3: chave 1 = nada, 6 = valor nos contextos (+0x130/+0xa858), 7 = VAME (troca de chaves), outra = erro 5.
  #   avcfix-vame-k7   : so a chave 7 passa; 1 e 6 desviam para o erro 5 (0x16017 e 0x16020 -> 0x16174), como o patch 3 fazia
  #   avcfix-vame-sem3 : funcao original (todas as chaves)
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES="$(echo $PATCHES | tr ' ' '\n' | grep -v '^15f96:' | tr '\n' ' ') 228358:48898190030000:0f1f8000000000 24361f:49434c:54474c 24364f:49434c:54474c"
  [ "$1" = avcfix-vame-k7 ] && PATCHES="$PATCHES 16017:0f8440010000:0f8457010000 16020:0f84e0000000:0f844e010000"
  T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: $1 (teste FairPlay, sem o patch 3). Voltar: sudo bash $0 avcfix"; exit 0
fi
if [ "${1:-}" = sps ]; then   # 06/11: hardware de video TODO ligado (3 patches) + correcao do SPS do H.264 no Tahoe, do projeto XPS13Plus-IrisXe-Tahoe (macos/vadriver/patch_spsshift.py):
  # o AppleGVA do Tahoe tem 8 bytes a mais no SPS antes do level_idc; o driver 16.0.32 le o layout antigo e manda ao MFX_AVC_IMG_STATE croma 4:4:4, MBAFF=1 e larguras de frame_num/POC erradas.
  # Os 3 consumidores do ponteiro do SPS passam a usar SPS+8 (0x228e3f parametros de imagem, 0x229740 listas de escala, 0x229655 a leitura do MBAFF 0x82c -> 0x834).
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES="$PATCHES 228e3f:488b4dd0488b892804000048894dc0488b4dd0488b892004000048894db8:488b4dd0488b9128040000488955c0488b89200400004883c10848894db8 229740:488b45f0488b8028040000488945e0488b45f0488b8020040000488945d8:488b4df0488b8128040000488945e0488b81200400004883c008488945d8 229655:83b82c08000000:83b83408000000"
  T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: hardware de video LIGADO com a correcao do SPS (patches 1-3 + 3 do SPS). REINICIE Safari/apps de video. Voltar: sudo bash $0 semavc"; exit 0
fi
if [ "${1:-}" = sem3 ]; then   # volta o driver original e aplica so os patches 1 e 2
  [ -f "$BK/driver" ] || { echo "sem backup em $BK (rode o script normal antes)"; exit 1; }
  PATCHES=$(echo $PATCHES | cut -d' ' -f1-2); T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; [ -n "${VA_BIN:-}" ] || codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: so os patches 1 e 2 (sem o 3). Para voltar aos 3: sudo bash $0"; exit 0
fi
[ -f "$BIN" ] || { echo "nao achei $BIN"; exit 1; }
# 05/11: se o driver esta em modo semhw (0x135d9 falhando a criacao do dispositivo), o modo normal NAO religava o hardware (so somava os patches 1-3): partir do backup original
if [ -f "$BK/driver" ] && [ "$(rd "$BIN" $((0x135d9)) 6)" = b807000000c3 ] && [ -z "${VA_BIN:-}" ]; then
  T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BK/driver" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
  cp -p "$T" "$BIN" && rm -f "$T"; codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou"
  echo "VA: hardware de video RELIGADO (3 patches, sem o 0x135d9). Reinicie Safari/apps de video. Para desligar de novo: sudo bash $0 semhw"; exit 0
fi
rc=0; aplica "$BIN" conferir x || rc=$?
[ "$rc" = 2 ] && { echo "VA: ja aplicado (3 patches)"; exit 0; }
[ "$rc" = 0 ] || exit 1
if [ "${1:-}" = seco ]; then aplica "$BIN" aplicar x || true; echo "VA (seco): patches aplicados na copia"; exit 0; fi
mkdir -p "$BK"; [ -f "$BK/driver" ] || cp -p "$BIN" "$BK/driver"
T=$(mktemp /tmp/vadrv.XXXXXX); cp -p "$BIN" "$T"; aplica "$T" aplicar x || { rm -f "$T"; exit 1; }
cp -p "$T" "$BIN" && rm -f "$T"
codesign -f -s - "$B" >/dev/null 2>&1 || echo "aviso: codesign do bundle falhou (a assinatura do OCLP pode nao valer mais)"
echo "VA: aplicado (3 patches; o 3o faz a operacao de conversao falhar e o VideoToolbox usar software); backup em $BK. Teste: tools/macos-metaltest/xe-vtpt"
