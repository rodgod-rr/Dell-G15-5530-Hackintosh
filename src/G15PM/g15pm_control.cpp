// G15PMControl: deixa o G15.app (usuario da sessao grafica) trocar o EPP do G15PM sem root, como o G15Fan faz com as
// ventoinhas. Escrita: IORegistryEntrySetCFProperties com {"EPP": 0..255} (0 = desempenho, 128 = equilibrado,
// 192 = economia, 255 = maximo de economia) e {"RtxDeny": bool} (11/11, perfil Bateria: RTX parada nao religa).
// Leitura: propriedades "EPP", "RtxDeny" e "Active" (G15PM ligado com -g15pm).
// Medido no G15 (docs/SONO-MACOS.md, "G15PM"): parado, EPP 0 gasta ~4 W a mais no pacote que EPP 128; o turbo de um
// nucleo vai de 4,2-4,5 GHz (EPP 0) a 3,75-4,1 GHz (EPP 128).
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include "g15_filelog.hpp"

bool xePmActive();
int xePmGetEpp();
bool xePmSetEpp(int e);
void rtxWakeSetDeny(bool d);
void rtxRevokeSet(bool on);
UInt64 rtxCallsGet();
const char *rtxCallsLast();
void rtxWakeSetLazy(bool l);
bool rtxWakeGetLazy();
bool rtxRevokeGet();
bool rtxWakeGetDeny();

class G15PMControl : public IOService {
	OSDeclareDefaultStructors(G15PMControl)
public:
	static G15PMControl *instance;
	void publish() {
		setProperty("Active", xePmActive());
		setProperty("RtxDeny", rtxWakeGetDeny());
		setProperty("RtxRevoke", rtxRevokeGet());
		setProperty("RtxLazy", rtxWakeGetLazy());
		setProperty("RtxCalls", rtxCallsGet(), 64);        // chamadas ao driver da RTX (atividade); {"Refresh": 1} atualiza
		setProperty("RtxCallsLast", rtxCallsLast());      // listar as placas nao religa a RTX parada (kern_wake)      // prototipo (kern_revoke): mapeamentos da RTX revogados       // perfil Bateria: RTX parada recusa aberturas (kern_wake)
		if (xePmGetEpp() >= 0) setProperty("EPP", (unsigned long long)xePmGetEpp(), 32); else removeProperty("EPP");
	}
	bool start(IOService *provider) override {
		if (!IOService::start(provider)) return false;
		instance = this;
		publish();
		registerService();
		return true;
	}
	IOReturn setProperties(OSObject *props) override {
		auto d = OSDynamicCast(OSDictionary, props);
		if (!d) return kIOReturnBadArgument;
		// usuario da sessao grafica (o G15.app) ou root, como no G15Fan
		if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeLocalUser) != kIOReturnSuccess &&
		    IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
			return kIOReturnNotPrivileged;
		IOReturn r = kIOReturnSuccess;
		if (auto n = OSDynamicCast(OSNumber, d->getObject("EPP"))) {
			const uint32_t e = n->unsigned32BitValue();
			if (e > 255) r = kIOReturnBadArgument;
			else if (!xePmSetEpp((int)e)) r = kIOReturnNotReady;   // G15PM desligado (sem -g15pm)
			g15fl::logf("G15PM: EPP %u (%s)", e, r == kIOReturnSuccess ? "ok" : "erro");
		}
		if (auto o = d->getObject("RtxDeny")) {
			auto b = OSDynamicCast(OSBoolean, o); auto n = OSDynamicCast(OSNumber, o);
			const bool v = b ? b->isTrue() : n ? n->unsigned32BitValue() != 0 : false;
			rtxWakeSetDeny(v);
			g15fl::logf("G15PM: RtxDeny %d", v);
		}
		if (auto o = d->getObject("RtxLazy")) {
			auto b = OSDynamicCast(OSBoolean, o); auto n = OSDynamicCast(OSNumber, o);
			rtxWakeSetLazy(b ? b->isTrue() : n ? n->unsigned32BitValue() != 0 : false);
			g15fl::logf("G15PM: RtxLazy %d", rtxWakeGetLazy());
		}
		if (auto o = d->getObject("RtxRevoke")) {
			auto b = OSDynamicCast(OSBoolean, o); auto n = OSDynamicCast(OSNumber, o);
			rtxRevokeSet(b ? b->isTrue() : n ? n->unsigned32BitValue() != 0 : false);
		}
		publish();
		return r;
	}
};

OSDefineMetaClassAndStructors(G15PMControl, IOService)
G15PMControl *G15PMControl::instance = nullptr;

void g15pmControlPublish() { if (G15PMControl::instance) G15PMControl::instance->publish(); }   // chamado aos 20/60 s
