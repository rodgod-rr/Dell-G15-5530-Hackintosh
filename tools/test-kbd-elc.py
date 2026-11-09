#!/usr/bin/env python3
"""Teste de cores, zonas e efeitos do controlador Alienware AW-ELC (USB 187c:0551) do G15 5530 no Fedora, antes de
levar para o G15.app. So biblioteca padrao; nao instala nada. Nada e gravado na memoria do controlador (exceto 'salvar').

Protocolo (OpenRGB AlienwareController e alienfx-tools API v4, so leitura): relatorio de 33 bytes, sem report ID,
byte 0 = 0x03, byte 1 = comando:
  20 <sub>                       relatorio: 00 firmware, 01 status, 02 config (plataforma em [3..4], zonas em [5])
  21 <sub16> <anim16> <dur16>    animacao: 0001 nova, 0002 fim+grava, 0003 fim+toca, 0004 apaga, 0005 toca,
                                 0006 padrao, 0007 inicio; anim FFFF = temporaria, 0061 = padrao, 0008 = inicio
  23 01 <n16> <zonas...>         seleciona zonas para as acoes seguintes
  24 {<modo> <dur16> <tempo16> <r g b>} x ate 3   acoes: modo 00 cor, 01 pulso, 02 morph (transicao)
  26 <dim> <n16> <zonas...>      brilho: dim 0 = 100%, 100 = apagada
  27 <r g b> <n16> <zonas...>    cor direta (OpenRGB: "causa um piscar")
Zonas do 5530 segundo o OpenRGB: 10 11 12 13 (esq, meio, dir, numerico); o brilho usa 00 01 02 03 hoje.

Uso (sudo):
  tools/test-kbd-elc.py info
  tools/test-kbd-elc.py cor ff0000                  # teclado todo vermelho
  tools/test-kbd-elc.py zonas ff0000 00ff00 0000ff ffffff
  tools/test-kbd-elc.py efeito pulso 00ffff --tempo 200 --dur 2000
  tools/test-kbd-elc.py efeito morph ff0000 0000ff
  tools/test-kbd-elc.py efeito espectro|onda|respira [cor]
  tools/test-kbd-elc.py direta 00ff00               # comando 27
  tools/test-kbd-elc.py dim 50
  opcoes: --ids 10 (padrao) ou --ids 0; --modo ctrl (padrao) ou intr; -v mostra os pacotes
"""
import argparse, fcntl, os, pathlib, select, sys, time

VID_PID, LEN = "0000187C:00000551", 33
RAINBOW = [0xFF0000, 0xFFA500, 0xFFFF00, 0x008000, 0x00BFFF, 0x0000FF, 0x800080]

def find_hidraw():
    for h in sorted(pathlib.Path("/sys/class/hidraw").iterdir()):
        if f"HID_ID=0003:{VID_PID}" in (h / "device" / "uevent").read_text():
            return "/dev/" + h.name
    sys.exit("ERRO: AW-ELC 187c:0551 nao encontrado")

def HIDIOCSOUTPUT(n): return (3 << 30) | (n << 16) | (ord("H") << 8) | 0x0B
def HIDIOCGINPUT(n): return (3 << 30) | (n << 16) | (ord("H") << 8) | 0x0A
def HIDIOCGFEATURE(n): return (3 << 30) | (n << 16) | (ord("H") << 8) | 0x07

def get_report(fd):                            # resposta por GET_REPORT (entrada, depois feature), como o OpenRGB
    for nome, req in (("in", HIDIOCGINPUT), ("feat", HIDIOCGFEATURE)):
        b = bytearray(LEN + 1)
        try:
            n = fcntl.ioctl(fd, req(len(b)), b)
            return nome, bytes(b[1:]) if b[0] == 0 and b[1] == 3 else bytes(b)
        except OSError as e:
            last = f"{nome}: {e.strerror}"
    return last, b""

class ELC:
    def __init__(s, modo, verbose):
        s.fd, s.modo, s.v = os.open(find_hidraw(), os.O_RDWR), modo, verbose
    def send(s, *b, wait=0.06):
        pkt = bytes([0x03, *b]).ljust(LEN, b"\0")[:LEN]
        buf = b"\0" + pkt
        if s.modo == "ctrl": fcntl.ioctl(s.fd, HIDIOCSOUTPUT(len(buf)), bytearray(buf))
        else: os.write(s.fd, buf)
        r, _, _ = select.select([s.fd], [], [], 0.3)
        resp, via = (os.read(s.fd, 64), "intr") if r else (b"", "")
        if not resp: via, resp = get_report(s.fd)
        if s.v: print(" >", pkt[:24].hex(" "), f"\n <{via}", resp[:24].hex(" ") if resp else "(sem resposta)")
        time.sleep(wait)
        return resp
    def anim(s, sub, anim=0xFFFF, dur=0):
        return s.send(0x21, sub >> 8, sub & 255, anim >> 8, anim & 255, dur >> 8, dur & 255,
                      wait=1.0 if sub in (3, 5) else 0.06)
    def zones(s, ids): s.send(0x23, 1, 0, len(ids), *ids)
    def actions(s, acts):                                  # [(modo, dur, tempo, rgb)], ate 3 por pacote
        for i in range(0, len(acts), 3):
            b = []
            for m, d, t, c in acts[i:i + 3]:
                b += [m, d >> 8, d & 255, t >> 8, t & 255, c >> 16, (c >> 8) & 255, c & 255]
            s.send(0x24, *b)

def rgb(x): return int(x.lstrip("#"), 16)

def main():
    ap = argparse.ArgumentParser(description="teste do AW-ELC 0551 (cores, zonas, efeitos)")
    ap.add_argument("cmd", choices=("info", "cor", "zonas", "efeito", "direta", "dim", "salvar"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--ids", default="10", choices=("10", "0"))
    ap.add_argument("--modo", default="ctrl", choices=("ctrl", "intr"))
    ap.add_argument("--tempo", type=int, default=0xFA)     # 0x64..0xFA no AWCC (maior = mais rapido?)
    ap.add_argument("--dur", type=int, default=2000)       # periodo em ms
    ap.add_argument("-v", action="store_true")
    a = ap.parse_args()
    if os.geteuid() != 0: sys.exit("rode com sudo")
    ids = [0x10, 0x11, 0x12, 0x13] if a.ids == "10" else [0, 1, 2, 3]
    e = ELC(a.modo, a.v or a.cmd == "info")

    if a.cmd == "info":
        for sub, nome in ((0, "firmware"), (1, "status"), (2, "config"), (3, "animacoes")):
            print(f"-- {nome}"); e.send(0x20, sub)
        return
    if a.cmd == "dim":
        e.send(0x26, 100 - int(a.args[0]), 0, len(ids), *ids); return
    if a.cmd == "direta":
        c = rgb(a.args[0]); e.send(0x27, c >> 16, (c >> 8) & 255, c & 255, 0, len(ids), *ids); return

    anim = 0x0061 if a.cmd == "salvar" else 0xFFFF
    if a.cmd == "salvar":                                  # grava a cor (args = 1 ou 4 cores) como padrao/inicio
        e.anim(4, anim)
    cores = [rgb(x) for x in a.args] if a.cmd != "efeito" else []
    e.anim(1, anim)
    if a.cmd in ("cor", "zonas", "salvar"):
        if len(cores) == 1:
            e.zones(ids); e.actions([(0, a.dur, a.tempo, cores[0])])
        else:
            for z, c in zip(ids, cores): e.zones([z]); e.actions([(0, a.dur, a.tempo, c)])
    else:
        tipo, extra = a.args[0], [rgb(x) for x in a.args[1:]]
        for i, z in enumerate(ids):
            e.zones([z])
            if tipo == "pulso":    acts = [(1, a.dur, a.tempo, extra[0] if extra else 0xFFFFFF)]
            elif tipo == "morph":  acts = [(2, a.dur, a.tempo, c) for c in (extra or [0xFF0000, 0x0000FF])]
            elif tipo == "respira": acts = [(2, a.dur, a.tempo, extra[0] if extra else 0xFFFFFF), (2, a.dur, a.tempo, 0)]
            elif tipo == "espectro": acts = [(2, a.dur, a.tempo, c) for c in RAINBOW]
            elif tipo == "onda":   acts = [(2, a.dur, a.tempo, c) for c in RAINBOW[-i:] + RAINBOW[:-i]] if i else \
                                          [(2, a.dur, a.tempo, c) for c in RAINBOW]
            else: sys.exit("efeito: pulso, morph, respira, espectro, onda")
            e.actions(acts)
    if a.cmd == "salvar":
        e.anim(2, anim); e.anim(6, anim); e.anim(7, anim)
    else:
        e.anim(3, anim)
    print("ok")

if __name__ == "__main__":
    main()
