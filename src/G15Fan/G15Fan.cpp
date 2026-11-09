// G15Fan: ventoinhas do Dell G15 5530 no macOS pelo metodo ACPI WMAX do dispositivo \_SB.AMWW (PNP0C14, SSDT
// "AWCCTABL"), o mesmo caminho do driver alienware-wmi do Linux (drivers/platform/x86/dell/alienware-wmi-wmax.c).
//
// WMAX(Arg0 = 0, Arg1 = metodo, Arg2 = buffer de 4 bytes {operacao, arg1, arg2, 0}) -> inteiro de 32 bits
//   0x14 informacao: 02 descricao (n fans, n temps, n ?, n perfis), 03 id do recurso [indice], 04 temperatura [sensor],
//        05 rpm [fan], 08 rpm min, 09 rpm max, 0B perfil atual, 0C boost [fan]
//   0x15 controle:   01 ativa perfil [id], 02 boost [fan] [valor]
//   0x25 G-Mode:     01 alterna o "game shift", 02 estado
//   G-Mode completo (como o alienware-wmi com o quirk gmode dos "Dell G15"): game shift ligado + perfil 0xAB, que o
//   firmware nao anuncia na lista. Qualquer outro perfil: game shift desligado + o perfil.
//   0xFFFFFFFF / 0xFFFFFFFE = erro
//
// Interface (registro do macOS, classe G15Fan):
//   leitura:  propriedades "Fans" (ID, RPM, Min, Max, Boost), "Temps" (sensor -> C), "Profile", "Profiles", "GMode",
//             "SleepDebug" (contadores do SSDT de sono carregado: metodo \_SB.AMWW.GSLP)
// Sono (so com o acpi/opt/SSDT-RTXKEXT carregado, que cria \_SB.AMWW.GOFF/GONN). No Deep Idle o macOS nao roda nenhum
//   metodo ACPI de sono, entao o kext chama:
//   - GOFF (PG01._OFF: corta a energia da RTX) quando a ponte PCIe da RTX (IOPCIDevice do PEG1, interessado nela com
//     registerInterestedDriver) termina de ir para o estado 0 no sono: depois do NVRM parar a GPU e do GFX0. O aviso de
//     prioridade do sono chega ~90 s ANTES disso (trace point 0x12; logs/macos/ordem-sono-deepidle.txt), entao ele so
//     marca que o sistema vai dormir.
//   - GONN (PG01._ON: religa) no kIOMessageSystemWillPowerOn do aviso de prioridade, que vem antes do GFX0/NVRM
//     acordarem; e, de reserva, quando o PEG1 vai sair do estado 0.
//   Propriedade "SleepHooks": PEG1 achado, avisos recebidos e chamadas feitas (o IOLog do kext nao aparece no log).
//   Modo bateria (acpi/opt/SSDT-RTXBOOT: \_SB.AMWW.GBOF = 1, config uhd com a RTX escondida): GOFF ao iniciar e
//   nunca GONN (a RTX fica desligada a sessao inteira).
//   escrita:  IORegistryEntrySetCFProperties com {"Refresh": qualquer}, {"FanBoost": 0..100} (todas as ventoinhas),
//             {"Profile": id anunciado pelo firmware ou 0xAB = G-Mode}, {"GMode": bool} (desligar volta ao ultimo perfil). Escrita so do usuario da sessao grafica ou root.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <pexpert/pexpert.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <libkern/c++/OSArray.h>
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>

#define LOG(fmt, ...) IOLog("G15Fan: " fmt "\n", ##__VA_ARGS__)

class G15Fan : public IOService {
    OSDeclareDefaultStructors(G15Fan)

    IOACPIPlatformDevice *acpi {nullptr};
    IOLock *lock {nullptr};
    static constexpr int MAXRES = 16;
    uint8_t fans[MAXRES] {}, temps[MAXRES] {}, profiles[MAXRES] {};
    int nfans {0}, ntemps {0}, nprofiles {0};
    uint32_t fanMin[MAXRES] {}, fanMax[MAXRES] {};
    static constexpr uint8_t GMODE = 0xAB;
    uint8_t lastProfile {0};                          // ultimo perfil normal, para sair do G-Mode
    IONotifier *sleepNotifier {nullptr};              // sono do macOS (armar o EC; e a RTX com o SSDT-RTXKEXT)
    IONotifier *pciNotifier {nullptr};                // espera o IOPCIDevice do PEG1 aparecer
    IOService *peg1 {nullptr};                        // ponte PCIe da RTX (interessado no estado de energia dela)
    bool systemSleeping {false};                      // entre o aviso de sono e o de acordar
    bool rtxBootOff {false};                          // SSDT-RTXBOOT: RTX desligada desde o boot (modo bateria)
    uint32_t hk[6] {};                                // contadores: avisos sono/acordar, PEG1 ->0 / ->on, GOFF, GONN
    bool hasRtx {false};                              // SSDT-RTXKEXT presente (GOFF/GONN)
    uint32_t wk[4] {};                                // armar o EC: vezes ligado, desligado, ultimo resultado tampa/botao
    bool pepIn {false};                               // avisos de entrada no Modern Standby dados, falta a saida
    bool pepOff {false};                              // boot-arg -g15fan-pep-off
    uint32_t pep[8] {};                               // entradas, saidas, ultimo resultado das funcoes 3, 5, 6, 4

    static IOReturn sleepWake(void *target, void *ref, UInt32 msg, IOService *prov, void *arg, vm_size_t argSize);
    static bool pciPublished(void *target, void *ref, IOService *dev, IONotifier *n);
    void callRtx(const char *m, int counter);
    void armWake(UInt32 on);
    IOReturn pepDsm(UInt32 fn);
    void pepNotify(bool enter);
    void publishHooks();

    bool gameShift(bool on);
    bool activate(uint8_t p);

    bool wmax(uint8_t method, uint8_t op, uint8_t a1, uint8_t a2, uint32_t *out);
    bool enumerate();
    void refresh();

public:
    IOService *probe(IOService *provider, SInt32 *score) override;
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;
    IOReturn setProperties(OSObject *props) override;
    IOReturn powerStateDidChangeTo(IOPMPowerFlags caps, unsigned long state, IOService *who) override;
    IOReturn powerStateWillChangeTo(IOPMPowerFlags caps, unsigned long state, IOService *who) override;
};

OSDefineMetaClassAndStructors(G15Fan, IOService)

bool G15Fan::wmax(uint8_t method, uint8_t op, uint8_t a1, uint8_t a2, uint32_t *out) {
    uint8_t buf[4] = {op, a1, a2, 0};
    OSNumber *inst = OSNumber::withNumber(0ULL, 32), *mid = OSNumber::withNumber(method, 32);
    OSData *arg = OSData::withBytes(buf, sizeof buf);
    OSObject *params[3] = {inst, mid, arg}, *res = nullptr;
    IOReturn r = (inst && mid && arg) ? acpi->evaluateObject("WMAX", &res, params, 3) : kIOReturnNoMemory;
    OSSafeReleaseNULL(inst); OSSafeReleaseNULL(mid); OSSafeReleaseNULL(arg);
    OSNumber *n = OSDynamicCast(OSNumber, res);
    bool ok = r == kIOReturnSuccess && n;
    uint32_t v = ok ? n->unsigned32BitValue() : 0;
    OSSafeReleaseNULL(res);
    if (!ok || v == 0xFFFFFFFF || v == 0xFFFFFFFE) return false;
    if (out) *out = v;
    return true;
}

bool G15Fan::enumerate() {
    uint32_t d;
    if (!wmax(0x14, 0x02, 0, 0, &d)) return false;
    int nf = d & 0xFF, nt = (d >> 8) & 0xFF, nu = (d >> 16) & 0xFF, np = (d >> 24) & 0xFF;
    if (nf > MAXRES || nt > MAXRES || nu > MAXRES || np > MAXRES) { LOG("descricao invalida 0x%08x", d); return false; }
    uint32_t id;
    for (int i = 0; i < nf; i++) {
        if (!wmax(0x14, 0x03, (uint8_t)i, 0, &id)) return false;
        fans[nfans] = id & 0xFF;
        wmax(0x14, 0x08, fans[nfans], 0, &fanMin[nfans]);
        wmax(0x14, 0x09, fans[nfans], 0, &fanMax[nfans]);
        nfans++;
    }
    for (int i = 0; i < nt; i++) {
        if (!wmax(0x14, 0x03, (uint8_t)(nf + i), 0, &id)) return false;
        temps[ntemps++] = id & 0xFF;
    }
    for (int i = 0; i < np; i++) {                    // alguns firmwares anunciam perfis demais: para no 1o erro
        if (!wmax(0x14, 0x03, (uint8_t)(nf + nt + nu + i), 0, &id)) break;
        profiles[nprofiles++] = id & 0xFF;
    }
    LOG("%d ventoinhas, %d sensores, %d perfis", nfans, ntemps, nprofiles);
    return nfans > 0;
}

void G15Fan::refresh() {
    OSArray *fa = OSArray::withCapacity((unsigned)nfans);
    OSDictionary *td = OSDictionary::withCapacity((unsigned)ntemps);
    OSArray *pa = OSArray::withCapacity((unsigned)nprofiles);
    if (!fa || !td || !pa) { OSSafeReleaseNULL(fa); OSSafeReleaseNULL(td); OSSafeReleaseNULL(pa); return; }
    uint32_t v;
    for (int i = 0; i < nfans; i++) {
        OSDictionary *f = OSDictionary::withCapacity(5);
        if (!f) continue;
        auto put = [f](const char *k, uint32_t x) { OSNumber *n = OSNumber::withNumber(x, 32); if (n) { f->setObject(k, n); n->release(); } };
        put("ID", fans[i]); put("Min", fanMin[i]); put("Max", fanMax[i]);
        if (wmax(0x14, 0x05, fans[i], 0, &v)) put("RPM", v);
        if (wmax(0x14, 0x0C, fans[i], 0, &v)) put("Boost", v);
        fa->setObject(f); f->release();
    }
    for (int i = 0; i < ntemps; i++) {
        if (!wmax(0x14, 0x04, temps[i], 0, &v)) continue;
        char k[8]; snprintf(k, sizeof k, "0x%02x", temps[i]);
        OSNumber *n = OSNumber::withNumber(v, 32);
        if (n) { td->setObject(k, n); n->release(); }
    }
    for (int i = 0; i < nprofiles; i++) {
        OSNumber *n = OSNumber::withNumber(profiles[i], 32);
        if (n) { pa->setObject(n); n->release(); }
    }
    setProperty("Fans", fa); setProperty("Temps", td); setProperty("Profiles", pa);
    fa->release(); td->release(); pa->release();
    if (wmax(0x14, 0x0B, 0, 0, &v)) setProperty("Profile", v, 32);
    if (wmax(0x25, 0x02, 0, 0, &v)) setProperty("GMode", v != 0);
    UInt32 sd;                                         // SSDT-RTXOFF: PPS3/PPS0 do PEG1 rodaram? RTX desligada?
    if (acpi->evaluateInteger("GSLP", &sd) == kIOReturnSuccess) setProperty("SleepDebug", sd, 32);
}

void G15Fan::publishHooks() {                     // "SleepHooks" no ioreg (o IOLog do kext nao chega ao log)
    char b[160];
    snprintf(b, sizeof b, "peg1 %s; avisos sono %u acordar %u; PEG1 ->0 %u ->on %u; GOFF %u GONN %u%s",
             peg1 ? "ok" : "nao achado", hk[0], hk[1], hk[2], hk[3], hk[4], hk[5], rtxBootOff ? "; RTX desligada desde o boot" : "");
    setProperty("SleepHooks", b);
}

void G15Fan::callRtx(const char *m, int counter) {   // GOFF/GONN do SSDT-RTXKEXT
    UInt32 r = 0, sd = 0;
    IOLockLock(lock);
    IOReturn e = acpi->evaluateInteger(m, &r);
    acpi->evaluateInteger("GSLP", &sd);
    IOLockUnlock(lock);
    hk[counter]++;
    LOG("%s (0x%x) %s, SleepDebug 0x%08x", m, e, e == kIOReturnSuccess ? "ok" : "erro", sd);
    setProperty("SleepDebug", sd, 32); publishHooks();
}

// 09/11/2026: no Deep Idle o macOS nao chama o _PSW de ninguem, entao o EC nunca e "armado" e a tampa e o botao de
// ligar nao acordam (so o USB e o relogio). LID0._PSW(1) = EEAC(2,1) e PBTN._PSW(1) = EEAC(1,1) pedem ao EC para
// acionar o GPE 24 (o _PRW deles) nesses eventos, como num sono S3. Arma no aviso de sono, desarma ao acordar.
// 09/11: tentativa de ligar o GPE 24 direto no GPE0_EN (I/O 0x1870) REMOVIDA: a escrita nao pegava (lia 0 antes e
// depois) e regravava a palavra inteira (risco de apagar outros bits). O GPE 24 e o GPE de eventos do EC (_L18), que o
// macOS nao atende no Deep Idle; acordar pela tampa/botao exigiria o tratamento de EC no s2idle do Linux.
void G15Fan::armWake(UInt32 on) {
    // 09/11: o caminho absoluto a partir do AMWW volta 0xe00002c2 (BadArgument): chama o _PSW no proprio dispositivo
    // ACPI (IOACPIPlane:/_SB/LID0 e /_SB/PBTN).
    static const char *const devs[] = {"/_SB/LID0", "/_SB/PBTN"};
    IOReturn r[2] = {kIOReturnNotFound, kIOReturnNotFound};
    const IORegistryPlane *plane = IORegistryEntry::getPlane("IOACPIPlane");
    IOLockLock(lock);
    for (int i = 0; i < 2 && plane; i++) {
        IORegistryEntry *e = IORegistryEntry::fromPath(devs[i], plane);
        auto d = OSDynamicCast(IOACPIPlatformDevice, e);
        OSNumber *n = OSNumber::withNumber(on, 32);
        OSObject *params[1] = {n};
        if (d && n) r[i] = d->evaluateObject("_PSW", nullptr, params, 1);
        if (n) n->release();
        if (e) e->release();
    }
    IOLockUnlock(lock);
    wk[on ? 0 : 1]++; wk[2] = r[0]; wk[3] = r[1];
    setProperty("WakeArm", wk, sizeof wk);
    LOG("EC %s para acordar: tampa 0x%x botao 0x%x", on ? "armado" : "desarmado", r[0], r[1]);
}

// 09/11/2026: o log com acpi=0xC mostrou que o macOS JA arma o GPE 0x18 da tampa/botao no repouso
// ("LID0: GPE[18] type 1 can wake"), mas o EC nunca o aciona. No Modern Standby o Windows/Linux chamam o _DSM Intel do
// \_SB.PEPD: 3 (tela apagada) e 5 (entrada) ao dormir, 6 (saida) e 4 (tela acesa) ao acordar. A 5 faz EISC(0x81,0xB9,1)
// = avisa o EC do standby (com o XOSI, OIDE >= 1), mais GUAM(1), XHCI.PSLI(5), GPRV; a 4/6 desfazem. O macOS nao chama
// nada disso (o SSDT-PEPS0 de 25/10 usava o _PS3 do LPCB, que o macOS nao roda no Deep Idle). Aqui o kext chama.
IOReturn G15Fan::pepDsm(UInt32 fn) {
    static const uint8_t uuid[16] = {0xa0,0x40,0xeb,0xc4,0xd2,0x6c,0xe2,0x11,0xbc,0xfd,0x08,0x00,0x20,0x0c,0x9a,0x66};
    const IORegistryPlane *plane = IORegistryEntry::getPlane("IOACPIPlane");
    IORegistryEntry *e = plane ? IORegistryEntry::fromPath("/_SB/PEPD", plane) : nullptr;
    auto d = OSDynamicCast(IOACPIPlatformDevice, e);
    OSData *u = OSData::withBytes(uuid, sizeof uuid);
    OSNumber *rev = OSNumber::withNumber(0ULL, 32), *f = OSNumber::withNumber(fn, 32);
    OSArray *pkg = OSArray::withCapacity(1);
    IOReturn r = kIOReturnNotFound;
    if (d && u && rev && f && pkg) {
        OSObject *params[4] = {u, rev, f, pkg};
        OSObject *res = nullptr;
        r = d->evaluateObject("_DSM", &res, params, 4);
        if (res) res->release();
    }
    if (u) u->release(); if (rev) rev->release(); if (f) f->release(); if (pkg) pkg->release();
    if (e) e->release();
    return r;
}

void G15Fan::pepNotify(bool enter) {
    if (pepOff || enter == pepIn) return;
    IOLockLock(lock);
    if (enter) { pep[2] = pepDsm(3); pep[3] = pepDsm(5); pep[0]++; }
    else       { pep[4] = pepDsm(6); pep[5] = pepDsm(4); pep[1]++; }
    IOLockUnlock(lock);
    pepIn = enter;
    setProperty("PepDsm", pep, sizeof pep);
    LOG("Modern Standby %s: 0x%x 0x%x", enter ? "entrada (3,5)" : "saida (6,4)", pep[enter ? 2 : 4], pep[enter ? 3 : 5]);
}

IOReturn G15Fan::sleepWake(void *target, void *, UInt32 msg, IOService *, void *, vm_size_t) {
    auto self = static_cast<G15Fan *>(target);
    if (msg == kIOMessageSystemWillSleep) {          // ~90 s antes dos drivers: so marca
        self->systemSleeping = true; self->hk[0]++; self->publishHooks();
        self->armWake(1);
        self->pepNotify(true);
    } else if (msg == kIOMessageSystemWillPowerOn) { // antes do GFX0/NVRM acordarem: religa a RTX
        self->hk[1]++;
        if (self->hasRtx && !self->rtxBootOff) self->callRtx("GONN", 5);
        self->systemSleeping = false;
        self->pepNotify(false);
        self->armWake(0);
    } else if (msg == kIOMessageSystemWillNotSleep) { // sono cancelado
        self->systemSleeping = false;
        self->pepNotify(false);
    }
    return kIOReturnSuccess;
}

IOReturn G15Fan::powerStateDidChangeTo(IOPMPowerFlags, unsigned long state, IOService *who) {
    if (who == peg1 && state == 0 && systemSleeping) {   // PEG1 desligado no sono: o NVRM ja parou a RTX
        hk[2]++;
        callRtx("GOFF", 4);
    }
    return IOPMAckImplied;
}

IOReturn G15Fan::powerStateWillChangeTo(IOPMPowerFlags, unsigned long state, IOService *who) {
    if (who == peg1 && state > 0) {                   // PEG1 vai ligar: reserva do GONN (nao faz nada se ja ligada)
        hk[3]++;
        UInt32 sd = 0;
        if (!rtxBootOff && acpi->evaluateInteger("GSLP", &sd) == kIOReturnSuccess && (sd & 0x10000)) callRtx("GONN", 5);
        else publishHooks();
    }
    return IOPMAckImplied;
}

bool G15Fan::pciPublished(void *target, void *, IOService *dev, IONotifier *) {
    auto self = static_cast<G15Fan *>(target);
    auto path = OSDynamicCast(OSString, dev->getProperty("acpi-path"));
    if (self->peg1 || !path) return true;
    const char *c = path->getCStringNoCopy(), *k = "/PEG1@";   // acpi-path ".../_SB/PC00/PEG1@10000"
    bool found = false;
    for (unsigned i = 0; !found && i + 6 <= path->getLength(); i++) found = !strncmp(c + i, k, 6);
    if (!found) return true;
    self->peg1 = dev; dev->retain();
    IOPMPowerFlags f = dev->registerInterestedDriver(self);
    LOG("PEG1 %s: interessado no estado de energia (flags 0x%lx)", path->getCStringNoCopy(), (unsigned long)f);
    self->publishHooks();
    return true;
}


bool G15Fan::gameShift(bool on) {                    // mesma ordem do alienware-wmi: le, alterna so se precisar
    uint32_t s;
    if (!wmax(0x25, 0x02, 0, 0, &s)) return false;
    return (s != 0) == on || wmax(0x25, 0x01, 0, 0, nullptr);
}

bool G15Fan::activate(uint8_t p) {
    bool ok = gameShift(p == GMODE) && wmax(0x15, 0x01, p, 0, nullptr);
    if (ok && p != GMODE) lastProfile = p;
    LOG("perfil 0x%02x%s (%s)", p, p == GMODE ? " = G-Mode" : "", ok ? "ok" : "erro");
    return ok;
}

IOService *G15Fan::probe(IOService *provider, SInt32 *score) {
    auto dev = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!dev || dev->validateObject("WMAX") != kIOReturnSuccess) return nullptr;   // so o AMWW tem WMAX
    return IOService::probe(provider, score);
}

bool G15Fan::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    acpi = OSDynamicCast(IOACPIPlatformDevice, provider);
    lock = IOLockAlloc();
    if (!acpi || !lock) return false;
    acpi->retain();
    IOLockLock(lock);
    bool ok = enumerate();
    uint32_t cur;
    if (ok && wmax(0x14, 0x0B, 0, 0, &cur) && (cur & 0xFF) != GMODE) lastProfile = cur & 0xFF;
    if (ok) refresh();
    IOLockUnlock(lock);
    if (!ok) { LOG("WMAX nao respondeu a descricao do sistema"); return false; }
    registerService();
    { char b[4]; pepOff = PE_parse_boot_argn("-g15fan-pep-off", b, sizeof b); }   // sem os avisos de Modern Standby
    sleepNotifier = registerPrioritySleepWakeInterest(sleepWake, this);   // sempre (armar o EC); a RTX so com o SSDT
    if (acpi->validateObject("GOFF") == kIOReturnSuccess && acpi->validateObject("GONN") == kIOReturnSuccess) {
        hasRtx = true;
        OSDictionary *m = serviceMatching("IOPCIDevice");
        if (m) { pciNotifier = addMatchingNotification(gIOFirstPublishNotification, m, pciPublished, this); m->release(); }
        LOG("SSDT-RTXKEXT: RTX desligada no sono %s", sleepNotifier && pciNotifier ? "ativo" : "(registro falhou)");
        UInt32 bo = 0;
        if (acpi->evaluateInteger("GBOF", &bo) == kIOReturnSuccess && bo) {   // modo bateria: RTX desligada ja
            rtxBootOff = true;
            callRtx("GOFF", 4);
        }
        publishHooks();
    }
    return true;
}

void G15Fan::stop(IOService *provider) {
    if (sleepNotifier) { sleepNotifier->remove(); sleepNotifier = nullptr; }
    if (pciNotifier) { pciNotifier->remove(); pciNotifier = nullptr; }
    if (peg1) { peg1->deRegisterInterestedDriver(this); OSSafeReleaseNULL(peg1); }
    OSSafeReleaseNULL(acpi);
    IOService::stop(provider);
}

void G15Fan::free() {
    if (lock) { IOLockFree(lock); lock = nullptr; }
    IOService::free();
}

IOReturn G15Fan::setProperties(OSObject *props) {
    auto d = OSDynamicCast(OSDictionary, props);
    if (!d) return kIOReturnBadArgument;
    bool write = d->getObject("FanBoost") || d->getObject("Profile") || d->getObject("GMode");
    // escrita: usuario da sessao grafica (o agente g15kbd) ou root. kIOClientPrivilegeAdministrator sozinho so aceita root.
    if (write && IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeLocalUser) != kIOReturnSuccess &&
        IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return kIOReturnNotPrivileged;
    IOReturn ret = kIOReturnSuccess;
    IOLockLock(lock);
    if (auto n = OSDynamicCast(OSNumber, d->getObject("FanBoost"))) {
        uint32_t v = n->unsigned32BitValue();
        if (v > 100) ret = kIOReturnBadArgument;
        else for (int i = 0; i < nfans; i++)
            if (!wmax(0x15, 0x02, fans[i], (uint8_t)v, nullptr)) ret = kIOReturnError;
        LOG("boost %u%% (%s)", v, ret == kIOReturnSuccess ? "ok" : "erro");
    }
    if (auto n = OSDynamicCast(OSNumber, d->getObject("Profile"))) {
        uint32_t p = n->unsigned32BitValue(); bool known = p == GMODE;
        for (int i = 0; i < nprofiles; i++) known |= profiles[i] == p;
        if (!known) { LOG("perfil 0x%02x nao anunciado", p); ret = kIOReturnBadArgument; }
        else if (!activate((uint8_t)p)) ret = kIOReturnError;
    }
    if (auto b = OSDynamicCast(OSBoolean, d->getObject("GMode"))) {
        uint8_t back = lastProfile ? lastProfile : (nprofiles ? profiles[0] : 0);
        if (!activate(b->isTrue() ? GMODE : back)) ret = kIOReturnError;
    }
    refresh();                                         // tambem atende {"Refresh": ...}
    IOLockUnlock(lock);
    return ret;
}
