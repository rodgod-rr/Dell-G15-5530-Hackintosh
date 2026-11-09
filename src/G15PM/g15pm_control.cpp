// G15PMControl: deixa o G15.app (usuario da sessao grafica) trocar o EPP do G15PM sem root, como o G15Fan faz com as
// ventoinhas. Escrita: IORegistryEntrySetCFProperties com {"EPP": 0..255} (0 = desempenho, 128 = equilibrado,
// 192 = economia, 255 = maximo de economia). Leitura: propriedades "EPP" e "Active" (G15PM ligado com -g15pm).
// Medido no G15 (docs/SONO-MACOS.md, "G15PM"): parado, EPP 0 gasta ~4 W a mais no pacote que EPP 128; o turbo de um
// nucleo vai de 4,2-4,5 GHz (EPP 0) a 3,75-4,1 GHz (EPP 128).
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>

bool xePmActive();
int xePmGetEpp();
bool xePmSetEpp(int e);

class G15PMControl : public IOService {
	OSDeclareDefaultStructors(G15PMControl)
public:
	static G15PMControl *instance;
	void publish() {
		setProperty("Active", xePmActive());
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
			IOLog("G15PM: EPP %u (%s)\n", e, r == kIOReturnSuccess ? "ok" : "erro");
		}
		publish();
		return r;
	}
};

OSDefineMetaClassAndStructors(G15PMControl, IOService)
G15PMControl *G15PMControl::instance = nullptr;

void g15pmControlPublish() { if (G15PMControl::instance) G15PMControl::instance->publish(); }   // chamado aos 20/60 s
