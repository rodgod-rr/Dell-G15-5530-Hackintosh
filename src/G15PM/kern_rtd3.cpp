//  G15PM: RTD3 da NullMoth 2.9 no Dell G15 5530 (10/11/2026).
//
//  O RTD3 da 2.9 (nvrtd3=1 nvrtd3res=\_SB.PC00.PEG1.PG01) corta a energia da RTX ociosa chamando o _OFF/_ON do recurso
//  de energia. O NVRM faz isso no evalMethod(acpi, "_OFF"), que monta "<recurso>._OFF" e chama
//  IOACPIPlatformDevice::evaluateObject. Medido aqui (G15Fan, RTD3Probe): o evaluateObject da Apple so executa NOME
//  SIMPLES; qualquer nome com ponto ("\_SB.AMWW.GSLP", "PG01._STA", o caminho do recurso) volta 0xe00002c2, entao o
//  RTD3 nunca desliga nada ("power-off failed, GPU resumed and left on").
//  Aqui o evalMethod do NVRM e trocado (Lilu, so com nvrtd3=1): "_OFF" -> GOFF e "_ON" -> GONN no \_SB.AMWW do nosso
//  SSDT-RTXKEXT, que chamam o mesmo PG01._OFF/_ON por dentro do ACPI (o caminho que o G15Fan ja usa no repouso).
//  Outros metodos vao para o original. Registro: G15RTD3 = {off ok, off falha, on ok, on falha, outros, gancho}.
//  So com -g15rtd3 (10/11: travou o sistema ao cortar a energia; ver o roteiro).
#include <Headers/kern_api.hpp>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IONVRAM.h>
#include "g15_filelog.hpp"

//  (10/11, 2a versao) Sequencia como a do Linux, que o AML do PG01 pressupoe (ssdt11: o _ON tira o root port de D3hot,
//  PEG1.D3HT=0, e espera a RTX responder). _OFF: salva a config (256 B) da GPU (fn0) e do audio HDMI (fn1), poe fn1, fn0
//  e o root port PEG1 em D3hot (PMCSR) e chama GOFF. _ON: GONN, root port e funcoes em D0, restaura a config (BARs, MSI,
//  comando por ultimo). -g15rtd3seco: faz tudo menos o GOFF (testa o D3hot e a restauracao sem cortar a energia) e
//  devolve "falhou" ao NullMoth, que retoma a GPU.
//  G15RTD3 = {off ok, off falha, on ok, on falha, outros, gancho, ultimo passo, PMCSR fn0, PMCSR fn1, PMCSR PEG1}.
static mach_vm_address_t gRtOrg = 0;
static uint32_t gRt[10] {};

// Rastro na NVRAM (sobrevive a desligar no botao): "g15-rtd3-trail" = ultimo passo e contagem, gravado e sincronizado a
// cada passo. Ler depois com: nvram g15-rtd3-trail. 1 off entra, 2 config salva, 3 D3hot feito, 4 GOFF chamado,
// 5 GOFF voltou ok, 6 on entra, 7 GONN voltou, 8 config restaurada.
static uint32_t gTrailN = 0;
static void rtTrail(uint32_t step) {
	auto nv = OSDynamicCast(IODTNVRAM, IORegistryEntry::fromPath("/options", gIODTPlane));
	if (!nv) return;
	char b[48]; snprintf(b, sizeof b, "passo %u n %u", step, ++gTrailN);
	auto d = OSData::withBytes(b, static_cast<unsigned>(strlen(b)));
	auto k = OSSymbol::withCString("g15-rtd3-trail");
	if (d && k) { nv->setProperty(k, d); nv->sync(); }
	OSSafeReleaseNULL(d); OSSafeReleaseNULL(k);
	nv->release();
}

static void rtPublish() {
	IORegistryEntry::getRegistryRoot()->setProperty("G15RTD3", gRt, sizeof(gRt));
}

struct RtFn {
	IOPCIDevice *d {nullptr};
	UInt8 pm {0};
	uint32_t cfg[64] {};
	bool saved {false};
};
static RtFn gFn0, gFn1, gRp;

static bool rtAcpiPath(IOPCIDevice *d, const char *want) {
	auto o = OSDynamicCast(OSString, d->getProperty("acpi-path"));
	return o && !strcmp(o->getCStringNoCopy(), want);
}

static bool rtFind() {
	if (gFn0.d && gFn1.d && gRp.d) return true;
	auto m = IOService::serviceMatching("IOPCIDevice");
	auto it = m ? IOService::getMatchingServices(m) : nullptr;
	OSSafeReleaseNULL(m);
	IOPCIDevice *fn0 = nullptr, *fn1 = nullptr, *rp = nullptr;
	while (auto o = it ? it->getNextObject() : nullptr) {
		auto d = OSDynamicCast(IOPCIDevice, o);
		if (!d) continue;
		if (rtAcpiPath(d, "IOACPIPlane:/_SB/PC00/PEG1@10000")) rp = d;
		else if (rtAcpiPath(d, "IOACPIPlane:/_SB/PC00/PEG1@10000/PEGP@0")) fn0 = d;
	}
	OSSafeReleaseNULL(it);
	if (fn0) {   // fn1: mesmo barramento e dispositivo da GPU, funcao 1, NVIDIA
		auto m2 = IOService::serviceMatching("IOPCIDevice");
		auto it2 = m2 ? IOService::getMatchingServices(m2) : nullptr;
		OSSafeReleaseNULL(m2);
		while (auto o = it2 ? it2->getNextObject() : nullptr) {
			auto d = OSDynamicCast(IOPCIDevice, o);
			if (d && d != fn0 && d->getBusNumber() == fn0->getBusNumber() && d->getDeviceNumber() == fn0->getDeviceNumber() &&
			    d->getFunctionNumber() == 1 && (d->configRead32(0) & 0xFFFF) == 0x10DE) fn1 = d;
		}
		OSSafeReleaseNULL(it2);
	}
	if (!fn0 || !fn1 || !rp) return false;
	gFn0.d = fn0; gFn1.d = fn1; gRp.d = rp;
	RtFn *all[] {&gFn0, &gFn1, &gRp};
	for (RtFn *f : all) { f->d->retain(); f->d->findPCICapability(kIOPCIPowerManagementCapability, &f->pm); }
	return gFn0.pm && gFn1.pm && gRp.pm;
}

static void rtSetD(RtFn &f, uint16_t st) {
	if (!f.pm) return;
	uint16_t v = f.d->configRead16(f.pm + 4);
	f.d->configWrite16(f.pm + 4, (v & ~3) | st);
	IOSleep(10);   // D3hot <-> D0: 10 ms (PCIe)
}
static void rtSave(RtFn &f) { for (int i = 0; i < 64; i++) f.cfg[i] = f.d->configRead32(static_cast<UInt8>(i * 4)); f.saved = true; }
static void rtRestore(RtFn &f) {
	if (!f.saved) return;
	for (int i = 2; i < 64; i++) f.d->configWrite32(static_cast<UInt8>(i * 4), f.cfg[i]);   // tudo menos IDs e comando (RO / por ultimo)
	f.d->configWrite32(4, f.cfg[1]);
}
static void rtPm() {
	gRt[7] = gFn0.pm ? gFn0.d->configRead16(gFn0.pm + 4) : 0xFFFF;
	gRt[8] = gFn1.pm ? gFn1.d->configRead16(gFn1.pm + 4) : 0xFFFF;
	gRt[9] = gRp.pm ? gRp.d->configRead16(gRp.pm + 4) : 0xFFFF;
}

static IOReturn rtAmww(const char *m) {
	auto amww = OSDynamicCast(IOACPIPlatformDevice, IORegistryEntry::fromPath("IOACPIPlane:/_SB/AMWW"));
	UInt32 r = 0;
	IOReturn e = amww ? amww->evaluateInteger(m, &r) : kIOReturnNotFound;
	OSSafeReleaseNULL(amww);
	return e;
}

static void rtBackOn() {   // D0 e config de volta (sem mexer na energia)
	rtSetD(gRp, 0); rtSetD(gFn0, 0); rtSetD(gFn1, 0);
	rtRestore(gFn0); rtRestore(gFn1);
}

static bool rtOff() {
	rtTrail(1);
	if (!rtFind()) { gRt[6] = 10; return false; }
	rtSave(gFn0); rtSave(gFn1);
	rtTrail(2);
	rtSetD(gFn1, 3); rtSetD(gFn0, 3); rtSetD(gRp, 3);
	rtTrail(3);
	rtPm(); gRt[6] = 11;
	if (checkKernelArgument("-g15rtd3seco")) { rtBackOn(); rtPm(); gRt[6] = 12; return false; }
	rtTrail(4);
	IOReturn e = rtAmww("GOFF");
	rtTrail(e == kIOReturnSuccess ? 5 : 15);
	if (e != kIOReturnSuccess) { rtBackOn(); rtPm(); gRt[6] = 13; return false; }
	gRt[6] = 14;
	return true;
}

static bool rtOn() {
	rtTrail(6);
	IOReturn e = rtAmww("GONN");   // AML: liga, PEG1.D3HT=0, CMDR=7, espera a RTX responder
	rtTrail(7);
	if (e != kIOReturnSuccess) { gRt[6] = 21; return false; }
	rtBackOn(); rtPm(); gRt[6] = 22;
	rtTrail(8);
	return true;
}

static bool rtEval(IOACPIPlatformDevice *acpi, const char *method) {
	uint32_t on = 0;
	if (!PE_parse_boot_argn("nvrtd3", &on, sizeof(on)) || on != 1) return false;   // como o original
	bool isOff = method && !strcmp(method, "_OFF");
	bool isOn = method && (!strcmp(method, "_ON") || !strcmp(method, "_ON_"));
	if (!isOff && !isOn) {
		gRt[4]++; rtPublish();
		return gRtOrg ? FunctionCast(rtEval, gRtOrg)(acpi, method) : false;
	}
	const bool ok = isOff ? rtOff() : rtOn();
	gRt[isOff ? (ok ? 0 : 1) : (ok ? 2 : 3)]++;
	rtPublish();
	g15fl::logf("G15PM: RTD3 %s -> %s (passo %u)", method, ok ? "ok" : "falhou", gRt[6]);
	return ok;
}

static const char *gNvrmPath[] {"/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM"};
static KernelPatcher::KextInfo gNvrm {"com.nullmoth.NVRM", gNvrmPath, arrsize(gNvrmPath), {true}, {}, KernelPatcher::KextInfo::Unloaded};

void rtd3Install() {
	uint32_t on = 0;
	// 10/11: com o gancho o GOFF desliga a RTX e o sistema TRAVA ~2 min depois do boot (3 boots, sem panic). Agora so com
	// -g15rtd3 explicito (alem de nvrtd3=1), para nao ligar por engano.
	if (!PE_parse_boot_argn("nvrtd3", &on, sizeof(on)) || on != 1 || !checkKernelArgument("-g15rtd3")) return;
	gRt[5] = 9; rtPublish();   // 9 = esperando o NVRM carregar
	lilu.onKextLoadForce(&gNvrm, 1, [](void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
		if (!gNvrm.loadIndex || index != gNvrm.loadIndex) return;
		mach_vm_address_t fn = patcher.solveSymbol(index, "__ZL10evalMethodP20IOACPIPlatformDevicePKc", address, size);
		if (!fn) { gRt[5] = 2; patcher.clearError(); rtPublish(); g15fl::logf("G15PM: RTD3: evalMethod do NVRM nao achado"); return; }
		gRtOrg = patcher.routeFunction(fn, reinterpret_cast<mach_vm_address_t>(rtEval), true);
		if (patcher.getError() != KernelPatcher::Error::NoError) { gRtOrg = 0; gRt[5] = 3; patcher.clearError(); }
		else gRt[5] = 1;
		rtPublish();
		g15fl::logf("G15PM: RTD3: gancho do evalMethod do NVRM %s", gRt[5] == 1 ? "instalado" : "FALHOU");
	});
}
