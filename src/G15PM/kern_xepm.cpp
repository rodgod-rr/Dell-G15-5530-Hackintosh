//  G15PM: o XE-PM do NootedGreen (JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe @99631db, src/NootedGreen/kern_xepm.cpp,
//  licenca Thou Shalt Not Profit 1.0, ver LICENSE-NootedGreen) num kext Lilu proprio, sem a parte de video do
//  NootedGreen, para usar no Dell G15 5530 com a tela na RTX (NullMoth). Mudancas: boot-args e sysctl renomeados
//  (-g15pm, g15pmepp, g15pmcst; debug.g15pm) para nao colidir com o NootedGreen; ISH do PCH 700-series (0x7a78) na
//  lista de D3; sem o PL1 do MCHBAR (o g15-power/BIOS cuidam dele); EPP por perfil pelo G15PMControl
//  (g15pm_control.cpp: o G15.app grava {"EPP": n} ao trocar o perfil).
//
//  XE-PM: CPU performance and idle power profile for hybrid Alder Lake / Raptor Lake (and Tiger Lake) under XCPM.
//  Opt-in with -g15pm. Everything is applied 20 s after the patcher loads (system up), re-checked at 60 s.
//
//  1. HWP units (hybrid P-cores). XCPM writes IA32_HWP_REQUEST (0x774) max/desired in 100 MHz ratio units (max = the
//     TURBO_RATIO_LIMIT value, 50 on an i7-1360P). On hybrid P-cores one HWP performance unit is ~78.7 MHz (Linux
//     intel_pstate hybrid scaling factor 78741; HWP_CAPABILITIES highest = 64 for 5.0 GHz), so max 50 caps them at
//     ~3.9 GHz. The static XCPM routine at _xcpm_enable_pstate_ctrs+0x1190 (macOS 26.7.1 25G241) takes the target
//     multiplier and writes the local CPU's request; it is routed, and after Apple's write the request is rescaled on
//     cores whose highest perf exceeds the requested max (max -> highest, desired -> desired * highest / max). The
//     route is installed only after the prologue and the write site match byte for byte.
//  2. EPP. XCPM's frequency vector asks EPP 0x80. On ADL/RPL mobile parts that clips one-core turbo (Intel, Linux 5.17
//     intel_pstate: EPP <= 102 needed). The profile writes EPP 0 (g15pmepp=N to choose, sysctl debug.g15pm.epp).
//  3. Energy-efficient turbo off (MSR_POWER_CTL 0x1FC bit 19).
//  4. XCPM idle table (_xcpm_cstate_table): for the spoofed CPU it has C8 (0x40) and C10 (0x60) disabled and C3 (0x10,
//     not an ADL/RPL/TGL state) enabled, so cores stop at C6 or fall back to C1. C8/C10 are enabled and C3 disabled,
//     only if the three entries carry exactly those hints.
//  5. D3hot for PCI functions macOS has no driver for (IPU camera, GNA, ISH, DPTF participant, Thunderbolt/USB4 DMA),
//     by device id, only when nothing is attached (or only a client that never matched).
//  Measured on a Dell XPS 13 Plus 9320 (i7-1360P): Geekbench 7 single-core 1269 -> 1697, multi-core 5859 -> 6148,
//  one-thread clock 3.3 -> 4.3-4.85 GHz, idle package ~4.6 -> ~3.3 W.
#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <IOKit/IOLib.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <IOKit/pci/IOPCIDevice.h>
#include <kern/thread_call.h>
#include <sys/sysctl.h>
#include "g15_filelog.hpp"

extern "C" void mp_rendezvous_no_intrs(void (*fn)(void *), void *arg);
extern "C" int cpu_number(void);

static inline uint64_t xpRdmsr(uint32_t m) { uint32_t lo, hi; asm volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(m)); return ((uint64_t)hi << 32) | lo; }
static inline void xpWrmsr(uint32_t m, uint64_t v) { asm volatile("wrmsr" : : "c"(m), "a"((uint32_t)v), "d"((uint32_t)(v >> 32))); }

static bool gXpOn = false;
static int gXpHwp = 0, gXpEpp = -1;                 // sysctl debug.g15pm.hwp / .epp (root)
static int gXpEet = 0, gXpCst = 0, gXpD3 = 0, gXpRoute = 0;   // status
static mach_vm_address_t gXpOrgSetMult = 0, gXpCstPtr = 0;
static bool gXpCstWant = true;   // g15pmcst=0 keeps XCPM's idle table (coil whine from deep C-state transitions)

// ─── 1/2: XCPM HWP request ───────────────────────────────────────────────────────────────────────────────────────
static uint64_t xpSetMult(uint64_t mult, uint64_t a1, uint64_t a2, uint64_t a3) {   // only edi is used by Apple
	const uint64_t r = FunctionCast(xpSetMult, gXpOrgSetMult)(mult, a1, a2, a3);
	// XCPM calls this before it enables HWP; the HWP MSRs #GP until IA32_PM_ENABLE bit 0 is set.
	if (gXpHwp && (xpRdmsr(0x770) & 1)) {
		const uint64_t v = xpRdmsr(0x774);
		if (v & (1ULL << 42)) return r;   // package control: leave it alone
		const uint32_t hi = (uint32_t)(xpRdmsr(0x771) & 0xff), max = (uint32_t)(v >> 8) & 0xff, des = (uint32_t)(v >> 16) & 0xff;
		uint64_t nv = v;
		if (max && hi > max && hi < 0xff) {
			uint32_t d = des ? (des * hi + max / 2) / max : 0;
			if (d > hi) d = hi;
			nv = (nv & ~0xFFFF00ULL) | ((uint64_t)hi << 8) | ((uint64_t)d << 16);
		}
		if (gXpEpp >= 0) nv = (nv & ~0xFF000000ULL) | ((uint64_t)gXpEpp << 24);
		if (nv != v) xpWrmsr(0x774, nv);
	}
	return r;
}

// EPP ja aplicado em todos os nucleos (sem esperar o proximo pedido do XCPM): G15PMControl, quando o G15.app troca o perfil
static void xpEppOne(void *) {
	if (gXpEpp < 0 || !(xpRdmsr(0x770) & 1)) return;
	const uint64_t v = xpRdmsr(0x774);
	if (v & (1ULL << 42)) return;   // package control: leave it alone
	const uint64_t nv = (v & ~0xFF000000ULL) | ((uint64_t)gXpEpp << 24);
	if (nv != v) xpWrmsr(0x774, nv);
}
bool xePmActive() { return gXpOn; }
int xePmGetEpp() { return gXpEpp; }
bool xePmSetEpp(int e) {
	if (!gXpOn || e < 0 || e > 255) return false;
	gXpEpp = e;
	mp_rendezvous_no_intrs(xpEppOne, nullptr);
	return true;
}

// ─── 3: energy-efficient turbo ───────────────────────────────────────────────────────────────────────────────────
static void xpEetOne(void *) {
	const uint64_t v = xpRdmsr(0x1FC);
	if (!(v & (1ULL << 19))) xpWrmsr(0x1FC, v | (1ULL << 19));
}

// ─── 4: XCPM idle table ──────────────────────────────────────────────────────────────────────────────────────────
// on = C8/C10 enabled, C3 disabled; !on = XCPM's own table back. Returns 1 (fix on), 0 (stock), 2-4 errors.
static int xpCstSet(bool on) {
	uint8_t *tab = gXpCstPtr ? *reinterpret_cast<uint8_t **>(gXpCstPtr) : nullptr;
	if (!tab) return 2;
	auto hint = [&](int i) { return *reinterpret_cast<volatile uint32_t *>(tab + i * 24 + 4); };
	auto en = [&](int i) { return reinterpret_cast<volatile uint32_t *>(tab + i * 24 + 8); };
	if (hint(0) != 0x60 || hint(2) != 0x40 || hint(6) != 0x10) return 3;
	const uint32_t want = on ? 1 : 0;
	if (*en(0) == want && *en(2) == want && *en(6) == !want) return on ? 1 : 0;
	if (MachInfo::setKernelWriting(true, KernelPatcher::kernelWriteLock) != KERN_SUCCESS) return 4;
	*en(0) = want; *en(2) = want; *en(6) = !want;
	MachInfo::setKernelWriting(false, KernelPatcher::kernelWriteLock);
	return on ? 1 : 0;
}
static int xpCstFix() { return xpCstSet(gXpCstWant); }

// ─── 5: D3hot for driverless functions ───────────────────────────────────────────────────────────────────────────
static int xpD3() {
	static const uint16_t ids[] = {
		0xa75d, 0x465d, 0x9a19,           // IPU6 camera (RPL-P, ADL-P, TGL)
		0xa74f, 0x464f, 0x9a11,           // GNA
		0x51fc, 0x54fc, 0xa0fc, 0x7a78,   // ISH (ADP-P, ADP-N, TGP-LP, 700-series PCH: G15 5530)
		0xa71d, 0x461d, 0x9a03,           // DPTF processor participant
		0xa73e, 0xa76d, 0x463e, 0x466d, 0x9a1b, 0x9a1d,   // Thunderbolt 4 / USB4 DMA (macOS has no host driver here)
	};
	int n = 0;
	OSIterator *it = IOService::getMatchingServices(IOService::serviceMatching("IOPCIDevice"));
	if (!it) return 0;
	while (auto *o = it->getNextObject()) {
		auto *d = OSDynamicCast(IOPCIDevice, o);
		if (!d) continue;
		if (IOService *cl = d->getClient())   // e.g. a USBToolBox instance on the TBT DMA that never matched
			if (cl->getState() & (kIOServiceMatchedState | kIOServiceRegisteredState)) continue;
		const uint32_t id = d->configRead32(0);
		if ((id & 0xffff) != 0x8086) continue;
		bool want = false;
		for (uint16_t w : ids) if (w == (id >> 16)) want = true;
		uint8_t pm = 0;
		if (!want || !d->findPCICapability(kIOPCIPowerManagementCapability, &pm) || !pm) continue;
		const uint16_t cs = d->configRead16(pm + 4);
		if ((cs & 3) != 3) { d->configWrite16(pm + 4, (uint16_t)(cs | 3)); n++; }
	}
	it->release();
	return n;
}

static void xpApply(thread_call_param_t, thread_call_param_t) {
	gXpCst = xpCstFix();
	gXpD3 += xpD3();
	if (!gXpEet) { mp_rendezvous_no_intrs(xpEetOne, nullptr); gXpEet = (int)((xpRdmsr(0x1FC) >> 19) & 1); }
	if (gXpOrgSetMult) gXpHwp = 1;   // takes effect at XCPM's next request on each CPU
	g15fl::logf("G15PM: profile on: HWP rescale %d (route %d), EPP %d, EE turbo off %d, C8/C10 %d, D3 %d",
	      gXpHwp, gXpRoute, gXpEpp, gXpEet, gXpCst, gXpD3);
	extern void g15pmControlPublish(); g15pmControlPublish();   // o G15PMControl pode ter publicado antes do perfil
}

// ─── sensors (always registered, read only): debug.g15pm.sensors ──────────────────────────────────────────────────
// The stack has no working CPU temperature source (SMCProcessor finds no instances), so the menu-bar tool reads this:
// struct { u32 version 1, ncpu, tjmax, pkg_temp_c; u8 core_temp_c[32]; u8 core_type[32] (0x40 P, 0x20 E);
//          u32 energy_unit_bits; u32 pad; u64 pkg_energy (0x611), ia_energy (0x639), gt_energy (0x641) }.
// Temperatures are TjMax minus the digital readout of IA32_THERM_STATUS / IA32_PACKAGE_THERM_STATUS.
struct XpSensors { uint32_t ver, ncpu, tjmax, pkg; uint8_t core[32], type[32]; uint32_t eunit, pad; uint64_t epkg, eia, egt; };
static XpSensors gXpSens;
static void xpSensOne(void *) {
	const int c = cpu_number();
	if (c < 0 || c >= 32) return;
	const uint32_t tj = (uint32_t)(xpRdmsr(0x1A2) >> 16) & 0xff, dro = (uint32_t)(xpRdmsr(0x19C) >> 16) & 0x7f;
	gXpSens.core[c] = (uint8_t)(tj > dro ? tj - dro : 0);
	uint32_t r[4];
	asm volatile("cpuid" : "=a"(r[0]), "=b"(r[1]), "=c"(r[2]), "=d"(r[3]) : "a"(0x1A), "c"(0));
	gXpSens.type[c] = (uint8_t)(r[0] >> 24);
	__sync_fetch_and_add(&gXpSens.ncpu, 1);
}
static int xpSensors SYSCTL_HANDLER_ARGS {
	bzero(&gXpSens, sizeof(gXpSens));
	gXpSens.ver = 1;
	mp_rendezvous_no_intrs(xpSensOne, nullptr);
	gXpSens.tjmax = (uint32_t)(xpRdmsr(0x1A2) >> 16) & 0xff;
	const uint32_t pd = (uint32_t)(xpRdmsr(0x1B1) >> 16) & 0x7f;
	gXpSens.pkg = gXpSens.tjmax > pd ? gXpSens.tjmax - pd : 0;
	gXpSens.eunit = (uint32_t)(xpRdmsr(0x606) >> 8) & 0x1f;
	gXpSens.epkg = xpRdmsr(0x611) & 0xffffffffULL;
	gXpSens.eia = xpRdmsr(0x639) & 0xffffffffULL;
	gXpSens.egt = xpRdmsr(0x641) & 0xffffffffULL;
	return SYSCTL_OUT(req, &gXpSens, sizeof(gXpSens));
}

SYSCTL_NODE(_debug, OID_AUTO, g15pm, CTLFLAG_RW, 0, "G15PM (XE-PM do NootedGreen)");
SYSCTL_PROC(_debug_g15pm, OID_AUTO, sensors, CTLTYPE_OPAQUE | CTLFLAG_RD | CTLFLAG_ANYBODY, nullptr, 0, xpSensors, "S", "temperatures and RAPL energy");
SYSCTL_INT(_debug_g15pm, OID_AUTO, hwp, CTLFLAG_RW, &gXpHwp, 0, "HWP rescale on hybrid P-cores");
SYSCTL_INT(_debug_g15pm, OID_AUTO, epp, CTLFLAG_RW, &gXpEpp, 0, "EPP override, -1 = XCPM's");
SYSCTL_INT(_debug_g15pm, OID_AUTO, eet_off, CTLFLAG_RD, &gXpEet, 0, "");
static int xpCstCtl SYSCTL_HANDLER_ARGS {   // sudo sysctl -w debug.g15pm.cst=0|1 (live)
	int v = gXpCst;
	int err = SYSCTL_OUT(req, &v, sizeof(v));
	if (err || !req->newptr) return err;
	if ((err = SYSCTL_IN(req, &v, sizeof(v)))) return err;
	gXpCstWant = v != 0;
	gXpCst = xpCstSet(gXpCstWant);
	return gXpCst >= 2 ? EIO : 0;
}
SYSCTL_PROC(_debug_g15pm, OID_AUTO, cst, CTLTYPE_INT | CTLFLAG_RW, nullptr, 0, xpCstCtl, "I", "1 = C8/C10 on (write 0/1, root)");
SYSCTL_INT(_debug_g15pm, OID_AUTO, d3, CTLFLAG_RD, &gXpD3, 0, "");
SYSCTL_INT(_debug_g15pm, OID_AUTO, route, CTLFLAG_RD, &gXpRoute, 0, "1 = HWP route installed");

void xePmInstall(KernelPatcher &patcher) {
	sysctl_register_oid(&sysctl__debug_g15pm);           // the sensors are always there (menu-bar temperature tool)
	sysctl_register_oid(&sysctl__debug_g15pm_sensors);
	if (!checkKernelArgument("-g15pm")) return;
	gXpOn = true;
	int e = 0;
	gXpEpp = (PE_parse_boot_argn("g15pmepp", &e, sizeof(e)) && e >= 0 && e <= 255) ? e : 0;
	int cw = 1;
	if (PE_parse_boot_argn("g15pmcst", &cw, sizeof(cw))) gXpCstWant = cw != 0;
	gXpCstPtr = patcher.solveSymbol(KernelPatcher::KernelID, "_xcpm_cstate_table");
	patcher.clearError();
	const mach_vm_address_t base = patcher.solveSymbol(KernelPatcher::KernelID, "_xcpm_enable_pstate_ctrs");
	patcher.clearError();
	if (base) {
		const mach_vm_address_t fn = base + 0x1190;
		static const uint8_t pro[] = {0x55, 0x48, 0x89, 0xE5, 0x53, 0x50, 0x89, 0xFB};   // push rbp; mov rbp,rsp; push rbx; push rax; mov ebx,edi
		static const uint8_t wr[] = {0x89, 0xF8, 0xC1, 0xEA, 0x18, 0xB9, 0x74, 0x07, 0x00, 0x00, 0x0F, 0x30};   // +0x168: ...; mov ecx,0x774; wrmsr
		auto *p = reinterpret_cast<const uint8_t *>(fn);
		bool ok = true;
		for (size_t i = 0; i < sizeof(pro); i++) if (p[i] != pro[i]) ok = false;
		for (size_t i = 0; i < sizeof(wr); i++) if (p[0x168 + i] != wr[i]) ok = false;
		if (ok) {
			gXpOrgSetMult = patcher.routeFunction(fn, reinterpret_cast<mach_vm_address_t>(xpSetMult), true);
			if (patcher.getError() != KernelPatcher::Error::NoError) { gXpOrgSetMult = 0; patcher.clearError(); }
		}
		gXpRoute = gXpOrgSetMult ? 1 : (ok ? 5 : 3);
	} else gXpRoute = 2;
	sysctl_register_oid(&sysctl__debug_g15pm_hwp);
	sysctl_register_oid(&sysctl__debug_g15pm_epp);
	sysctl_register_oid(&sysctl__debug_g15pm_eet_off);
	sysctl_register_oid(&sysctl__debug_g15pm_cst);
	sysctl_register_oid(&sysctl__debug_g15pm_d3);
	sysctl_register_oid(&sysctl__debug_g15pm_route);
	uint64_t dl;
	thread_call_t t20 = thread_call_allocate(xpApply, nullptr), t60 = thread_call_allocate(xpApply, nullptr);
	clock_interval_to_deadline(20, kSecondScale, &dl);
	if (t20) thread_call_enter_delayed(t20, dl);
	clock_interval_to_deadline(60, kSecondScale, &dl);
	if (t60) thread_call_enter_delayed(t60, dl);
	g15fl::logf("G15PM: -g15pm, HWP route %d, idle table %s; profile in 20 s", gXpRoute, gXpCstPtr ? "found" : "missing");
}
