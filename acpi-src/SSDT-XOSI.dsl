/*
 * XOSI: no macOS responde "sim" para as versoes do Windows (como na EFI do XPS), para o firmware da Dell
 * seguir o caminho do Windows. Sem isso o \_SB.OSID fica < 0x20 e o SMEE descarta o evento das teclas de
 * brilho (Fn+F6/F7) antes do Notify(LCD, 0x86/0x87) em \_SB.PC00.PEG1.PEGP. Fora do macOS repassa ao _OSI real.
 * A DSDT do G15 (acpi/dsdt-flat.dsl) chama XOSI no lugar de _OSI (troca feita no codigo-fonte por tools/flatten-dsdt.py).
 */
DefinitionBlock ("", "SSDT", 2, "G15HAK", "XOSI", 0x00001000)
{
    Method (XOSI, 1, NotSerialized)
    {
        Local0 = Package (0x0A)
        {
            "Windows 2001", "Windows 2001 SP1", "Windows 2001.1", "Windows 2001 SP2", "Windows 2006",
            "Windows 2009", "Windows 2012", "Windows 2013", "Windows 2015", "Windows 2020"
        }
        If (_OSI ("Darwin"))
        {
            Return ((Match (Local0, MEQ, Arg0, MTR, Zero, Zero) != Ones))
        }
        Return (_OSI (Arg0))
    }
}
