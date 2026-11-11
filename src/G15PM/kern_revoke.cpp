//  G15PM: "revoke" da RTX - religar sozinha quando um programa conectado volta a usa-la (11/11/2026, PROTOTIPO).
//
//  O trabalho do Metal (NVK) vai da memoria do programa direto para a placa: pushbuffer e doorbell (USERMODE) em
//  mapeamentos da BAR que o NVRMUserClient::clientMemoryForType entrega como descritores fisicos
//  (IOMemoryDescriptor::withPhysicalAddress / kIOMemoryTypePhysical64). Com a RTX cortada, uma escrita ali travaria.
//  Aqui (docs/RTX-OCIOSA-REVOKE.md, "Plano"):
//    1. gancho no clientMemoryForType: guarda (retain) os descritores fisicos que o NVRM entrega;
//    2. G15PMControl {"RtxRevoke": 1} (antes de parar a RTX): redirect(NULL, true) em todos -> o IOKit tira as paginas
//       dos programas; o proximo acesso faz page fault no device pager -> IOMemoryDescriptor::handleFault, que dorme
//       enquanto o descritor estiver redirecionado;
//    3. gancho no handleFault: descritor nosso e revoke ligado -> agenda (thread_call, fora do caminho do fault) religar
//       a RTX (G15Fan "G15RtxWake", espera o NVRM no estado 1) e redirect(false) em todos: a thread acorda e segue;
//    4. gancho no NVRMUserClient::externalMethod: chamada ao driver com o revoke ligado -> religa antes (sincrono).
//  Sem "RtxRevoke" os ganchos so repassam. Registro "G15RtxRevoke" = {descritores guardados, revogacoes, faults nossos,
//  religadas por fault, religadas por chamada, ultima espera ms, ganchos (bits: 1 cmft 2 fault 4 extm)};
//  "G15RtxRevokeWho" = ultimos que acordaram. -g15revoke-off nao instala.
#include <Headers/kern_api.hpp>
#include <IOKit/IOService.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/IOLib.h>
#include <kern/thread_call.h>
#include <sys/proc.h>

static mach_vm_address_t gCmftOrg, gFaultOrg, gExtOrg;
static IOLock *gRvLock;
static const unsigned kRvMax = 4096;
static IOMemoryDescriptor *gRv[kRvMax];
static unsigned gRvN;
static volatile bool gRevoked;
static volatile UInt32 gWakeQueued;
static thread_call_t gWakeCall;
static uint32_t gRs[7] {};
static void rvPublish() { IORegistryEntry::getRegistryRoot()->setProperty("G15RtxRevoke", gRs, sizeof(gRs)); }

static void rvWho(const char *how) {
	static char who[6][48]; static unsigned n;
	for (unsigned k = 5; k > 0; k--) memcpy(who[k], who[k - 1], sizeof(who[0]));
	char nm[24] {}; proc_selfname(nm, sizeof(nm));
	snprintf(who[0], sizeof(who[0]), "%s %d %s", nm, proc_selfpid(), how);
	if (n < 6) n++;
	auto arr = OSArray::withCapacity(n);
	for (unsigned k = 0; arr && k < n; k++) { auto s = OSString::withCString(who[k]); if (s) { arr->setObject(s); s->release(); } }
	if (arr) { IORegistryEntry::getRegistryRoot()->setProperty("G15RtxRevokeWho", arr); arr->release(); }
}

static bool rvTracked(IOMemoryDescriptor *md) {
	bool f = false;
	IOLockLock(gRvLock);
	for (unsigned i = 0; i < gRvN && !f; i++) f = gRv[i] == md;
	IOLockUnlock(gRvLock);
	return f;
}

// redirect em todos os guardados (fora do gRvLock: o redirect pega o gIOMemoryLock)
static void rvApply(bool on) {
	// copia em memoria alocada (a pilha do kernel e de 16 KB)
	auto snap = static_cast<IOMemoryDescriptor **>(IOMalloc(sizeof(IOMemoryDescriptor *) * kRvMax)); unsigned n = 0;
	if (!snap) return;
	IOLockLock(gRvLock);
	for (unsigned i = 0; i < gRvN; i++) { gRv[i]->retain(); snap[n++] = gRv[i]; }
	IOLockUnlock(gRvLock);
	if (on) gRevoked = true;
	for (unsigned i = 0; i < n; i++) { snap[i]->redirect(nullptr, on); snap[i]->release(); }
	if (!on) gRevoked = false;
	IOFree(snap, sizeof(IOMemoryDescriptor *) * kRvMax);
	IOLog("G15PM: revoke %s em %u descritor(es)\n", on ? "LIGADO" : "desligado", n);
}

static uint32_t rvWakeGpu() {                       // G15Fan religa e espera o NVRM; devolve ms
	uint32_t ms = 0;
	auto m = IOService::serviceMatching("G15Fan");
	auto fan = m ? IOService::copyMatchingService(m) : nullptr;
	OSSafeReleaseNULL(m);
	if (auto f = OSDynamicCast(IOService, fan)) {
		auto sym = OSSymbol::withCString("G15RtxWake");
		if (sym) { f->callPlatformFunction(sym, true, &ms, nullptr, nullptr, nullptr); sym->release(); }
	}
	OSSafeReleaseNULL(fan);
	return ms;
}

static void rvWakeAll(const char *why) {
	uint32_t ms = rvWakeGpu();
	gRs[5] = ms;
	rvApply(false);
	IOLog("G15PM: revoke: RTX religada (%s, %u ms)\n", why, ms);
}

static void rvWakeCallFn(thread_call_param_t, thread_call_param_t) {
	rvWakeAll("fault");
	gRs[3]++; rvPublish();
	OSCompareAndSwap(1, 0, &gWakeQueued);
}

// 1. descritores da BAR que o NVRM entrega aos programas
static IOReturn rvCmft(void *that, UInt32 type, IOOptionBits *options, IOMemoryDescriptor **memory) {
	IOReturn r = FunctionCast(rvCmft, gCmftOrg)(that, type, options, memory);
	if (r != kIOReturnSuccess || !memory || !*memory) return r;
	IOMemoryDescriptor *md = *memory;
	const IOOptionBits t = md->getFlags() & kIOMemoryTypeMask;
	if (t != kIOMemoryTypePhysical && t != kIOMemoryTypePhysical64) return r;   // RAM (IOSubMemoryDescriptor): nao
	IOLockLock(gRvLock);
	bool have = false;
	unsigned w = 0;                                  // limpa os que so nos seguramos (mapeamento ja desfeito)
	for (unsigned i = 0; i < gRvN; i++) {
		if (gRv[i] == md) have = true;
		if (gRv[i] != md && gRv[i]->getRetainCount() <= 1) { gRv[i]->release(); continue; }
		gRv[w++] = gRv[i];
	}
	gRvN = w;
	if (!have && gRvN < kRvMax) { md->retain(); gRv[gRvN++] = md; }
	gRs[0] = gRvN;
	IOLockUnlock(gRvLock);
	return r;
}

// 3. page fault num descritor redirecionado
static IOReturn rvFault(IOMemoryDescriptor *that, void *pager, mach_vm_size_t off, mach_vm_size_t len) {
	if (gRevoked && rvTracked(that)) {
		gRs[2]++;
		if (OSCompareAndSwap(0, 1, &gWakeQueued)) { rvWho("fault"); thread_call_enter(gWakeCall); }
		rvPublish();
	}
	return FunctionCast(rvFault, gFaultOrg)(that, pager, off, len);   // dorme ate o redirect(false)
}

// (11/11) atividade: toda chamada ao driver de um programa (NVK: alocar, mandar trabalho, esperar) conta. O G15.app so
// considera a RTX ociosa se este contador nao andar durante todo o tempo do modo (como o RTD3 fino do Linux, que conta
// cada ioctl). "RtxCalls" (total) e "RtxCallsLast" (ultimo programa) no G15PMControl.
static volatile UInt64 gCalls;
static char gCallsLast[24];
UInt64 rtxCallsGet() { return gCalls; }
const char *rtxCallsLast() { return gCallsLast; }

// 4. chamada ao driver com o revoke ligado: religa antes
static IOReturn rvExt(void *that, uint32_t sel, void *args, void *disp, void *target, void *ref) {
	OSIncrementAtomic64(reinterpret_cast<volatile SInt64 *>(&gCalls));
	if ((gCalls & 63) == 1) proc_selfname(gCallsLast, sizeof(gCallsLast));   // nome de vez em quando (barato)
	if (gRevoked) {
		rvWho("chamada");
		rvWakeAll("chamada ao driver");
		gRs[4]++; rvPublish();
	}
	return FunctionCast(rvExt, gExtOrg)(that, sel, args, disp, target, ref);
}

void rtxRevokeSet(bool on) {                        // G15PMControl "RtxRevoke"
	if (!gRvLock) return;
	if (on) { gRs[1]++; rvApply(true); }
	else rvApply(false);
	rvPublish();
}
bool rtxRevokeGet() { return gRevoked; }

static const char *gNvPath[] {"/Library/Extensions/NVRM.kext/Contents/MacOS/NVRM"};
static KernelPatcher::KextInfo gNv {"com.nullmoth.NVRM", gNvPath, arrsize(gNvPath), {true}, {}, KernelPatcher::KextInfo::Unloaded};

void rtxRevokeInstall() {
	if (checkKernelArgument("-g15revoke-off")) return;
	gRvLock = IOLockAlloc();
	gWakeCall = thread_call_allocate(rvWakeCallFn, nullptr);
	if (!gRvLock || !gWakeCall) return;
	rvPublish();
	lilu.onPatcherLoadForce([](void *, KernelPatcher &patcher) {
		mach_vm_address_t fn = patcher.solveSymbol(KernelPatcher::KernelID, "__ZN18IOMemoryDescriptor11handleFaultEPvyy");
		if (fn) gFaultOrg = patcher.routeFunction(fn, reinterpret_cast<mach_vm_address_t>(rvFault), true);
		if (!fn || patcher.getError() != KernelPatcher::Error::NoError) { gFaultOrg = 0; patcher.clearError(); IOLog("G15PM: revoke: handleFault FALHOU\n"); }
		else gRs[6] |= 2;
		rvPublish();
	});
	lilu.onKextLoadForce(&gNv, 1, [](void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
		if (!gNv.loadIndex || index != gNv.loadIndex) return;
		mach_vm_address_t a = patcher.solveSymbol(index, "__ZN14NVRMUserClient19clientMemoryForTypeEjPjPP18IOMemoryDescriptor", address, size);
		if (a) gCmftOrg = patcher.routeFunction(a, reinterpret_cast<mach_vm_address_t>(rvCmft), true);
		if (!a || patcher.getError() != KernelPatcher::Error::NoError) { gCmftOrg = 0; patcher.clearError(); }
		else gRs[6] |= 1;
		mach_vm_address_t b = patcher.solveSymbol(index, "__ZN14NVRMUserClient14externalMethodEjP25IOExternalMethodArgumentsP24IOExternalMethodDispatchP8OSObjectPv", address, size);
		if (b) gExtOrg = patcher.routeFunction(b, reinterpret_cast<mach_vm_address_t>(rvExt), true);
		if (!b || patcher.getError() != KernelPatcher::Error::NoError) { gExtOrg = 0; patcher.clearError(); }
		else gRs[6] |= 4;
		rvPublish();
		IOLog("G15PM: revoke: ganchos 0x%x\n", gRs[6]);
	});
}
