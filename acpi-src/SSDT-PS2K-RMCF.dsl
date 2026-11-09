/*
 * G15 5530: configuracao do VoodooPS2Keyboard (RMCF) no teclado interno \_SB.PC00.LPCB.PS2K.
 * Fn+F10 (PrtSc) manda e0 37 (visto no Linux: scancode 0xb7, KEY_SYSRQ). O perfil Dell do VoodooPS2 troca e037 por e01e
 * ("nao deixar o PrtSc desligar o touchpad") e a tecla nao chega ao macOS. Aqui: e037 continua e037 e vira F13 (ADB 0x69),
 * que o G15.app usa para a captura de tela.
 */
DefinitionBlock ("", "SSDT", 2, "G15", "PS2RMCF", 0x00000000)
{
    External (_SB_.PC00.LPCB.PS2K, DeviceObj)

    Scope (_SB.PC00.LPCB.PS2K)
    {
        Method (RMCF, 0, NotSerialized)
        {
            If (_OSI ("Darwin"))
            {
                Return (Package ()
                {
                    "Keyboard", Package ()
                    {
                        "Custom PS2 Map", Package ()
                        {
                            Package () {},
                            "e037=e037"
                        },
                        "Custom ADB Map", Package ()
                        {
                            Package () {},
                            "e037=69"
                        }
                    }
                })
            }
            Return (Package () {})
        }
    }
}
