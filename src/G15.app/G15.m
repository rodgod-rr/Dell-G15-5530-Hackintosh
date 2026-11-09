// G15.app: teclas Fn do Dell G15 5530 no macOS, com icone na barra de menus. Faz o mesmo que o Linux:
//  - Fn+F5 (F18 para o VoodooPS2: scancode PS/2 0x69 -> ADB 0x4f): luz do teclado apagada -> 50% -> 100%, com uma
//    barrinha na tela (como a do KDE). Controlador Alienware AW-ELC 187c:0551, relatorio de saida de 33 bytes sem
//    report ID: 03 26 <dim> 00 04 00 01 02 03 00...  dim = 100 - brilho% (linux/g15-kbd, tools/test-kbd-backlight.py).
//    O nivel e reaplicado ao iniciar, ao acordar e quando o controlador reaparece.
//  - Fn+F9 (F17: scancode 0x68 -> ADB 0x40): passa pelos perfis Bateria -> Silencioso -> Balanceado -> Performance ->
//    G-Mode -> Bateria, com a barrinha na tela (como o g15-kbd-sync no Linux). O boost das ventoinhas fica no menu.
//  - Carregador: ao desconectar vai para Bateria, ao conectar para Balanceado (como o g15-power no Linux); ao abrir no
//    login ja na bateria, vai para Bateria.
//  - Fn+F10 (PrtSc; F13 para o VoodooPS2): captura da tela inteira, como Cmd+Shift+3.
//  - EPP do processador por perfil (kext G15PM, servico G15PMControl, so com -g15pm): Bateria/Silencioso 192
//    (economia), Balanceado 128, Performance/G-Mode 0 (desempenho). Medido: EPP 0 gasta ~4 W a mais parado.
//    Ao iniciar, boost do perfil atual (ou "fanDefault" se definido; -1 = nao mexe); a cada
//    5 s, CPU ou GPU >= 93 C forca 100% e abaixo de 90 C volta ao boost de antes. Trocar de perfil no menu grava o
//    boost do perfil: Bateria 10, Silencioso 25, Balanceado 50, Performance 75, G-Mode 100 (como o g15-power). Ventoinhas, temperaturas, perfil e G-Mode vem do
//    kexts/G15Fan (metodo ACPI WMAX), lidos e gravados pelas propriedades do servico G15Fan no registro.
//  - Menu: temperaturas, RPM, nivel das ventoinhas, luz do teclado, perfil termico (com o G-Mode = perfil 0xAB +
//    game shift, como o "performance" do alienware-wmi no Linux), log.
//  - Sono: ao dormir, ventoinhas em Automatico e luz do teclado apagada (o EC e o AW-ELC continuam ligados no Deep
//    Idle); ao acordar, volta o boost e a luz de antes (IORegisterForSystemPower).
//  - Tampa: desde 09/11/2026 o proprio macOS dorme ao fechar a tampa; o app so registra abrir/fechar (a antiga acao
//    "lidAction" Repouso/Apagar a tela/Nada foi removida). Com monitor externo
//    nao faz nada. Aviso kIOPMMessageClamshellStateChange do IOPMrootDomain, e AppleClamshellState no tick de reserva.
//  - Permissoes de microfone/camera: com o AMFI desligado (necessario para o Metal da UHD e do NullMoth) o tccd nunca
//    mostra o pedido a apps de terceiros ("CS_PLATFORM_BINARY set but not AppleSigned; prompt policy is Deny"). O G15
//    acompanha o log do tccd ("Policy disallows prompt for Sub:{<bundle id>} ... access to kTCCServiceMicrophone denied"),
//    mostra o proprio pedido ("WhatsApp quer acessar o microfone") e, se o usuario permitir, grava no TCC.db do usuario
//    (como tools/macos-permitir-app.sh) e reinicia o tccd. Nunca permite sozinho; "Nao permitir" fica guardado (prefs
//    "tccDecisions") e o menu tem "Esquecer respostas". Testado na VM com AMFI desligado (tools/macos-tcc-teste).
// Teclas: RegisterEventHotKey (nao pede permissao); se falhar ou com G15KBD_TAP=1, event tap que consome F17/F18
// (pede Acessibilidade). Preferencias: "defaults read local.g15".
// Uso:  G15.app/Contents/MacOS/G15            (app; o LaunchAgent local.g15 passa --daemon)
//       G15.app/Contents/MacOS/G15 0..100     (so a luz do teclado, uma vez, e sai)
//       G15 --estado | --perfil <id em hex, ex. 0xa0, ou 0xab = G-Mode> | --boost <0..100>   (ventoinhas, e sai)
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <IOKit/IOMessage.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <UserNotifications/UserNotifications.h>

static NSUserDefaults *prefs;

// textos: portugues se o idioma do sistema for portugues, ingles nos outros
static BOOL PT;
#define L(pt, en) (PT ? @pt : @en)

// ---------- avisos ----------
static BOOL notifyOK;                              // permissao de notificacao do app; sem ela usa o osascript

static void notify(NSString *title, NSString *body) {
    if (notifyOK) {
        UNMutableNotificationContent *c = [UNMutableNotificationContent new];
        c.title = title; c.body = body;
        UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:@"g15" content:c trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:r withCompletionHandler:nil];
        return;
    }
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    t.arguments = @[@"-e", [NSString stringWithFormat:@"display notification \"%@\" with title \"%@\"", body, title]];
    [t launchAndReturnError:nil];
}

// barrinha na tela (luz do teclado), some sozinha
static NSPanel *hud; static NSImageView *hudIcon; static NSTextField *hudText; static NSLevelIndicator *hudBar;
static NSUInteger hudGen;

static void showHUD(NSString *symbol, NSString *text, double pct) {
    if (!hud) {
        hud = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 250, 64)
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered defer:NO];
        hud.level = NSStatusWindowLevel; hud.opaque = NO; hud.backgroundColor = NSColor.clearColor;
        hud.ignoresMouseEvents = YES; hud.hasShadow = YES; hud.releasedWhenClosed = NO;
        hud.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 250, 64)];
        v.material = NSVisualEffectMaterialHUDWindow; v.state = NSVisualEffectStateActive;
        v.wantsLayer = YES; v.layer.cornerRadius = 18; v.layer.masksToBounds = YES;
        hud.contentView = v;
        hudIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 14, 36, 36)];
        hudIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:26 weight:NSFontWeightRegular];
        hudText = [NSTextField labelWithString:@""];
        hudText.frame = NSMakeRect(64, 34, 170, 18); hudText.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        hudBar = [[NSLevelIndicator alloc] initWithFrame:NSMakeRect(64, 16, 166, 10)];
        hudBar.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
        hudBar.minValue = 0; hudBar.maxValue = 100;
        hudBar.warningValue = 101; hudBar.criticalValue = 101;
        [v addSubview:hudIcon]; [v addSubview:hudText]; [v addSubview:hudBar];
    }
    hudIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]
                    ?: [NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:nil];
    hudText.stringValue = text; hudBar.doubleValue = pct;
    NSRect s = NSScreen.mainScreen.visibleFrame;
    [hud setFrameOrigin:NSMakePoint(NSMidX(s) - 125, NSMaxY(s) - 64 - 16)];
    hud.alphaValue = 1; [hud orderFrontRegardless];
    NSUInteger gen = ++hudGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != hudGen) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.3; hud.animator.alphaValue = 0; }
                            completionHandler:^{ if (gen == hudGen) [hud orderOut:nil]; }];
    });
}

// ---------- luz do teclado ----------
static IOHIDManagerRef mgr;
static NSInteger kbLevel = 2;                      // 0, 1, 2
static const int KB_PCT[3] = {0, 50, 100};

static void kbSend(int pct) {
    CFSetRef devs = IOHIDManagerCopyDevices(mgr);
    CFIndex n = devs ? CFSetGetCount(devs) : 0;
    if (!n) { NSLog(@"AW-ELC 187c:0551 nao encontrado"); if (devs) CFRelease(devs); return; }
    const void *vals[n]; CFSetGetValues(devs, vals);
    uint8_t r[33] = {0x03, 0x26, (uint8_t)(100 - pct), 0x00, 0x04, 0x00, 0x01, 0x02, 0x03};
    for (CFIndex i = 0; i < n; i++) {
        IOReturn e = IOHIDDeviceSetReport((IOHIDDeviceRef)vals[i], kIOHIDReportTypeOutput, 0, r, sizeof r);
        if (e == kIOReturnSuccess) NSLog(@"brilho %d%%", pct);
        else NSLog(@"erro 0x%08x ao mandar brilho %d%%", e, pct);
    }
    CFRelease(devs);
}

static void kbApply(void) { kbSend(KB_PCT[kbLevel]); }

static void kbApplySoon(double s) {                // o controlador pode demorar a aceitar comandos ao conectar/acordar
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ kbApply(); });
}

static void kbDeviceAdded(void *ctx, IOReturn res, void *sender, IOHIDDeviceRef dev) {
    NSLog(@"AW-ELC conectado"); kbApplySoon(0.5);
}

static void kbOpen(void) {
    mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)@{@kIOHIDVendorIDKey: @0x187c, @kIOHIDProductIDKey: @0x0551});
    IOReturn e = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    if (e != kIOReturnSuccess) NSLog(@"IOHIDManagerOpen: 0x%08x", e);
}

static void kbSet(NSInteger lv, BOOL showOnScreen) {
    kbLevel = lv;
    [prefs setInteger:kbLevel forKey:@"level"];
    kbApply();
    if (showOnScreen)
        showHUD(kbLevel ? @"light.max" : @"light.min", kbLevel ? [NSString stringWithFormat:L("Luz do teclado: %d%%", "Keyboard light: %d%%"), KB_PCT[kbLevel]]
                                                               : L("Luz do teclado: apagada", "Keyboard light: off"), KB_PCT[kbLevel]);
}

static void kbStep(const char *via) {
    NSLog(@"Fn+F5 (%s): nivel %ld", via, (long)((kbLevel + 1) % 3));
    kbSet((kbLevel + 1) % 3, YES);
}

// ---------- ventoinhas (G15Fan.kext) ----------
static const int HOT = 93, COOL = 90;              // C: forca 100% / volta ao boost de antes
static int hotFrom = -1;                           // boost de antes da protecao (-1 = protecao desligada)

static NSDictionary *fanState(BOOL refresh) {
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15Fan"));
    if (!sv) return nil;
    if (refresh) IORegistryEntrySetCFProperties(sv, (__bridge CFDictionaryRef)@{@"Refresh": @YES});
    CFMutableDictionaryRef p = NULL;
    IORegistryEntryCreateCFProperties(sv, &p, kCFAllocatorDefault, 0);
    IOObjectRelease(sv);
    return CFBridgingRelease(p);
}

static kern_return_t fanWrite(NSDictionary *d) {
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15Fan"));
    if (!sv) { NSLog(@"G15Fan.kext nao carregado"); return kIOReturnNotFound; }
    kern_return_t r = IORegistryEntrySetCFProperties(sv, (__bridge CFDictionaryRef)d);
    IOObjectRelease(sv);
    if (r == KERN_SUCCESS) NSLog(@"G15Fan: %@ ok", d);
    else NSLog(@"G15Fan: erro 0x%08x ao gravar %@", r, d);
    return r;
}

static BOOL setBoost(int v) { return fanWrite(@{@"FanBoost": @(v)}) == KERN_SUCCESS; }
static int fanBoost(NSDictionary *st) { NSNumber *b = [st[@"Fans"] firstObject][@"Boost"]; return b ? b.intValue : -1; }
static int fanTemp(NSDictionary *st, NSString *sensor) { NSNumber *t = st[@"Temps"][sensor]; return t ? t.intValue : -1; }

static NSString *boostName(int b) { return b ? [NSString stringWithFormat:@"%d%%", b] : L("Automático", "Auto"); }

// nomes como no Alienware Command Center do Windows
static NSString *profileName(int p) {
    switch (p) {
        case 0xA5: return L("Bateria", "Battery Saver");
        case 0x96: case 0xA3: return L("Silencioso", "Silent");
        case 0x97: case 0xA0: return L("Balanceado", "Balanced");
        case 0x98: case 0xA1: case 0x99: case 0xA4: return @"Performance";
        case 0xA2: return L("Frio", "Cool");
        case 0xAB: return @"G-Mode";
        default:   return [NSString stringWithFormat:L("Perfil 0x%02x", "Profile 0x%02x"), p];
    }
}

static int profileRank(int p) {                    // ordem do menu: Bateria, Silencioso, Balanceado, Performance, G-Mode
    switch (p) {
        case 0xA5: return 0; case 0x96: case 0xA3: return 1; case 0xA2: return 2; case 0x97: case 0xA0: return 3;
        case 0x98: case 0xA1: return 4; case 0x99: case 0xA4: return 5; case 0xAB: return 7; default: return 6;
    }
}

// boost das ventoinhas ao escolher um perfil (o mesmo do g15-power no Linux)
static int profileFanBoost(int p) {
    switch (profileRank(p)) {
        case 0: return 10; case 1: case 2: return 25; case 4: case 5: return 75; case 7: return 100; default: return 50;
    }
}

// RTX (NullMoth): estado e temperatura pelo NVAccel (PerformanceStatistics). 0 = desligada/ausente (sem NVAccel),
// 1 = ociosa, 2 = em uso (utilizacao >= 5%). Sem o driver, a temperatura vem do sensor 0x06 do EC (G15Fan).
typedef struct { int state, temp, util; } RtxInfo;
static RtxInfo rtxInfo(NSDictionary *st) {
    RtxInfo r = {0, -1, 0};
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (sv) {
        NSDictionary *ps = CFBridgingRelease(IORegistryEntryCreateCFProperty(sv, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0));
        IOObjectRelease(sv);
        if ([ps isKindOfClass:NSDictionary.class]) {
            NSNumber *t = ps[@"Temperature(C)"], *u = ps[@"Device Utilization %"];
            r.temp = t ? t.intValue : -1; r.util = u ? u.intValue : 0;
            r.state = r.util >= 5 ? 2 : 1;
        }
    }
    if (r.temp < 0 && st) r.temp = fanTemp(st, @"0x06");
    return r;
}
static NSString *rtxStateName(int s) {
    return s == 2 ? L("em uso", "busy") : s == 1 ? L("ociosa", "idle") : L("desligada", "off");
}

static NSString *tempsText(NSDictionary *st) {
    RtxInfo r = rtxInfo(st);
    return [NSString stringWithFormat:@"CPU %d° · RTX %d° (%@)", fanTemp(st, @"0x01"), r.temp, rtxStateName(r.state)];
}

// ---------- sono e tampa ----------
static BOOL asleep;                                // entre "vai dormir" e "acordou": o tick nao mexe nas ventoinhas
static int sleepBoost = -1;                        // boost de antes de dormir
static io_connect_t pmRoot;

static void run(NSString *tool, NSArray *args) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:tool]; t.arguments = args;
    NSError *e; if (![t launchAndReturnError:&e]) NSLog(@"%@ %@: %@", tool, args, e.localizedDescription);
}

static void sleepPrep(void) {                      // ventoinhas em Automatico e luz apagada enquanto dorme
    asleep = YES;
    NSDictionary *st = fanState(NO);
    sleepBoost = hotFrom >= 0 ? hotFrom : (st ? fanBoost(st) : -1);
    hotFrom = -1;
    NSLog(@"vai dormir: boost %d%% -> Automatico, luz apagada", sleepBoost);
    if (sleepBoost > 0) setBoost(0);
    kbSend(0);
}

static void wakeRestore(void) {
    if (!asleep) return;
    asleep = NO;
    NSLog(@"acordou: boost de volta a %d%%, luz nivel %ld", sleepBoost, (long)kbLevel);
    if (sleepBoost > 0) setBoost(sleepBoost);
    sleepBoost = -1;
    kbApplySoon(1.0);
}

static void powerCallback(void *ref, io_service_t s, natural_t msg, void *arg) {
    switch (msg) {
        case kIOMessageCanSystemSleep: IOAllowPowerChange(pmRoot, (intptr_t)arg); break;
        case kIOMessageSystemWillSleep: sleepPrep(); IOAllowPowerChange(pmRoot, (intptr_t)arg); break;
        case kIOMessageSystemWillNotSleep:
        case kIOMessageSystemHasPoweredOn: wakeRestore(); break;
    }
}

static int lidClosed = -1;                         // ultimo estado visto (-1 = ainda nao lido)

static int readLid(void) {
    io_service_t r = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!r) return -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(r, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(r);
    int c = (v && CFGetTypeID(v) == CFBooleanGetTypeID()) ? CFBooleanGetValue((CFBooleanRef)v) : -1;
    if (v) CFRelease(v);
    return c;
}


static void lidEvent(int closed, const char *via) {
    if (closed < 0 || closed == lidClosed) return;
    BOOL first = lidClosed < 0; lidClosed = closed;
    if (first) return;                             // estado inicial, nao e um evento
    // 09/11/2026: com o repouso funcionando, o proprio macOS dorme ao fechar a tampa (AppleClamshellCausesSleep = Yes);
    // a acao da tampa do G15.app (Repouso/Apagar a tela/Nada) foi removida. So registra.
    NSLog(@"tampa %s (%s), telas %lu", closed ? "fechada" : "aberta", via, (unsigned long)NSScreen.screens.count);
}

static void lidCallback(void *ref, io_service_t s, natural_t msg, void *arg) {
    if (msg != kIOPMMessageClamshellStateChange) return;
    int closed = ((uintptr_t)arg & kClamshellStateBit) ? 1 : 0;
    dispatch_async(dispatch_get_main_queue(), ^{ lidEvent(closed, "aviso"); });
}

static void powerOpen(void) {
    IONotificationPortRef port; io_object_t n;
    pmRoot = IORegisterForSystemPower(NULL, &port, powerCallback, &n);
    if (pmRoot) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
    else NSLog(@"IORegisterForSystemPower falhou: sem ajuste de ventoinhas/luz no sono");
    IONotificationPortRef lp = IONotificationPortCreate(kIOMainPortDefault);
    io_service_t r = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    io_object_t ln;
    if (r && IOServiceAddInterestNotification(lp, r, kIOGeneralInterest, lidCallback, NULL, &ln) == KERN_SUCCESS)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(lp), kCFRunLoopCommonModes);
    else NSLog(@"sem aviso da tampa do IOPMrootDomain: so o tick de 5 s");
    if (r) IOObjectRelease(r);
    lidEvent(readLid(), "inicio");
}

// perfis na ordem do menu e do Fn+F9 (os que o firmware anuncia + G-Mode = game shift + perfil 0xAB)
static NSArray<NSNumber *> *profileRing(NSDictionary *st) {
    return [[st[@"Profiles"] arrayByAddingObject:@0xAB] sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [@(profileRank(a.intValue)) compare:@(profileRank(b.intValue))]; }];
}

static NSString *profileSymbol(int p) {
    switch (profileRank(p)) {
        case 0: return @"battery.25"; case 1: case 2: return @"leaf"; case 4: case 5: return @"bolt"; case 7: return @"flame";
        default: return @"gauge.with.dots.needle.50percent";
    }
}

// EPP (preferencia de energia do processador) por perfil, pelo G15PMControl do kext G15PM
static int profileEpp(int p) {
    switch (profileRank(p)) {
        case 0: case 1: case 2: return 192; case 4: case 5: case 7: return 0; default: return 128;
    }
}

static void setEpp(int e) {
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15PMControl"));
    if (!sv) return;                               // sem o G15PM: nada a fazer
    kern_return_t r = IORegistryEntrySetCFProperties(sv, (__bridge CFDictionaryRef)@{@"EPP": @(e)});
    IOObjectRelease(sv);
    NSLog(@"G15PM: EPP %d %@", e, r == KERN_SUCCESS ? @"ok" : [NSString stringWithFormat:@"erro 0x%08x", r]);
}

static BOOL applyProfile(int p) {                  // perfil + boost das ventoinhas + EPP do perfil
    if (fanWrite(@{@"Profile": @(p)}) != KERN_SUCCESS) return NO;
    if (hotFrom >= 0) hotFrom = profileFanBoost(p);   // quente: aplica quando esfriar
    else setBoost(profileFanBoost(p));
    setEpp(profileEpp(p));
    return YES;
}

static void profileStep(void) {                    // Fn+F9: proximo perfil
    NSDictionary *st = fanState(YES);
    if (!st) { NSLog(@"Fn+F9: G15Fan.kext nao carregado"); notify(L("Perfil", "Profile"), L("G15Fan.kext não carregado", "G15Fan.kext not loaded")); return; }
    NSArray<NSNumber *> *ring = profileRing(st);
    int cur = [st[@"Profile"] intValue];
    NSUInteger i = [ring indexOfObject:@(cur)];
    int next = ring[i == NSNotFound ? 0 : (i + 1) % ring.count].intValue;
    NSLog(@"Fn+F9: perfil 0x%02x -> 0x%02x", cur, next);
    if (!applyProfile(next)) { notify(L("Perfil", "Profile"), L("Erro ao trocar o perfil", "Could not change the profile")); return; }
    NSUInteger k = [ring indexOfObject:@(next)];
    showHUD(profileSymbol(next), [L("Perfil: ", "Profile: ") stringByAppendingString:profileName(next)],
            100.0 * (k + 1) / ring.count);
}

// carregador: desconectado -> Bateria (0xA5), conectado -> Balanceado (0xA0); ao abrir (login) ja na bateria -> Bateria
static int acLast = -1;
static int onAC(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFStringRef src = IOPSGetProvidingPowerSourceType(info);
    int ac = src ? CFStringCompare(src, CFSTR(kIOPMACPowerKey), 0) == kCFCompareEqualTo : -1;
    CFRelease(info);
    return ac;
}

static void acChanged(void *ctx) {
    int ac = onAC();
    if (ac < 0 || ac == acLast) return;
    BOOL first = acLast < 0; acLast = ac;
    if (first && ac) return;                       // abriu na tomada: mantem o perfil; abriu na bateria: vai para Bateria
    int p = ac ? 0xA0 : 0xA5;
    NSLog(@"carregador %s: perfil 0x%02x", ac ? "conectado" : "desconectado", p);
    NSDictionary *st = fanState(NO);
    if (!st || [st[@"Profile"] intValue] == p || ![profileRing(st) containsObject:@(p)]) return;
    if (applyProfile(p)) showHUD(profileSymbol(p), [L("Perfil: ", "Profile: ") stringByAppendingString:profileName(p)], 0);
}

static void acOpen(void) {
    acChanged(NULL);                               // estado inicial
    CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(acChanged, NULL);
    if (src) CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
    else NSLog(@"sem aviso do carregador (IOPSNotificationCreateRunLoopSource)");
}

// ---------- barra de menus ----------
// ---------- permissoes de microfone/camera (tccd com o AMFI desligado) ----------
static NSTask *tccLog;
static NSMutableString *tccBuf;
static NSMutableDictionary<NSString *, NSDate *> *tccSeen;   // chave "bundle|servico" -> ultima vez (o tccd repete a linha)
static BOOL tccAsking;

static NSString *tccServiceName(NSString *s) {
    return [s isEqualToString:@"kTCCServiceCamera"] ? L("a câmera", "the camera") : L("o microfone", "the microphone");
}

static NSString *tccAppName(NSString *bid) {
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bid];
    NSString *n = u ? [[NSFileManager defaultManager] displayNameAtPath:u.path] : nil;
    return n.length ? [n stringByReplacingOccurrencesOfString:@".app" withString:@""] : bid;
}

// grava a permissao no TCC.db do usuario (auth_value 2 = permitido, auth_reason 3 = usuario, csreq NULL) e reinicia o tccd
static BOOL tccGrant(NSString *bid, NSString *svc, NSString **err) {
    NSString *db = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/com.apple.TCC/TCC.db"];
    NSString *sql = [NSString stringWithFormat:@"insert or replace into access (service, client, client_type, auth_value, auth_reason, "
                     "auth_version, flags, last_modified) values ('%@', '%@', 0, 2, 3, 1, 0, cast(strftime('%%s','now') as integer));", svc, bid];
    NSTask *t = [NSTask new]; NSPipe *e = [NSPipe pipe];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sqlite3"];
    t.arguments = @[db, sql]; t.standardError = e;
    if (![t launchAndReturnError:nil]) { *err = @"sqlite3"; return NO; }
    [t waitUntilExit];
    if (t.terminationStatus) {
        *err = [[NSString alloc] initWithData:[e.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        return NO;
    }
    run(@"/usr/bin/killall", @[@"tccd"]);           // o tccd do usuario volta sozinho e relê o banco
    return YES;
}

static void tccAsk(NSString *bid, NSString *svc) {
    NSString *key = [NSString stringWithFormat:@"%@|%@", bid, svc];
    NSDictionary *dec = [prefs dictionaryForKey:@"tccDecisions"];
    if (dec[key] || tccAsking) return;
    NSDate *last = tccSeen[key];
    if (last && -last.timeIntervalSinceNow < 30) return;
    tccSeen[key] = NSDate.date;
    tccAsking = YES;
    NSString *app = tccAppName(bid);
    NSLog(@"tccd negou o pedido de %@ para %@ (%@): perguntando", svc, app, bid);
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L("“%@” quer acessar %@.", "“%@” wants to access %@."), app, tccServiceName(svc)];
    a.informativeText = L("Neste hackintosh o macOS não consegue mostrar este pedido (AMFI desligado). O G15 grava a permissão por você. "
                          "Depois de permitir, feche e abra o app.",
                          "On this hackintosh macOS cannot show this request (AMFI off). G15 stores the permission for you. "
                          "After allowing, quit and reopen the app.");
    [a addButtonWithTitle:L("Permitir", "Allow")];
    [a addButtonWithTitle:L("Não permitir", "Don't Allow")];
    [NSApp activateIgnoringOtherApps:YES];
    BOOL ok = [a runModal] == NSAlertFirstButtonReturn;
    tccAsking = NO;
    NSMutableDictionary *d = [dec mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!ok) {
        d[key] = @"negado"; [prefs setObject:d forKey:@"tccDecisions"];
        NSLog(@"permissao de %@ para %@: negada pelo usuario", svc, bid);
        return;
    }
    NSString *err = nil;
    if (tccGrant(bid, svc, &err)) {
        d[key] = @"permitido"; [prefs setObject:d forKey:@"tccDecisions"];
        NSLog(@"permissao de %@ para %@: gravada no TCC.db", svc, bid);
        notify(app, [NSString stringWithFormat:L("Acesso a %@ permitido. Feche e abra o app.", "Access to %@ allowed. Quit and reopen the app."), tccServiceName(svc)]);
    } else {
        NSLog(@"permissao de %@ para %@: falhou (%@)", svc, bid, err);
        NSAlert *f = [NSAlert new];
        f.messageText = L("Não consegui gravar a permissão.", "Could not store the permission.");
        f.informativeText = [NSString stringWithFormat:L("Dê ao G15 “Acesso total ao disco” em Ajustes > Privacidade e Segurança e tente de novo.\n\n%@",
                             "Give G15 “Full Disk Access” in Settings > Privacy & Security and try again.\n\n%@"), err ?: @""];
        [f runModal];
        tccSeen[key] = nil;                        // deixa perguntar de novo no proximo pedido
    }
}

static void tccLine(NSString *l) {
    if (![l containsString:@"Policy disallows prompt for Sub:{"]) return;
    NSRange a = [l rangeOfString:@"Sub:{"], b = [l rangeOfString:@"}" options:0 range:NSMakeRange(NSMaxRange(a), l.length - NSMaxRange(a))];
    NSRange s = [l rangeOfString:@"access to kTCCService"];
    if (b.location == NSNotFound || s.location == NSNotFound) return;
    NSString *bid = [l substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))];
    NSString *svc = [[[l substringFromIndex:s.location + 10] componentsSeparatedByString:@" "] firstObject];
    if (![svc isEqualToString:@"kTCCServiceMicrophone"] && ![svc isEqualToString:@"kTCCServiceCamera"]) return;
    if ([bid hasPrefix:@"/"] || [bid hasPrefix:@"com.apple."]) return;   // processos do sistema: nao e com a gente
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                          @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if (!bid.length || [bid rangeOfCharacterFromSet:ok.invertedSet].location != NSNotFound) return;
    dispatch_async(dispatch_get_main_queue(), ^{ tccAsk(bid, svc); });
}

static void tccStart(void) {
    if (!tccSeen) { tccSeen = [NSMutableDictionary dictionary]; tccBuf = [NSMutableString string]; }
    tccLog = [NSTask new];
    NSPipe *o = [NSPipe pipe];
    tccLog.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    tccLog.arguments = @[@"stream", @"--style", @"compact", @"--predicate",
                         @"process == \"tccd\" AND eventMessage CONTAINS \"Policy disallows prompt\""];
    tccLog.standardOutput = o; tccLog.standardError = [NSFileHandle fileHandleWithNullDevice];
    o.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; }
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (tccBuf) {
            [tccBuf appendString:s];
            NSRange nl;
            while ((nl = [tccBuf rangeOfString:@"\n"]).location != NSNotFound) {
                tccLine([tccBuf substringToIndex:nl.location]);
                [tccBuf deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            }
        }
    };
    tccLog.terminationHandler = ^(NSTask *t) {     // o log stream caiu: volta em 10 s
        NSLog(@"log stream do tccd terminou (%d); religando", t.terminationStatus);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ tccStart(); });
    };
    NSError *err = nil;
    if (![tccLog launchAndReturnError:&err]) NSLog(@"log stream do tccd: %@", err.localizedDescription);
    else NSLog(@"acompanhando os pedidos de microfone/camera negados pelo tccd");
}

// ---------- supressor de ruido do microfone (plug-in XeSpeakers) ----------
// O plug-in (coreaudiod) le a atenuacao maxima do DeepFilterNet em /Library/Preferences/local.g15.audio.plist (chave
// noiseAttenDb, em dB; a cada ~1 s). O arquivo e do root; o audio/install.sh o deixa gravavel por todos (666), e o app o regrava no lugar.
static NSTextField *nsLabel;
static NSString *const NS_PLIST = @"/Library/Preferences/local.g15.audio.plist";
static const int NS_DEFAULT = 30, NS_MAXDB = 60;    // a barra vai de 0 a 60 dB; a ponta direita (60) = sem limite (100 dB)
static int nsAtten(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:NS_PLIST];
    NSNumber *n = [d[@"noiseAttenDb"] isKindOfClass:NSNumber.class] ? d[@"noiseAttenDb"] : nil;
    return n ? MAX(0, MIN(NS_MAXDB, (int)lround(n.doubleValue >= 100 ? NS_MAXDB : n.doubleValue))) : NS_DEFAULT;
}
static BOOL nsWritable(void) { return [NSFileManager.defaultManager isWritableFileAtPath:NS_PLIST]; }
static BOOL nsSetAtten(int db) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:NS_PLIST] mutableCopy] ?: [NSMutableDictionary new];
    d[@"noiseAttenDb"] = @(db >= NS_MAXDB ? 100.0 : (double)db);
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NS_PLIST];   // no lugar (sem trocar o arquivo): mantem dono e permissao
    if (!fh || !data) return NO;
    [fh truncateFileAtOffset:0]; [fh writeData:data]; [fh closeFile];
    NSLog(@"supressor de ruido: atenuacao %d dB", db);
    return YES;
}

@interface G15Menu : NSObject <NSMenuDelegate>
@property NSStatusItem *item;
@end

@implementation G15Menu

// Barra de menus: ventilador + duas linhas (CPU em cima, RTX embaixo), nome a esquerda e temperatura a direita.
// O nome "RTX" fica verde (em uso), amarelo (ociosa) ou vermelho (desligada/ausente).
- (void)updateTitle:(NSDictionary *)st {
    NSStatusBarButton *b = self.item.button;
    int cpu = st ? fanTemp(st, @"0x01") : -1;
    RtxInfo r = rtxInfo(st);
    NSString *tc = cpu >= 0 ? [NSString stringWithFormat:@"%d°", cpu] : @"--", *tr = r.temp >= 0 ? [NSString stringWithFormat:@"%d°", r.temp] : @"--";
    NSColor *rc = r.state == 2 ? NSColor.systemGreenColor : r.state == 1 ? NSColor.systemYellowColor : NSColor.systemRedColor;
    NSFont *f = [NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightSemibold];
    NSImage *fan = [NSImage imageWithSystemSymbolName:@"fan" accessibilityDescription:@"G15"];
    const CGFloat iconW = 15, gap = 3, textW = 42, h = 22;
    NSImage *img = [NSImage imageWithSize:NSMakeSize(iconW + gap + textW, h) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSColor *fg = NSColor.labelColor;
        if (fan) {                                     // ventilador na cor do texto (claro/escuro)
            NSImage *t = [fan copy]; t.template = YES;
            NSRect ir = NSMakeRect(0, (h - 14) / 2, 14, 14);
            [t drawInRect:ir]; [fg set]; NSRectFillUsingOperation(ir, NSCompositingOperationSourceAtop);
        }
        NSDictionary *a = @{NSFontAttributeName: f, NSForegroundColorAttributeName: fg};
        NSDictionary *ar = @{NSFontAttributeName: f, NSForegroundColorAttributeName: rc};
        CGFloat x = iconW + gap, lh = 10.5;
        [@"CPU" drawAtPoint:NSMakePoint(x, lh) withAttributes:a];
        [@"RTX" drawAtPoint:NSMakePoint(x, 0) withAttributes:ar];
        NSSize s1 = [tc sizeWithAttributes:a], s2 = [tr sizeWithAttributes:a];
        [tc drawAtPoint:NSMakePoint(x + textW - s1.width, lh) withAttributes:a];
        [tr drawAtPoint:NSMakePoint(x + textW - s2.width, 0) withAttributes:a];
        return YES;
    }];
    img.template = NO;
    b.image = img; b.imagePosition = NSImageOnly; b.title = @"";
    b.toolTip = [NSString stringWithFormat:@"CPU %@ · RTX %@ (%@, %d%%)", tc, tr, rtxStateName(r.state), r.util];
}

- (void)tick {                                     // a cada 5 s: titulo e protecao (>= 93 C: 100%; < 90 C: volta)
    lidEvent(readLid(), "tick");
    if (asleep) return;
    NSDictionary *st = fanState(YES);
    [self updateTitle:st];
    if (!st) return;
    int t = MAX(fanTemp(st, @"0x01"), fanTemp(st, @"0x06")), b = fanBoost(st);
    if (hotFrom < 0 && t >= HOT && b >= 0 && b < 100 && setBoost(100)) {
        hotFrom = b;
        NSLog(@"temperatura %d C: boost 100%% (estava em %d%%)", t, b);
        notify(L("Ventoinhas", "Fans"), [NSString stringWithFormat:L("Temperatura em %d °C: ventoinhas a 100%%.", "Temperature at %d °C: fans at 100%%."), t]);
    } else if (hotFrom >= 0 && t < COOL && setBoost(hotFrom)) {
        NSLog(@"temperatura %d C: boost de volta a %d%%", t, hotFrom);
        hotFrom = -1;
    }
}

- (NSMenuItem *)add:(NSMenu *)m title:(NSString *)t action:(SEL)a tag:(NSInteger)tag on:(BOOL)on {
    NSMenuItem *i = [m addItemWithTitle:t action:a keyEquivalent:@""];
    i.target = self; i.tag = tag; i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return i;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSDictionary *st = fanState(YES);
    [self updateTitle:st];
    if (st) {
        [menu addItemWithTitle:tempsText(st) action:nil keyEquivalent:@""];
        NSMutableArray *rpm = [NSMutableArray array];
        for (NSDictionary *f in st[@"Fans"]) [rpm addObject:[NSString stringWithFormat:@"%@", f[@"RPM"] ?: @"?"]];
        [menu addItemWithTitle:[NSString stringWithFormat:L("Ventoinhas: %@ RPM", "Fans: %@ RPM"), [rpm componentsJoinedByString:@" / "]]
                        action:nil keyEquivalent:@""];
    } else {
        [menu addItemWithTitle:L("G15Fan.kext não carregado", "G15Fan.kext not loaded") action:nil keyEquivalent:@""];
    }
    [menu addItem:NSMenuItem.separatorItem];

    if (st) {
        NSMenu *fm = [NSMenu new]; int b = fanBoost(st);
        for (NSNumber *v in @[@0, @25, @50, @75, @90, @100])
            [self add:fm title:boostName(v.intValue) action:@selector(setFan:) tag:v.intValue on:b == v.intValue];
        [menu addItemWithTitle:[L("Ventoinhas: ", "Fans: ") stringByAppendingString:boostName(b)] action:nil keyEquivalent:@""].submenu = fm;

        NSMenu *pm = [NSMenu new]; int cur = [st[@"Profile"] intValue];
        for (NSNumber *p in profileRing(st))
            [self add:pm title:profileName(p.intValue) action:@selector(setProfile:) tag:p.intValue on:p.intValue == cur];
        [menu addItemWithTitle:[L("Perfil: ", "Profile: ") stringByAppendingString:profileName(cur)] action:nil keyEquivalent:@""].submenu = pm;
    }

    NSMenu *km = [NSMenu new];
    for (NSInteger i = 0; i < 3; i++)
        [self add:km title:i ? [NSString stringWithFormat:@"%d%%", KB_PCT[i]] : L("Apagada", "Off") action:@selector(setKb:) tag:i on:kbLevel == i];
    [menu addItemWithTitle:(kbLevel ? [NSString stringWithFormat:L("Luz do teclado: %d%%", "Keyboard light: %d%%"), KB_PCT[kbLevel]]
                                    : L("Luz do teclado: apagada", "Keyboard light: off"))
                    action:nil keyEquivalent:@""].submenu = km;

    {   // barra de atenuacao do supressor de ruido do microfone
        int db = nsAtten();
        NSMenu *nm = [NSMenu new];
        NSMenuItem *si = [NSMenuItem new];
        NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 56)];
        nsLabel = [NSTextField labelWithString:[self nsText:db]];
        nsLabel.frame = NSMakeRect(16, 32, 228, 17);
        NSSlider *sl = [NSSlider sliderWithValue:db minValue:0 maxValue:NS_MAXDB target:self action:@selector(nsSlide:)];
        sl.frame = NSMakeRect(14, 8, 232, 22); sl.continuous = YES; sl.enabled = nsWritable();
        [v addSubview:nsLabel]; [v addSubview:sl];
        si.view = v; [nm addItem:si];
        NSMenuItem *hint = [nm addItemWithTitle:nsWritable() ? L("Menos dB = voz mais natural; mais dB = silêncio mais limpo", "Fewer dB = more natural voice; more dB = cleaner silence")
                                                           : L("Rode audio/install.sh (EFI) para liberar a barra", "Run audio/install.sh (EFI) to enable the slider")
                                         action:nil keyEquivalent:@""];
        hint.enabled = NO;
        [menu addItemWithTitle:[NSString stringWithFormat:L("Supressor de ruído do mic: %@", "Mic noise suppression: %@"), [self nsShort:db]]
                        action:nil keyEquivalent:@""].submenu = nm;
    }

    NSDictionary *dec = [prefs dictionaryForKey:@"tccDecisions"];
    if (dec.count) {
        NSMenu *tm = [NSMenu new];
        for (NSString *k in [dec.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSArray *p = [k componentsSeparatedByString:@"|"];
            [tm addItemWithTitle:[NSString stringWithFormat:@"%@: %@ (%@)", tccAppName(p.firstObject),
                                  [p.lastObject isEqualToString:@"kTCCServiceCamera"] ? L("câmera", "camera") : L("microfone", "microphone"),
                                  [dec[k] isEqualToString:@"permitido"] ? L("permitido", "allowed") : L("negado", "denied")]
                          action:nil keyEquivalent:@""];
        }
        [tm addItem:NSMenuItem.separatorItem];
        [self add:tm title:L("Esquecer respostas (perguntar de novo)", "Forget answers (ask again)") action:@selector(tccForget:) tag:0 on:NO];
        [menu addItemWithTitle:L("Permissões de microfone/câmera", "Microphone/camera permissions") action:nil keyEquivalent:@""].submenu = tm;
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self add:menu title:L("Abrir log", "Open log") action:@selector(openLog:) tag:0 on:NO];
    [self add:menu title:L("Sair do G15", "Quit G15") action:@selector(quit:) tag:0 on:NO];
}

- (NSString *)nsShort:(int)db { return db >= NS_MAXDB ? L("máximo", "max") : [NSString stringWithFormat:@"%d dB", db]; }
- (NSString *)nsText:(int)db { return [NSString stringWithFormat:L("Atenuação máxima: %@", "Max attenuation: %@"), [self nsShort:db]]; }
- (void)nsSlide:(NSSlider *)sl {                   // o rotulo acompanha a barra; o arquivo e gravado 0,4 s depois do ultimo movimento
    int db = (int)lround(sl.doubleValue);
    nsLabel.stringValue = [self nsText:db];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(nsSave:) object:nil];
    [self performSelector:@selector(nsSave:) withObject:@(db) afterDelay:0.4 inModes:@[NSRunLoopCommonModes]];   // menu aberto = modo de tracking
}
- (void)nsSave:(NSNumber *)db { nsSetAtten(db.intValue); }
- (void)setFan:(NSMenuItem *)i { setBoost((int)i.tag); }
- (void)setProfile:(NSMenuItem *)i { applyProfile((int)i.tag); }
- (void)setKb:(NSMenuItem *)i { kbSet(i.tag, NO); }
- (void)openLog:(id)s {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/g15.log"]]];
}
- (void)tccForget:(id)s { [prefs removeObjectForKey:@"tccDecisions"]; [tccSeen removeAllObjects]; NSLog(@"respostas de permissao esquecidas"); }
- (void)quit:(id)s { [NSApp terminate:nil]; }      // saida normal: o LaunchAgent nao relanca ate o proximo login
@end

// ---------- teclas ----------
// Fn+F10 = PrtSc: o VoodooPS2 manda F13 (o macOS nao usa). Captura a tela inteira como Cmd+Shift+3, na pasta dos
// screenshots do usuario (com.apple.screencapture location, senao a Mesa). Na 1a vez o macOS pede Gravacao de Tela.
static void screenshot(void) {
    NSLog(@"F13 recebida (Fn+F10): captura de tela");
    NSString *dir = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("location"), CFSTR("com.apple.screencapture")));
    BOOL isDir = NO;
    if (![dir isKindOfClass:NSString.class] || ![[NSFileManager defaultManager] fileExistsAtPath:(dir = dir.stringByExpandingTildeInPath) isDirectory:&isDir] || !isDir)
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = L("yyyy-MM-dd 'às' HH.mm.ss", "yyyy-MM-dd 'at' HH.mm.ss");
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %@.png",
                      L("Captura de Tela", "Screenshot"), [f stringFromDate:NSDate.date]]];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    t.arguments = @[path];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) NSLog(@"screencapture: %@", err.localizedDescription);
    else NSLog(@"Fn+F10: captura em %@", path);
}

static OSStatus hotkey(EventHandlerCallRef c, EventRef e, void *u) {
    EventHotKeyID id = {0, 0};
    GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id);
    if (id.id == 2) profileStep(); else if (id.id == 3) screenshot();
    else if (id.id >= 10) NSLog(@"tecla de diagnostico recebida: F%u (Fn+F10 chega assim?)", (unsigned)(id.id - 10));
    else kbStep("atalho");
    return noErr;
}

static CFMachPortRef tap;
static CGEventRef tapEvent(CGEventTapProxy p, CGEventType type, CGEventRef ev, void *u) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(tap, true); return ev;
    }
    int64_t key = CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
    if (key != kVK_F18 && key != kVK_F17 && key != kVK_F13) return ev;
    if (type == kCGEventKeyDown && !CGEventGetIntegerValueField(ev, kCGKeyboardEventAutorepeat))
        dispatch_async(dispatch_get_main_queue(), ^{
            if (key == kVK_F17) profileStep(); else if (key == kVK_F13) screenshot(); else kbStep("event tap"); });
    return NULL;                                   // consome F13/F17/F18
}

static void startTap(void) {                       // tenta ate ter a permissao de Acessibilidade
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                           CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp), tapEvent, NULL);
    if (!tap) {
        static BOOL asked;
        if (!asked) {
            asked = YES;
            NSLog(@"sem permissao de Acessibilidade: libere o G15 em Ajustes > Privacidade e Seguranca > Acessibilidade");
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ startTap(); });
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(NULL, tap, 0), kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    NSLog(@"event tap ativo (F13, F17, F18)");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && isdigit((unsigned char)argv[1][0])) {          // teste da luz pela linha de comando
            int pct = atoi(argv[1]);
            if (pct > 100) { fprintf(stderr, "uso: G15 [--daemon] | G15 0..100\n"); return 2; }
            kbOpen(); kbSend(pct); return 0;
        }
        if (argc >= 2 && !strncmp(argv[1], "--", 2) && strcmp(argv[1], "--daemon")) {   // ventoinhas pela linha de comando
            kern_return_t r = KERN_SUCCESS;
            if (!strcmp(argv[1], "--perfil") && argc == 3) r = applyProfile((int)strtol(argv[2], NULL, 0)) ? KERN_SUCCESS : KERN_FAILURE;   // perfil + ventoinhas + EPP
            else if (!strcmp(argv[1], "--boost") && argc == 3) r = fanWrite(@{@"FanBoost": @(atoi(argv[2]))});
            else if (strcmp(argv[1], "--estado")) { fprintf(stderr, "uso: G15 --estado | --perfil 0xNN | --boost N\n"); return 2; }
            NSDictionary *st = fanState(YES);
            if (!st) { fprintf(stderr, "G15Fan.kext nao carregado\n"); return 1; }
            NSMutableArray *rpm = [NSMutableArray array];
            for (NSDictionary *f in st[@"Fans"]) [rpm addObject:[NSString stringWithFormat:@"%@", f[@"RPM"]]];
            printf("perfil 0x%02x (%s)  boost %d  %s  fans %s RPM\n", [st[@"Profile"] intValue], profileName([st[@"Profile"] intValue]).UTF8String,
                   fanBoost(st), tempsText(st).UTF8String, [rpm componentsJoinedByString:@"/"].UTF8String);
            return r == KERN_SUCCESS ? 0 : 1;
        }
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"local.g15.app";
        if ([NSRunningApplication runningApplicationsWithBundleIdentifier:bid].count > 1) return 0;   // ja rodando

        PT = [NSLocale.preferredLanguages.firstObject hasPrefix:@"pt"];
        prefs = [[NSUserDefaults alloc] initWithSuiteName:@"local.g15"];
        NSUserDefaults *old = [[NSUserDefaults alloc] initWithSuiteName:@"local.g15kbd"];      // versao anterior (g15kbd)
        if (![prefs objectForKey:@"level"] && [old objectForKey:@"level"]) [prefs setInteger:[old integerForKey:@"level"] forKey:@"level"];
        if ([prefs objectForKey:@"level"]) kbLevel = MAX(0, MIN(2, [prefs integerForKey:@"level"]));

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // sem icone no Dock, recebe atalhos

        [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert
            completionHandler:^(BOOL granted, NSError *err) {
                dispatch_async(dispatch_get_main_queue(), ^{ notifyOK = granted; });
                NSLog(@"notificacoes do app: %@%@", granted ? @"permitidas" : @"negadas (usando osascript)",
                      err ? [@" - " stringByAppendingString:err.localizedDescription] : @"");
            }];

        kbOpen();
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, kbDeviceAdded, NULL);
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

        EventTypeSpec t = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(&hotkey, 1, &t, NULL, NULL);
        EventHotKeyRef ref, ref2;
        OSStatus s = RegisterEventHotKey(kVK_F18, 0, (EventHotKeyID){'g15k', 1}, GetApplicationEventTarget(), 0, &ref);
        OSStatus s2 = RegisterEventHotKey(kVK_F17, 0, (EventHotKeyID){'g15k', 2}, GetApplicationEventTarget(), 0, &ref2);
        EventHotKeyRef ref3;                       // F13 = Fn+F10 (PrtSc): captura de tela; se falhar, so essa tecla fica sem
        if (RegisterEventHotKey(kVK_F13, 0, (EventHotKeyID){'g15k', 3}, GetApplicationEventTarget(), 0, &ref3) != noErr)
            NSLog(@"RegisterEventHotKey F13 (captura de tela) falhou");
        // 27/10: Fn+F10 nao disparou o F13; registra outras teclas F so para logar qual chega (id 10 + n = Fn)
        const struct { int vk, n; } diag[] = {{kVK_F14, 14}, {kVK_F15, 15}, {kVK_F16, 16}, {kVK_F19, 19}};
        for (size_t i = 0; i < sizeof diag / sizeof *diag; i++) {
            EventHotKeyRef r;
            RegisterEventHotKey(diag[i].vk, 0, (EventHotKeyID){'g15k', (UInt32)(10 + diag[i].n)}, GetApplicationEventTarget(), 0, &r);
        }
        if (s == noErr && s2 == noErr && !getenv("G15KBD_TAP")) NSLog(@"atalhos F18 (luz), F17 (perfil) e F13 (captura) registrados");
        else { NSLog(@"RegisterEventHotKey F18: %d, F17: %d; usando event tap", (int)s, (int)s2); startTap(); }

        tccStart();
        G15Menu *ui = [G15Menu new];
        ui.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        NSMenu *menu = [NSMenu new]; menu.delegate = ui; ui.item.menu = menu;

        NSDictionary *st = fanState(YES);
        if (!st) NSLog(@"G15Fan.kext nao carregado: Fn+F9 e protecao de temperatura desligados");
        else {                                         // boost do perfil atual, ou "fanDefault" se definido (-1 = nao mexe)
            int fanDefault = [prefs objectForKey:@"fanDefault"] ? (int)[prefs integerForKey:@"fanDefault"]
                                                                 : profileFanBoost([st[@"Profile"] intValue]);
            NSLog(@"G15Fan: boost %d%%, %@, perfil %@", fanBoost(st), tempsText(st), st[@"Profile"]);
            if (fanDefault >= 0 && fanDefault <= 100) setBoost(fanDefault);
            setEpp(profileEpp([st[@"Profile"] intValue]));
        }
        [ui updateTitle:fanState(NO)];
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *tm) { [ui tick]; }];

        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserverForName:NSWorkspaceDidWakeNotification
            object:nil queue:nil usingBlock:^(NSNotification *n) { NSLog(@"acordou"); wakeRestore(); kbApplySoon(1.0); }];
        powerOpen();
        acOpen();

        NSLog(@"G15 iniciado, luz nivel %ld", (long)kbLevel);
        kbApplySoon(0.2);
        [NSApp run];
    }
    return 0;
}
