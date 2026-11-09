/*
 * Desligar a RTX 4050 no Deep Idle do macOS pelo G15Fan.kext (Dell G15 5530). Os testes mostraram que no Deep Idle o
 * macOS nao roda nenhum metodo ACPI de sono: nem _PS3/_PS0 do PEG1 (SSDT-RTXOFF), nem do LPCB (SSDT-PEPS0), nem
 * _PTS/_WAK (deepidle-hook); docs/SONO-MACOS.md. Por isso quem chama e o G15Fan.kext, que se registra no sono do
 * macOS com registerPrioritySleepWakeInterest: e avisado DEPOIS dos outros drivers ao dormir (o NullMoth ja parou a
 * GPU e salvou a VRAM) e ANTES deles ao acordar (a RTX volta antes do NVRM).
 *   GOFF: corta a energia da RTX pelo recurso de energia dela (PG01._OFF -> NPOF -> PGOF, como o _PR3 no Linux).
 *   GONN: religa (PG01._ON -> NPON -> PGON, que espera a RTX responder no PCI).
 *   GSLP: contadores para o ioreg "SleepDebug" do G15Fan: bits 0-7 vezes do GOFF, 8-15 vezes do GONN,
 *         16 = RTX desligada agora, 24-31 GSTA antes do _OFF (1 = ligada; 0xFF = sem leitura).
 * Sem este SSDT o G15Fan nao mexe na RTX (os metodos nao existem). Nao carregar junto com RTXOFF/SLPHOOK (GSLP).
 * Risco: se a RTX nao voltar, o NPON espera o PCI (tela preta) -> segurar o botao e voltar a config deepidle.
 * Compilar: iasl acpi/opt/SSDT-RTXKEXT.dsl (config deepidle-kext).
 */
DefinitionBlock ("", "SSDT", 2, "G15", "RtxKext", 0x00001000)
{
    External (\_SB.AMWW, DeviceObj)
    External (\_SB.PC00.PEG1.PG01, PowerResObj)
    External (\_SB.PC00.PEG1.PG01._ON_, MethodObj)
    External (\_SB.PC00.PEG1.PG01._OFF, MethodObj)
    External (\_SB.PC00.PEG1.PEGP.GSTA, MethodObj)

    Scope (\_SB.AMWW)
    {
        Name (KOFC, Zero)                   // vezes do GOFF
        Name (KONC, Zero)                   // vezes do GONN
        Name (KOFF, Zero)                   // 1 = a RTX foi desligada pelo GOFF
        Name (KSTA, 0xFF)                   // GSTA antes do _OFF

        Method (GOFF, 0, Serialized)
        {
            KOFC = ((KOFC + One) & 0xFF)
            If (CondRefOf (\_SB.PC00.PEG1.PEGP.GSTA))
            {
                KSTA = \_SB.PC00.PEG1.PEGP.GSTA ()
            }

            If ((KOFF == Zero))
            {
                \_SB.PC00.PEG1.PG01._OFF ()
                KOFF = One
            }

            Return (KSTA)
        }

        Method (GONN, 0, Serialized)
        {
            KONC = ((KONC + One) & 0xFF)
            If ((KOFF == One))
            {
                \_SB.PC00.PEG1.PG01._ON ()
                KOFF = Zero
            }

            Return (Zero)
        }

        Method (GSLP, 0, NotSerialized)     // contadores para o G15Fan.kext
        {
            Return ((((KOFC | (KONC << 0x08)) | (KOFF << 0x10)) | ((KSTA & 0xFF) << 0x18)))
        }
    }
}
