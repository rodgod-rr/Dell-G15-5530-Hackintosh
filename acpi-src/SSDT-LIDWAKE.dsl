/*
 * Tampa acorda o Deep Idle do macOS, Dell G15 5530 (09/11/2026). Montado a mao (sem iasl no Mac):
 * tools/macos-ssdt-lidwake.py gera o SSDT-LIDWAKE.aml igual a este fonte.
 * O AppleACPIPlatform le o PRW0 de cada dispositivo com _PRW (como nos Macs reais): o GPE do PRW0 vira o
 * "acpi-wake-s0-gpe", o GPE armado no repouso S0 (Deep Idle) no lugar do GPE do _PRW. O _PRW da tampa (GPE 0x18)
 * ja e armado, mas o EC nao o aciona no Deep Idle. Aqui a tampa aponta para o GPE do proprio EC (0x6E, ECDV._GPE com
 * eSPI), como o Linux faz no s2idle (o GPE do EC fica ligado para acordar). So o macOS le o PRW0.
 * Efeito colateral possivel: outros eventos do EC (bateria, carregador, temperatura) tambem acordarem o Mac.
 */
DefinitionBlock ("", "SSDT", 2, "G15", "LidWake", 0x00001000)
{
    External (\_SB.LID0, DeviceObj)

    Scope (\_SB.LID0)
    {
        Name (PRW0, Package (0x02) { 0x6E, 0x03 })
    }
}
