DefinitionBlock ("", "SSDT", 2, "G15HAK", "AWACOFF", 0x00000000)
{
    External (STAS, IntObj)            // se STAS=1 o AWAC fica desligado e o RTC legado (PNP0B00) liga
    Scope (\)
    {
        Method (_INI, 0, NotSerialized)
        {
            If (_OSI ("Darwin")) { STAS = One }
        }
    }
}
