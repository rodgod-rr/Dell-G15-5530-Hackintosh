//  G15PM: religa a RTX quando um programa a pede (10/11/2026).
//
//  O G15.app (com o G15Fan, RtxPm) para a RTX ociosa: NVRM e audio HDMI no estado 0 e, com -g15fan-rtxpm-corte, energia
//  cortada (GOFF). O NVAccel continua registrado e o Metal ainda lista a placa para os programas da nvmtl-allow.txt; um
//  trabalho mandado com ela parada travaria. Aqui o NVAccel::newUserClient (todo programa que abre a RTX passa por ele) e
//  trocado (Lilu): antes do original chama G15Fan::callPlatformFunction("G15RtxWake"), que religa (RtxPm 1: GONN, IOPM
//  acorda o NVRM) e so volta com o NVRM no estado 1. Registro G15RtxWake = {aberturas, religadas, ultima espera ms,
//  falhas, gancho}. -g15rtxwake-off desliga.
#include <Headers/kern_api.hpp>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <sys/proc.h>

static mach_vm_address_t gNaOrg = 0;
static uint32_t gWk[6] {};   // [5] = aberturas recusadas (coletores com a RTX parada)
static UInt32 gWkType = 0;
static void wkPublish() { IORegistryEntry::getRegistryRoot()->setProperty("G15RtxWake", gWk, sizeof(gWk)); }

// Coletores periodicos (systemstats abre o NVAccel tipo 33 a cada ~10 min): com a RTX parada, recusa em vez de religar.
static bool wkIsCollector() {
	char nm[24] {}; proc_selfname(nm, sizeof(nm));
	return !strcmp(nm, "systemstats");
}

// true = recusar a abertura
static bool wkEnsure() {
	auto m = IOService::serviceMatching("G15Fan");
	auto it = m ? IOService::getMatchingServices(m) : nullptr;
	OSSafeReleaseNULL(m);
	auto fan = it ? OSDynamicCast(IOService, it->getNextObject()) : nullptr;
	if (fan) fan->retain();
	OSSafeReleaseNULL(it);
	if (!fan) return false;
	bool deny = false;
	auto parked = OSDynamicCast(OSBoolean, fan->getProperty("RtxParked"));
	// parada, ou acordando (NVRM ainda no estado 0): pede ao G15Fan e espera
	bool need = parked && parked->isTrue();
	if (!need) {
		auto mn = IOService::serviceMatching("NVRM");
		auto nv = mn ? OSDynamicCast(IOService, IOService::copyMatchingService(mn)) : nullptr;
		OSSafeReleaseNULL(mn);
		need = nv && nv->getPowerState() < 1;
		OSSafeReleaseNULL(nv);
	}
	if (need && wkIsCollector() && !checkKernelArgument("-g15rtxwake-all")) { gWk[5]++; deny = true; need = false; }
	if (need) {
		uint32_t ms = 0;
		auto sym = OSSymbol::withCString("G15RtxWake");
		IOReturn e = sym ? fan->callPlatformFunction(sym, true, &ms, nullptr, nullptr, nullptr) : kIOReturnNoMemory;
		OSSafeReleaseNULL(sym);
		gWk[1]++; gWk[2] = ms;
		// quem pediu: "G15RtxWakeWho" = ultimos 6 processos que religaram a RTX ("nome pid tipo"), o mais novo primeiro
		static char who[6][40]; static unsigned nwho = 0;
		for (unsigned k = 5; k > 0; k--) memcpy(who[k], who[k - 1], sizeof(who[0]));
		char nm[24] {}; proc_selfname(nm, sizeof(nm));
		snprintf(who[0], sizeof(who[0]), "%s %d t%u", nm, proc_selfpid(), gWkType);
		if (nwho < 6) nwho++;
		auto arr = OSArray::withCapacity(nwho);
		for (unsigned k = 0; arr && k < nwho; k++) { auto st = OSString::withCString(who[k]); if (st) { arr->setObject(st); st->release(); } }
		if (arr) { IORegistryEntry::getRegistryRoot()->setProperty("G15RtxWakeWho", arr); arr->release(); }
		if (e != kIOReturnSuccess || ms == 0xFFFFFFFF) gWk[3]++;
		IOLog("G15PM: RTX pedida por um programa: religada (0x%x, %u ms)\n", e, ms);
	}
	fan->release();
	return deny;
}

static IOReturn naNewUC(IOService *that, task_t owningTask, void *securityID, UInt32 type, IOUserClient **handler) {
	gWk[0]++; gWkType = type;
	bool deny = wkEnsure();
	wkPublish();
	if (deny) return kIOReturnNotReady;
	return FunctionCast(naNewUC, gNaOrg)(that, owningTask, securityID, type, handler);
}

static const char *gNaPath[] {"/Library/Extensions/NVAccel.kext/Contents/MacOS/NVAccel"};
static KernelPatcher::KextInfo gNa {"com.nullmoth.NVAccel", gNaPath, arrsize(gNaPath), {true}, {}, KernelPatcher::KextInfo::Unloaded};

void rtxWakeInstall() {
	if (checkKernelArgument("-g15rtxwake-off")) return;
	gWk[4] = 9; wkPublish();   // 9 = esperando o NVAccel carregar
	lilu.onKextLoadForce(&gNa, 1, [](void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
		if (!gNa.loadIndex || index != gNa.loadIndex) return;
		mach_vm_address_t fn = patcher.solveSymbol(index, "__ZN7NVAccel13newUserClientEP4taskPvjPP12IOUserClient", address, size);
		if (!fn) { gWk[4] = 2; patcher.clearError(); wkPublish(); IOLog("G15PM: NVAccel::newUserClient nao achado\n"); return; }
		gNaOrg = patcher.routeFunction(fn, reinterpret_cast<mach_vm_address_t>(naNewUC), true);
		if (patcher.getError() != KernelPatcher::Error::NoError) { gNaOrg = 0; gWk[4] = 3; patcher.clearError(); }
		else gWk[4] = 1;
		wkPublish();
		IOLog("G15PM: gancho do NVAccel::newUserClient %s\n", gWk[4] == 1 ? "instalado" : "FALHOU");
	});
}
