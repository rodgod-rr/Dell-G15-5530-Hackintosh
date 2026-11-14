//  G15PM: Bluetooth USB que dorme quando ocioso (14/11/2026, WhateverXe #87).
//
//  O BT do G15 (Intel AX201, 8087:0026) e um aparelho USB Full Speed cujo dono exclusivo e o bluetoothd. O IOUSBHostFamily
//  so suspende um aparelho ocioso se o driver ligar uma politica de ocio (IOUSBHostFamily.h, "Idle suspend" e "Pausing IO":
//  IOUSBHostInterface::setIdlePolicy + IOUSBHostPipe::setIdlePolicy nos IN interrupt/bulk, que sempre tem leitura
//  pendente). O bluetoothd nao liga (nos Macs o BT e UART/PCIe), entao com o BT ligado a porta nunca suspende e o pacote
//  fica em PC2 (+5 W). Aqui o IOUSBHostInterface::copyPipe e trocado (Lilu): quando o bluetoothd pega os pipes IN 0x81
//  (eventos HCI) e 0x82 (ACL) da interface 0 de um BT Intel, liga a politica nos dois e na interface. O aparelho suspende
//  e acorda sozinho (remote wake) quando tem dado. Como no Linux (btusb autosuspend), o risco e o firmware nao acordar.
//  sysctl debug.g15btidle = ms da politica (padrao 50; 0 = nao liga). Vale na proxima vez que o BT ligar.
//  Registro "G15BtIdle" = {gancho (1 ok, 2 simbolo, 3 rota), pipes ligados, interfaces ligadas, ultimo IOReturn do pipe,
//  ultimo IOReturn da interface, ms}. -g15btidle-off desliga.
#include <Headers/kern_api.hpp>
#include <IOKit/IOService.h>
#include <sys/sysctl.h>
#include <kern/thread_call.h>
#include <sys/proc.h>
#include "g15_filelog.hpp"

static mach_vm_address_t gCpOrg = 0, gPipeIdle = 0, gIfIdle = 0;
static uint32_t gBi[7] {};   // [6] = IntelBluetoothFirmware tirados da arvore de energia (automatico)
static int gBiMs = 50;
static void biPublish() { gBi[5] = (uint32_t)gBiMs; IORegistryEntry::getRegistryRoot()->setProperty("G15BtIdle", gBi, sizeof(gBi)); }

static uint32_t biNum(IORegistryEntry *e, const char *k) {
	auto n = e ? OSDynamicCast(OSNumber, e->getProperty(k)) : nullptr;
	return n ? n->unsigned32BitValue() : 0xFFFFFFFFu;
}

// (14/11, 2a etapa) Mesmo com a politica a porta nao suspendia: o IntelBluetoothFirmware (carrega o firmware no boot e
// fica parado) segue como filho de energia do IOUSBHostDevice num estado sem kIOPMLowPower, e o IOUSBHostFamily.h diz que
// isso desliga o idle suspend. Com PMstop nele (sysctl debug.g15btidle_fw=1) a porta passou a ficar 63% suspensa.
// 3a etapa: feito sozinho, numa thread_call, na 1a vez que o bluetoothd pega um pipe de cada aparelho BT (cada
// reenumeracao cria aparelho e IntelBluetoothFirmware novos). debug.g15btidle_fw: 1 = PMstop, 2 = terminate (a mao);
// a leitura devolve quantos foram tratados na ultima vez.
static int gBiFw = 0;
static int fwDetach(int v) {
	int n = 0;
	// o IntelBluetoothFirmware nao e registrado (getMatchingServices nao o ve): procura nos filhos do BT Intel
	auto m = IOService::serviceMatching("IOUSBHostDevice");
	auto it = m ? IOService::getMatchingServices(m) : nullptr;
	OSSafeReleaseNULL(m);
	while (auto dev = it ? OSDynamicCast(IOService, it->getNextObject()) : nullptr) {
		if (biNum(dev, "idVendor") != 0x8087 || biNum(dev, "bDeviceClass") != 0xE0) continue;
		auto ci = dev->getChildIterator(gIOServicePlane);
		while (auto c = ci ? OSDynamicCast(IOService, ci->getNextObject()) : nullptr) {
			if (!c->metaCast("IntelBluetoothFirmware")) continue;
			if (v == 1) { if (!c->getProperty("G15PMStop")) { c->PMstop(); c->setProperty("G15PMStop", true); n++; } }
			else { c->terminate(); n++; }
			g15fl::logf("G15PM: IntelBluetoothFirmware: %s", v == 1 ? "PMstop" : "terminate");
		}
		OSSafeReleaseNULL(ci);
	}
	OSSafeReleaseNULL(it);
	gBiFw = n;
	return n;
}
static int biFwSysctl SYSCTL_HANDLER_ARGS {
	int v = gBiFw; const int e = sysctl_handle_int(oidp, &v, 0, req);
	if (e || !req->newptr || (v != 1 && v != 2)) return e;
	fwDetach(v);
	return 0;
}
static thread_call_t gFwCall = nullptr;
static uint64_t gFwDevId = 0;
static void fwCallFn(thread_call_param_t, thread_call_param_t) { gBi[6] += (uint32_t)fwDetach(1); biPublish(); }

static void *cpHook(IOService *that, uint8_t address) {
	void *pipe = FunctionCast(cpHook, gCpOrg)(that, address);
	if (!pipe || gBiMs <= 0) return pipe;
	IOService *dev = that->getProvider();
	if (biNum(dev, "idVendor") != 0x8087 || biNum(dev, "bDeviceClass") != 0xE0) return pipe;
	// so quando quem abre e o bluetoothd: a 1a abertura (~2 s do boot) e do proprio IntelBluetoothFirmware no start()
	if (gFwCall && dev->getRegistryEntryID() != gFwDevId) {
		char nm[24] {}; proc_selfname(nm, sizeof(nm));
		if (!strcmp(nm, "bluetoothd")) { gFwDevId = dev->getRegistryEntryID(); thread_call_enter(gFwCall); }
	}
	auto setPipe = reinterpret_cast<IOReturn (*)(void *, uint32_t)>(gPipeIdle);
	auto setIf = reinterpret_cast<IOReturn (*)(void *, uint32_t)>(gIfIdle);
	IOReturn ri = setIf ? setIf(that, (uint32_t)gBiMs) : kIOReturnUnsupported;   // toda interface do BT (a 1 e a do audio SCO)
	gBi[2] += ri == kIOReturnSuccess; gBi[4] = (uint32_t)ri;
	if ((address != 0x81 && address != 0x82) || biNum(that, "bInterfaceNumber") != 0) { biPublish(); return pipe; }
	IOReturn rp = setPipe ? setPipe(pipe, (uint32_t)gBiMs) : kIOReturnUnsupported;
	gBi[1] += rp == kIOReturnSuccess; gBi[3] = (uint32_t)rp;
	biPublish();
	if (gBi[1] <= 4) g15fl::logf("G15PM: BT pipe 0x%02x: politica de ocio %d ms (pipe 0x%x, interface 0x%x)", address, gBiMs, rp, ri);
	return pipe;
}

SYSCTL_PROC(_debug, OID_AUTO, g15btidle_fw, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_LOCKED, nullptr, 0, biFwSysctl, "I", "");

static int biSysctl SYSCTL_HANDLER_ARGS {
	int v = gBiMs; const int e = sysctl_handle_int(oidp, &v, 0, req);
	if (!e && req->newptr) { gBiMs = v < 0 ? 0 : v > 10000 ? 10000 : v; biPublish(); }
	return e;
}
SYSCTL_PROC(_debug, OID_AUTO, g15btidle, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY | CTLFLAG_LOCKED, nullptr, 0, biSysctl, "I", "");

static const char *gUsbPath[] {"/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily"};
static KernelPatcher::KextInfo gUsb {"com.apple.iokit.IOUSBHostFamily", gUsbPath, arrsize(gUsbPath), {true}, {}, KernelPatcher::KextInfo::Unloaded};

void btIdleInstall() {
	if (checkKernelArgument("-g15btidle-off")) return;
	sysctl_register_oid(&sysctl__debug_g15btidle); sysctl_register_oid(&sysctl__debug_g15btidle_fw);
	gFwCall = thread_call_allocate(fwCallFn, nullptr);
	gBi[0] = 9; biPublish();   // 9 = esperando o IOUSBHostFamily
	lilu.onKextLoadForce(&gUsb, 1, [](void *, KernelPatcher &patcher, size_t index, mach_vm_address_t address, size_t size) {
		if (!gUsb.loadIndex || index != gUsb.loadIndex) return;
		gPipeIdle = patcher.solveSymbol(index, "__ZN13IOUSBHostPipe13setIdlePolicyEj", address, size); patcher.clearError();
		gIfIdle = patcher.solveSymbol(index, "__ZN18IOUSBHostInterface13setIdlePolicyEj", address, size); patcher.clearError();
		mach_vm_address_t fn = patcher.solveSymbol(index, "__ZN18IOUSBHostInterface8copyPipeEh", address, size);
		if (!fn || !gPipeIdle || !gIfIdle) { gBi[0] = 2; patcher.clearError(); biPublish(); g15fl::logf("G15PM: simbolos do IOUSBHost nao achados"); return; }
		gCpOrg = patcher.routeFunction(fn, reinterpret_cast<mach_vm_address_t>(cpHook), true);
		if (patcher.getError() != KernelPatcher::Error::NoError) { gCpOrg = 0; gBi[0] = 3; patcher.clearError(); }
		else gBi[0] = 1;
		biPublish();
		g15fl::logf("G15PM: gancho do IOUSBHostInterface::copyPipe %s", gBi[0] == 1 ? "instalado" : "FALHOU");
	});
}
