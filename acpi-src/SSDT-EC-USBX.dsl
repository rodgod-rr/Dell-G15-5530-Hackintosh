DefinitionBlock ("", "SSDT", 2, "G15HAK", "ECUSBX", 0x00001000)
{
    External (_SB_.PC00.LPCB, DeviceObj)
    // EC real da Dell (ECDV, PNP0C09) e escondido do macOS dentro da DSDT corrigida (acpi/dsdt-flat.dsl)

    Scope (\_SB.PC00.LPCB)
    {
        Device (EC)
        {
            Name (_HID, "ACID0001")
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin")) { Return (0x0F) } Else { Return (Zero) }
            }
        }
    }
    Scope (\_SB)
    {
        Device (USBX)
        {
            Name (_ADR, Zero)
            Method (_DSM, 4, NotSerialized)
            {
                If (!Arg2) { Return (Buffer (One) { 0x03 }) }
                Return (Package (0x08)
                {
                    "kUSBSleepPortCurrentLimit", 3000,
                    "kUSBWakePortCurrentLimit", 3000,
                    "kUSBSleepPowerSupply", 9600,
                    "kUSBWakePowerSupply", 9600
                })
            }
        }
    }
}
