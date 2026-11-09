/*
 * Deep Idle (AOAC) para o macOS no Dell G15 5530: dormir em S0 de baixo consumo, sem o S3.
 * A BIOS so tem Modern Standby (S3 desligado e travado pela Dell: docs/SONO-MACOS.md). Este SSDT cria os dois
 * ganchos que o AppleACPIPlatform procura para dormir em S0:
 *   \_SB.LPS0  = 1  plataforma suporta Low Power S0 Idle (o FADT ja tem o bit de Modern Standby)
 *   \_GPE.LXEN = 1  tratar os eventos _Lxx pendentes ao acordar
 * So vale no macOS (_OSI Darwin). Usar com a DSDT normal (sem _S3): config deepidle = nvidia-fan + este SSDT.
 * Ideia do OC-Little (AOAC) e da EFI do G15 5510 (KernelFox0); o DSDT do 5530 nao tem LPS0/LXEN.
 */
DefinitionBlock ("", "SSDT", 2, "G15", "DeepIdl", 0x00001000)
{
    Scope (\_SB)
    {
        Method (LPS0, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (One)
            }
            Return (Zero)
        }
    }

    Scope (\_GPE)
    {
        Method (LXEN, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (One)
            }
            Return (Zero)
        }
    }
}
