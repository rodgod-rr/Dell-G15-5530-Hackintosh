// G15PM: plugin Lilu minimo que so instala o XE-PM (kern_xepm.cpp). Ligado com -g15pm; -g15pmoff desliga o plugin.
#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#define G15FL_IMPL
#include "g15_filelog.hpp"

extern void xePmInstall(KernelPatcher &);
extern void rtd3Install();
extern void rtxWakeInstall();
extern void rtxRevokeInstall();
extern void btIdleInstall();

static const char *bootargOff[] {"-g15pmoff"};
static const char *bootargDebug[] {"-g15pmdbg"};

PluginConfiguration ADDPR(config) {
	xStringify(PRODUCT_NAME),
	parseModuleVersion(xStringify(MODULE_VERSION)),
	LiluAPI::AllowNormal,
	bootargOff,
	arrsize(bootargOff),
	bootargDebug,
	arrsize(bootargDebug),
	nullptr,
	0,
	KernelVersion::Ventura,
	KernelVersion::Tahoe,
	[]() {
		g15fl::init("g15pm");
		lilu.onPatcherLoadForce([](void *, KernelPatcher &patcher) { xePmInstall(patcher); });
		rtd3Install();
		rtxWakeInstall();
		rtxRevokeInstall();
		btIdleInstall();
	},
};
