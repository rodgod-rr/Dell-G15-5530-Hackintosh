// G15.app: teclas Fn do Dell G15 5530 no macOS, com icone na barra de menus. Faz o mesmo que o Linux:
//  - Fn+F5 (F18 para o VoodooPS2: scancode PS/2 0x69 -> ADB 0x4f): luz do teclado apagada -> 50% -> 100%, com uma
//    barrinha na tela (como a do KDE). Controlador Alienware AW-ELC 187c:0551, relatorio de saida de 33 bytes sem
//    report ID: 03 26 <dim> 00 04 00 01 02 03 00...  dim = 100 - brilho% (linux/g15-kbd, tools/test-kbd-backlight.py).
//    O nivel e reaplicado ao iniciar, ao acordar e quando o controlador reaparece.
//  - Luz do teclado (menu): janela com o desenho do teclado, 1 ou 4 zonas, cor (NSColorWell ou paleta), efeitos do
//    controlador (fixo, respiracao, transicao, espectro, onda) com velocidade, brilho, predefinicoes, perfis com nome
//    e o tempo para a luz apagar (BIOS, pelo G15Fan: KbdTimeout). O efeito e reaplicado junto com o brilho.
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
#import <CoreAudio/CoreAudio.h>
#include <sys/sysctl.h>
#import <UserNotifications/UserNotifications.h>
#import <dlfcn.h>

static NSUserDefaults *prefs;
static BOOL g15Quitting;                           // reiniciando (permissao do proprio G15): nao confere/avisa o BT

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
// AW-ELC (testado no Fedora em 09/11/2026, tools/test-kbd-elc.py; protocolo do OpenRGB AlienwareController): relatorio
// de saida de 33 bytes, resposta lida por GET_REPORT de entrada (83 <cmd> ...). Zonas 00 esquerda, 01 centro,
// 02 direita, 03 numerico. Uma cor/efeito = 21 0001 FFFF (nova animacao temporaria) -> {23 01 <n> <zonas> ->
// 24 <acoes>} por zona -> 21 0003 FFFF (fim e toca). Acao (8 bytes, ate 3 por pacote): modo 00 cor / 01 pulso /
// 02 transicao, duracao em ms (16 bits: menor = mais rapido), tempo (16 bits), r g b. Brilho: 26 <dim> 00 04 00 01 02 03.
// Nada e gravado na memoria do controlador: no boot ele volta a animacao padrao, e o app reaplica.
static IOHIDManagerRef mgr;
static NSInteger kbLevel = 2;                      // 0, 1, 2
static const int KB_PCT[3] = {0, 50, 100};
static BOOL kbBattery;                              // (11/11) perfil Bateria: o nivel do meio vale 25% em vez de 50%
static int kbPct(NSInteger lv) { return lv == 1 && kbBattery ? 25 : KB_PCT[lv]; }
static dispatch_queue_t kbq;                       // pacotes do controlador em ordem, fora da thread principal
static volatile NSUInteger kbGen;                  // cada nova cor cancela as que ainda nao comecaram

static void kbPackets(NSArray<NSData *> *pkts) {   // roda na kbq
    CFSetRef devs = mgr ? IOHIDManagerCopyDevices(mgr) : NULL;
    CFIndex n = devs ? CFSetGetCount(devs) : 0;
    if (!n) { NSLog(@"AW-ELC 187c:0551 nao encontrado"); if (devs) CFRelease(devs); return; }
    const void *vals[n]; CFSetGetValues(devs, vals);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDDeviceRef d = (IOHIDDeviceRef)vals[i];
        for (NSData *p in pkts) {
            IOReturn e = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, p.bytes, p.length);
            if (e != kIOReturnSuccess) { NSLog(@"AW-ELC: erro 0x%08x no comando %02x", e, ((uint8_t *)p.bytes)[1]); break; }
            uint8_t r[33]; CFIndex rl = sizeof r;          // a resposta do comando (o controlador espera ser lido)
            IOHIDDeviceGetReport(d, kIOHIDReportTypeInput, 0, r, &rl);
            usleep(30000);
        }
    }
    CFRelease(devs);
}

static NSData *kbPkt(const uint8_t *b, size_t n) {
    uint8_t r[33] = {0x03}; memcpy(r + 1, b, MIN(n, (size_t)32));
    return [NSData dataWithBytes:r length:33];
}

static void kbSend(int pct) {                      // so o brilho (sincrono: tambem usado antes de dormir e na linha de comando)
    if (!kbq) kbq = dispatch_queue_create("local.g15.awelc", DISPATCH_QUEUE_SERIAL);
    uint8_t b[] = {0x26, (uint8_t)(100 - pct), 0x00, 0x04, 0x00, 0x01, 0x02, 0x03};
    NSData *p = kbPkt(b, sizeof b);
    dispatch_sync(kbq, ^{ kbPackets(@[p]); });
    NSLog(@"brilho %d%%", pct);
}

// efeito salvo em prefs "kbLight": {effect: static|breath|morph|spectrum|wave, zones: 1|4, colors: [4 x "RRGGBB"],
// color2: "RRGGBB", speed: 0..4}; perfis do usuario em "kbProfiles" {nome: efeito}
static NSArray<NSString *> *kbEffects(void) { return @[@"static", @"breath", @"morph", @"spectrum", @"wave"]; }
static const int KB_DUR[5] = {2400, 1400, 800, 450, 250};   // ms por passo; 300 com tempo 15 ficou bom na onda (Fedora)
static const uint32_t KB_RAINBOW[7] = {0xFF0000, 0xFFA500, 0xFFFF00, 0x00C000, 0x00BFFF, 0x0000FF, 0x8000FF};

static uint32_t hexColor(id s) { return [s isKindOfClass:NSString.class] ? (uint32_t)strtoul([s UTF8String], NULL, 16) & 0xFFFFFF : 0xFFFFFF; }

static NSDictionary *kbDefaultLight(void) {
    return @{@"effect": @"static", @"zones": @1, @"colors": @[@"FFFFFF", @"FFFFFF", @"FFFFFF", @"FFFFFF"], @"color2": @"0000FF", @"speed": @2};
}
static NSDictionary *kbLight(void) {
    NSDictionary *d = [prefs dictionaryForKey:@"kbLight"];
    return [d[@"colors"] isKindOfClass:NSArray.class] && [d[@"colors"] count] == 4 ? d : kbDefaultLight();
}
static uint32_t kbZoneColor(NSDictionary *L, int z) { return hexColor(L[@"colors"][[L[@"zones"] intValue] == 4 ? z : 0]); }

static NSArray<NSData *> *kbLightPackets(NSDictionary *L) {
    NSMutableArray *p = [NSMutableArray array];
    NSString *fx = L[@"effect"] ?: @"static";
    int sp = MAX(0, MIN(4, [L[@"speed"] intValue])), dur = KB_DUR[sp];
    uint16_t tempo = [fx isEqualToString:@"static"] ? 0xFA : 0x0F;
    BOOL one = [L[@"zones"] intValue] != 4 && ![fx isEqualToString:@"wave"];
    uint8_t a1[] = {0x21, 0x00, 0x01, 0xFF, 0xFF, 0, 0};
    [p addObject:kbPkt(a1, sizeof a1)];
    for (int z = 0; z < (one ? 1 : 4); z++) {
        if (one) { uint8_t s[] = {0x23, 1, 0, 4, 0, 1, 2, 3}; [p addObject:kbPkt(s, sizeof s)]; }
        else     { uint8_t s[] = {0x23, 1, 0, 1, (uint8_t)z}; [p addObject:kbPkt(s, sizeof s)]; }
        uint32_t c = kbZoneColor(L, z), c2 = hexColor(L[@"color2"]);
        NSMutableArray<NSArray *> *acts = [NSMutableArray array];         // {modo, cor}
        if ([fx isEqualToString:@"breath"])      { [acts addObject:@[@2, @(c)]]; [acts addObject:@[@2, @0]]; }
        else if ([fx isEqualToString:@"morph"])  { [acts addObject:@[@2, @(c)]]; [acts addObject:@[@2, @(c2)]]; }
        else if ([fx isEqualToString:@"spectrum"] || [fx isEqualToString:@"wave"]) {
            int sh = [fx isEqualToString:@"wave"] ? z : 0;                // onda: cada zona um passo atras da anterior
            for (int k = 0; k < 7; k++) [acts addObject:@[@2, @(KB_RAINBOW[(k - sh + 7) % 7])]];
        } else [acts addObject:@[@0, @(c)]];
        for (NSUInteger i = 0; i < acts.count; i += 3) {
            uint8_t b[25] = {0x24}; size_t n = 1;
            for (NSUInteger j = i; j < MIN(i + 3, acts.count); j++) {
                uint32_t col = [acts[j][1] unsignedIntValue];
                uint8_t a[8] = {[acts[j][0] unsignedCharValue], dur >> 8, dur & 255, tempo >> 8, tempo & 255,
                                col >> 16, (col >> 8) & 255, col & 255};
                memcpy(b + n, a, 8); n += 8;
            }
            [p addObject:kbPkt(b, n)];
        }
    }
    uint8_t a3[] = {0x21, 0x00, 0x03, 0xFF, 0xFF, 0, 0};
    [p addObject:kbPkt(a3, sizeof a3)];
    uint8_t dm[] = {0x26, (uint8_t)(100 - kbPct(kbLevel)), 0x00, 0x04, 0x00, 0x01, 0x02, 0x03};
    [p addObject:kbPkt(dm, sizeof dm)];
    return p;
}

static void kbApplyLight(NSDictionary *L) {        // assincrono; so a ultima de uma sequencia rapida e mandada
    if (!kbq) kbq = dispatch_queue_create("local.g15.awelc", DISPATCH_QUEUE_SERIAL);
    NSArray *pk = kbLightPackets(L);
    NSUInteger g = ++kbGen;
    dispatch_async(kbq, ^{
        if (g != kbGen) return;
        kbPackets(pk);
        NSLog(@"luz: %@ %@ zona(s), velocidade %@", L[@"effect"], L[@"zones"], L[@"speed"]);
    });
}

static void kbApply(void) { kbApplyLight(kbLight()); }   // efeito + brilho

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

static void kbWindowRefresh(void);                 // a janela da luz acompanha o Fn+F5

static void kbSet(NSInteger lv, BOOL showOnScreen) {
    kbLevel = lv;
    [prefs setInteger:kbLevel forKey:@"level"];
    kbSend(kbPct(kbLevel));
    kbWindowRefresh();
    if (showOnScreen)
        showHUD(kbLevel ? @"light.max" : @"light.min", kbLevel ? [NSString stringWithFormat:L("Luz do teclado: %d%%", "Keyboard light: %d%%"), kbPct(kbLevel)]
                                                               : L("Luz do teclado: apagada", "Keyboard light: off"), kbPct(kbLevel));
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
    // (10/11) RTX parada pelo G15Fan (RtxPm, "imitar o repouso"): o NVAccel continua no registro com a ultima leitura
    // congelada; vale o estado desligado e a temperatura do sensor 0x06 do EC (le a placa mesmo sem energia nela).
    BOOL parked = [st[@"RtxParked"] boolValue];
    io_service_t sv = parked ? 0 : IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
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

static void batteryExtras(int p);
// (11/11) perfil Bateria: G15PMControl "RtxDeny" = a RTX parada recusa os programas (nao religa). Escreve so quando muda.
static int rtxDenySent = -1;
static void rtxDenySync(BOOL deny) {
    if (rtxDenySent == deny) return;
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15PMControl"));
    if (!sv) return;
    kern_return_t r = IORegistryEntrySetCFProperties(sv, (__bridge CFDictionaryRef)@{@"RtxDeny": @(deny)});
    BOOL has = [CFBridgingRelease(IORegistryEntryCreateCFProperty(sv, CFSTR("RtxDeny"), kCFAllocatorDefault, 0)) isKindOfClass:NSNumber.class];
    IOObjectRelease(sv);
    if (r == KERN_SUCCESS && has) rtxDenySent = deny;
    NSLog(@"G15PM: RTX %s: %@", deny ? "recusa programas (Bateria)" : "religa sob demanda",
          r == KERN_SUCCESS && has ? @"ok" : has ? [NSString stringWithFormat:@"erro 0x%08x", r] : @"G15PM sem RtxDeny (kext antigo)");
    if (!has) rtxDenySent = deny;                  // kext antigo: nao insiste a cada tique
}

static int profileApplied = -1;                    // ultimo perfil trocado por este processo (o tick ve trocas de fora)
static BOOL applyProfile(int p) {                  // perfil + boost das ventoinhas + EPP do perfil (+ extras da Bateria)
    if (fanWrite(@{@"Profile": @(p)}) != KERN_SUCCESS) return NO;
    if (hotFrom >= 0) hotFrom = profileFanBoost(p);   // quente: aplica quando esfriar
    else setBoost(profileFanBoost(p));
    setEpp(profileEpp(p));
    profileApplied = p;
    batteryExtras(p);
    rtxDenySync(profileRank(p) == 0);
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

// ---------- RTX automatica (G15Fan RtxPm, 10/11) ----------
// Sem uso (com o G15PM do revoke: Device Utilization < 2%; sem ele: nenhum programa conectado) e sem monitor externo
// por 30 s na bateria ou 5 min na tomada (3 min ate 11/11), para a
// RTX (NVRM e audio HDMI no estado 0; com -g15fan-rtxpm-corte o G15Fan corta a energia). Ao conectar o carregador:
// religa (e ela volta a parar depois de 5 min ociosa). Parada, a RTX nao ve o cabo HDMI: modo "Ligada" antes. Modo no menu (seletor RTX), preferencia local.g15 "rtxMode".
static int rtxIdleTicks;
static NSString *rtxLastWho;                       // quem esta segurando a RTX (log so quando muda)
// modo (preferencia "rtxMode"): 0 desligada (para sempre que ociosa 30 s; um programa que a pedir ainda a religa),
// 1 ligada (nunca para), 2 automatica (ociosa: 30 s na bateria, 5 min na tomada; religa no carregador)
static int rtxMode(void) { id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"rtxMode"]; return v ? MAX(0, MIN(2, [v intValue])) : 2; }
static int rtxClients(void) {                      // conexoes abertas no NVAccel (Metal/OpenCL de algum programa)
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (!sv) return 0;
    io_iterator_t it = 0; int n = 0;
    if (IORegistryEntryGetChildIterator(sv, kIOServicePlane, &it) == KERN_SUCCESS) {
        io_object_t c;
        while ((c = IOIteratorNext(it))) { if (IOObjectConformsTo(c, "IOUserClient")) n++; IOObjectRelease(c); }
        IOObjectRelease(it);
    }
    IOObjectRelease(sv);
    return n;
}
static NSString *rtxClientNames(void) {            // "pid 123, Foo" de cada cliente (IOUserClientCreator)
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (!sv) return @"";
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(sv, kIOServicePlane, &it) == KERN_SUCCESS) {
        io_object_t c;
        while ((c = IOIteratorNext(it))) {
            NSString *s = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0));
            if ([s isKindOfClass:NSString.class]) [names addObject:s];
            IOObjectRelease(c);
        }
        IOObjectRelease(it);
    }
    IOObjectRelease(sv);
    return [names.array componentsJoinedByString:@"; "];
}
static BOOL rtxExternal(void) {                    // mais de uma tela ligada (espelhada conta)
    uint32_t n = 0; CGGetOnlineDisplayList(0, NULL, &n);
    return n > 1;
}
// (11/11) revoke + religar no uso de verdade (G15PM kern_revoke.cpp / kern_wake.cpp). Com o G15PMControl expondo
// "RtxRevoke": a RTX para pelo USO (Device Utilization < 2% pelo tempo do modo), mesmo com programas conectados; antes
// de parar liga o revoke (RtxRevoke 1: o primeiro uso de um programa conectado a religa). "RtxLazy" 1: listar as placas
// do Metal (todo app faz ao abrir) nao religa mais; so um cliente do RM (o app criando o dispositivo) ou uma chamada
// ao driver. Sem o G15PM novo: o criterio antigo (nenhum programa conectado).
static id g15pmGet(NSString *k) {
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15PMControl"));
    if (!sv) return nil;
    id v = CFBridgingRelease(IORegistryEntryCreateCFProperty(sv, (__bridge CFStringRef)k, kCFAllocatorDefault, 0));
    IOObjectRelease(sv);
    return v;
}
static BOOL g15pmSet(NSString *k, BOOL v) {
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15PMControl"));
    if (!sv) return NO;
    kern_return_t r = IORegistryEntrySetCFProperties(sv, (__bridge CFDictionaryRef)@{k: @(v)});
    IOObjectRelease(sv);
    return r == KERN_SUCCESS && [g15pmGet(k) boolValue] == v;
}
static BOOL rtxRevokeAvail(void) { return g15pmGet(@"RtxRevoke") != nil && g15pmGet(@"RtxLazy") != nil; }
// (11/11) atividade = chamadas ao driver da RTX ("RtxCalls" do G15PMControl, como o RTD3 fino do Linux conta cada
// ioctl): um jogo leve a 60 quadros/s chama o driver o tempo todo, mesmo com o uso abaixo de 2%. Lido 1x por tique.
static unsigned long long rtxCallsPrev; static BOOL rtxCallsMoved, rtxCallsHave;
static void rtxCallsTick(void) {
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("G15PMControl"));
    if (!sv) { rtxCallsHave = NO; return; }
    IORegistryEntrySetCFProperties(sv, (__bridge CFDictionaryRef)@{@"Refresh": @YES});   // publica o total atual
    NSNumber *n = CFBridgingRelease(IORegistryEntryCreateCFProperty(sv, CFSTR("RtxCalls"), kCFAllocatorDefault, 0));
    IOObjectRelease(sv);
    rtxCallsHave = [n isKindOfClass:NSNumber.class];
    unsigned long long c = n.unsignedLongLongValue;
    rtxCallsMoved = rtxCallsHave && c != rtxCallsPrev;
    rtxCallsPrev = c;
}
static BOOL rtxIdleNow(NSDictionary *st) {
    if (!rtxRevokeAvail()) return rtxClients() == 0;
    return rtxInfo(st).util < 2 && !(rtxCallsHave && rtxCallsMoved);
}

static BOOL rtxSet(BOOL on, const char *why) {
    int n = on ? 0 : rtxClients();
    if (!on && n) {                                // programas conectados: so com o revoke ligado antes
        if (!rtxRevokeAvail() || !g15pmSet(@"RtxRevoke", YES)) {
            NSLog(@"RTX parar (%s): %d programa(s) conectado(s) e sem revoke; fica ligada", why, n);
            rtxIdleTicks = 0; return NO;
        }
    }
    kern_return_t r = fanWrite(@{@"RtxPm": on ? @1 : @2});
    NSLog(@"RTX %s (%s)%@: %s", on ? "ligar" : "parar", why,
          n ? [NSString stringWithFormat:@", revoke com %d conexao(oes): %@", n, rtxClientNames()] : @"", r == KERN_SUCCESS ? "ok" : "erro");
    rtxIdleTicks = 0; rtxLastWho = nil;
    return r == KERN_SUCCESS;
}
static void rtxTick(NSDictionary *st, int ac) {    // a cada 5 s
    int mode = rtxMode();
    if (st && ![st[@"RtxParked"] boolValue]) rtxCallsTick();   // quem usa a RTX (painel), em qualquer modo
    if (!st || mode == 1 || (mode == 2 && ac < 0) || !st[@"RtxParked"] || [st[@"RtxParked"] boolValue]) { rtxIdleTicks = 0; return; }
    if (rtxRevokeAvail() && ![g15pmGet(@"RtxLazy") boolValue]) NSLog(@"G15PM: RtxLazy %s", g15pmSet(@"RtxLazy", YES) ? "ligado" : "erro");
    if (!rtxIdleNow(st) || rtxExternal()) {
        rtxIdleTicks = 0;
        NSString *who = rtxExternal() ? @"monitor externo" : [NSString stringWithFormat:@"%@ (uso %d%%%@)", rtxClientNames(), rtxInfo(st).util,
                                                rtxCallsMoved ? [NSString stringWithFormat:@", chamando o driver: %@", g15pmGet(@"RtxCallsLast") ?: @"?"] : @""];
        if (![who isEqualToString:rtxLastWho]) { rtxLastWho = who; NSLog(@"RTX acordada e presa por: %@", who); }
        return;
    }
    if (mode == 0) { if (++rtxIdleTicks >= 6) rtxSet(NO, "modo desligada, ociosa 30 s"); return; }
    if (++rtxIdleTicks >= (ac ? 60 : 6)) rtxSet(NO, ac ? "tomada, ociosa 5 min" : "bateria, ociosa 30 s");
}
static void rtxPower(int ac) {                     // carregador mudou
    rtxIdleTicks = 0;
    if (ac != 1 || rtxMode() != 2) return;
    NSDictionary *st = fanState(NO);
    if ([st[@"RtxParked"] boolValue]) rtxSet(YES, "carregador conectado");
}


// ---------- pausar em segundo plano (11/11) ----------
// O painel mostra o app que esta chamando o driver da RTX ("RtxCallsLast" do G15PM entre os clientes do NVAccel) e uma
// botao "Pausar em 2o plano" SO para ele e SO enquanto ESTE processo dele estiver aberto: fica guardado (pref "bgPausa":
// pid + hora em que o processo comecou, contra pid reaproveitado) e sobrevive ao G15 reiniciar; fechou o app, apaga e na
// proxima vez o botao volta a perguntar. Ligada: se o app
// ficar 30 s fora da frente (2 min ate 11/11), o G15 o congela (SIGSTOP) -> ele para de chamar o driver e a RTX desliga pelo criterio
// normal; ao voltar para ele (Cmd+Tab, clique, Dock) descongela na hora (SIGCONT) e a RTX religa sozinha. Desligar a
// chave, fechar o app ou sair do G15 descongela.
static const NSTimeInterval BG_SECS = 30;
static pid_t bgPid; static unsigned long long bgStart; static NSString *bgName; static BOOL bgPaused; static NSDate *bgSince; static NSTimer *bgTimer;
static void panelRefreshSoon(void);
static pid_t rtxAppPid(NSString **nameOut) {       // app (janela normal) que esta chamando o driver da RTX agora
    if (!rtxCallsMoved) return 0;
    NSString *last = g15pmGet(@"RtxCallsLast");
    if (![last isKindOfClass:NSString.class] || !last.length) return 0;
    io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"));
    if (!sv) return 0;
    pid_t found = 0; io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(sv, kIOServicePlane, &it) == KERN_SUCCESS) {
        io_object_t c;
        while (!found && (c = IOIteratorNext(it))) {
            NSString *cr = CFBridgingRelease(IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0));
            IOObjectRelease(c);
            int pid = 0; char nm[64] = {0};
            if (![cr isKindOfClass:NSString.class] || sscanf(cr.UTF8String, "pid %d, %63[^\n]", &pid, nm) != 2) continue;
            NSString *n = @(nm);
            if (!([n hasPrefix:last] || [last hasPrefix:n])) continue;
            NSRunningApplication *ra = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            if (ra && ra.activationPolicy == NSApplicationActivationPolicyRegular && pid != getpid()) {
                found = pid; if (nameOut) *nameOut = ra.localizedName ?: n;
            }
        }
        IOObjectRelease(it);
    }
    IOObjectRelease(sv);
    return found;
}
// Congelado, o app nao entrega mais audio e o macOS repete o ultimo pedaco do buffer (som "travado"). Nao ha volume
// por app no macOS: silencia a saida padrao enquanto o app estiver congelado e devolve como estava ao descongelar.
static int bgMutedByUs = -1;                       // -1 = nao mexemos; 0/1 = mudo de antes
static AudioObjectID bgOutDev(void) {
    AudioObjectID d = 0; UInt32 sz = sizeof d;
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &d) == noErr ? d : 0;
}
static BOOL bgMute(UInt32 on, UInt32 *was) {
    AudioObjectID d = bgOutDev(); if (!d) return NO;
    AudioObjectPropertyAddress a = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 sz = sizeof(UInt32), cur = 0;
    if (was && AudioObjectGetPropertyData(d, &a, 0, NULL, &sz, &cur) == noErr) *was = cur;
    return AudioObjectSetPropertyData(d, &a, 0, NULL, sizeof on, &on) == noErr;
}
static void bgAudioBack(void);
static void bgAudioOff(void) {                     // so ~1 s: o tempo de o macOS largar o audio parado; depois devolve
    UInt32 was = 0;
    if (bgMutedByUs < 0 && bgMute(1, &was)) {
        bgMutedByUs = (int)was;
        NSLog(@"pausa em segundo plano: som silenciado por 1 s (estava %s)", was ? "mudo" : "ligado");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ bgAudioBack(); });
    } else if (bgMutedByUs < 0) NSLog(@"pausa em segundo plano: a saida de som nao aceita mudo");
}
static void bgAudioBack(void) {
    if (bgMutedByUs < 0) return;
    if (!bgMutedByUs) bgMute(0, NULL);             // so tira o mudo se estava ligado antes
    NSLog(@"pausa em segundo plano: som devolvido (%s)", bgMutedByUs ? "continua mudo" : "ligado");
    bgMutedByUs = -1;
}
static unsigned long long procStart(pid_t pid, BOOL *stopped) {   // hora em que o processo comecou (us); 0 = nao existe
    struct kinfo_proc kp; size_t len = sizeof kp; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return 0;
    if (stopped) *stopped = kp.kp_proc.p_stat == SSTOP;
    return (unsigned long long)kp.kp_proc.p_starttime.tv_sec * 1000000ULL + kp.kp_proc.p_starttime.tv_usec;
}
static void bgSave(void) {
    if (bgPid) [prefs setObject:@{@"pid": @(bgPid), @"inicio": @(procStart(bgPid, NULL)), @"nome": bgName ?: @"?"} forKey:@"bgPausa"];
    else [prefs removeObjectForKey:@"bgPausa"];
}
static void bgResume(const char *why) {
    if (bgPid && bgPaused) {
        kill(bgPid, SIGCONT);
        bgAudioBack();
        NSLog(@"pausa em segundo plano: %@ (pid %d) DESCONGELADO (%s)", bgName, bgPid, why);
    }
    bgPaused = NO; bgSince = nil;
}
static void bgCheck(void) {                        // a cada 1 s com a chave ligada
    if (!bgPid) return;
    if ((kill(bgPid, 0) != 0 && errno == ESRCH) || procStart(bgPid, NULL) != bgStart) {   // app fechado (ou pid de outro): some
        NSLog(@"pausa em segundo plano: %@ fechado", bgName);
        bgPid = 0; bgSave(); bgPaused = NO; bgSince = nil; [bgTimer invalidate]; bgTimer = nil; panelRefreshSoon(); return;
    }
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == bgPid) {
        if (bgPaused) { bgResume("voltou para a frente"); panelRefreshSoon(); }
        bgSince = nil; return;
    }
    if (!bgSince) bgSince = [NSDate date];
    if (!bgPaused && -bgSince.timeIntervalSinceNow >= BG_SECS) {
        if (kill(bgPid, SIGSTOP) == 0) {
            bgPaused = YES;
            bgAudioOff();
            NSLog(@"pausa em segundo plano: %@ (pid %d) CONGELADO apos %.0f s fora da frente", bgName, bgPid, BG_SECS);
            notify(@"RTX", [NSString stringWithFormat:L("%@ pausado em segundo plano (som silenciado). Volte para ele para continuar.",
                                                         "%@ paused in the background (sound muted). Switch back to it to continue."), bgName]);
            panelRefreshSoon();
        }
    }
}
static void bgSet(pid_t pid, NSString *name);
static void bgRestore(void) {                      // ao abrir o G15: a pausa guardada vale se o MESMO processo ainda roda
    NSDictionary *d = [prefs dictionaryForKey:@"bgPausa"];
    if (!d) return;
    pid_t pid = [d[@"pid"] intValue]; BOOL stopped = NO;
    unsigned long long st = procStart(pid, &stopped);
    if (!pid || !st || st != [d[@"inicio"] unsignedLongLongValue]) {
        NSLog(@"pausa em segundo plano: %@ ja fechou; esquecida", d[@"nome"]); [prefs removeObjectForKey:@"bgPausa"]; return;
    }
    bgSet(pid, d[@"nome"]);
    bgPaused = stopped;                            // se o G15 reiniciou com ele congelado, continua congelado ate voltar a ele
    NSLog(@"pausa em segundo plano: retomada para %@ (pid %d)%s", d[@"nome"], pid, stopped ? ", congelado" : "");
}
static void bgSet(pid_t pid, NSString *name) {     // pid 0 = desliga (e descongela)
    if (!pid) {
        bgResume("chave desligada");
        if (bgPid) NSLog(@"pausa em segundo plano: desligada para %@", bgName);
        bgPid = 0; bgName = nil; bgSave(); [bgTimer invalidate]; bgTimer = nil; return;
    }
    bgResume("trocando de app");
    bgPid = pid; bgName = name; bgSince = nil; bgStart = procStart(pid, NULL); bgSave();
    NSLog(@"pausa em segundo plano: ligada para %@ (pid %d), congela apos %.0f s fora da frente", name, pid, BG_SECS);
    static BOOL obs;
    if (!obs) {                                     // voltar para o app descongela na hora; sair do G15 tambem
        obs = YES;
        [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil
                                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { bgCheck(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:nil
                                                         queue:nil usingBlock:^(NSNotification *n) { bgResume("G15 saindo"); }];
        signal(SIGTERM, SIG_IGN);                   // launchctl/stop: descongela antes de sair
        static dispatch_source_t term; term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ bgResume("G15 encerrado (SIGTERM)"); exit(0); });
        dispatch_resume(term);
    }
    [bgTimer invalidate];
    bgTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { bgCheck(); }];
    [[NSRunLoop mainRunLoop] addTimer:bgTimer forMode:NSRunLoopCommonModes];
}

// ---------- extras do perfil Bateria (11/11) ----------
// Entrar na Bateria: tela interna a 60 Hz (de 120), brilho no maximo 50% e RTX no modo "Desligada". Sair da Bateria:
// volta a taxa de antes (pref "hzAntesBateria") e a RTX vai para "Automatica" (se estava Desligada); o brilho fica.
// O Bluetooth usa 1 min (em vez de 3) enquanto o perfil for Bateria (btTick).
static int onAC(void);
static void rtxSetMode(int m);
static CGDirectDisplayID builtinDisplay(void) {
    uint32_t n = 0; CGDirectDisplayID d[8];
    if (CGGetOnlineDisplayList(8, d, &n) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < n; i++) if (CGDisplayIsBuiltin(d[i])) return d[i];
    return 0;
}
static BOOL setRefresh(double hz) {                // mesma resolucao, taxa mais proxima de hz
    CGDirectDisplayID d = builtinDisplay();
    if (!d) return NO;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    if (!cur) return NO;
    BOOL ok = YES;
    if (fabs(CGDisplayModeGetRefreshRate(cur) - hz) > 0.5) {
        NSArray *ms = CFBridgingRelease(CGDisplayCopyAllDisplayModes(d, NULL));
        CGDisplayModeRef best = NULL;
        for (id o in ms) {
            CGDisplayModeRef m = (__bridge CGDisplayModeRef)o;
            if (CGDisplayModeGetWidth(m) != CGDisplayModeGetWidth(cur) || CGDisplayModeGetHeight(m) != CGDisplayModeGetHeight(cur) ||
                CGDisplayModeGetPixelWidth(m) != CGDisplayModeGetPixelWidth(cur) || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
            if (!best || fabs(CGDisplayModeGetRefreshRate(m) - hz) < fabs(CGDisplayModeGetRefreshRate(best) - hz)) best = m;
        }
        CGError e = kCGErrorIllegalArgument;          // permanente (como Ajustes): fica depois que o processo sai
        CGDisplayConfigRef cfg = NULL;
        if (best && fabs(CGDisplayModeGetRefreshRate(best) - hz) <= 0.5 && (e = CGBeginDisplayConfiguration(&cfg)) == kCGErrorSuccess) {
            e = CGConfigureDisplayWithDisplayMode(cfg, d, best, NULL);
            e = e == kCGErrorSuccess ? CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently) : (CGCancelDisplayConfiguration(cfg), e);
        }
        ok = e == kCGErrorSuccess;
        NSLog(@"tela: %.0f Hz -> %.0f Hz: %@", CGDisplayModeGetRefreshRate(cur), hz, ok ? @"ok" : [NSString stringWithFormat:@"erro %d", e]);
    }
    CGDisplayModeRelease(cur);
    return ok;
}
static double currentRefresh(void) {
    CGDirectDisplayID d = builtinDisplay();
    CGDisplayModeRef cur = d ? CGDisplayCopyDisplayMode(d) : NULL;
    double hz = cur ? CGDisplayModeGetRefreshRate(cur) : 0;
    if (cur) CGDisplayModeRelease(cur);
    return hz;
}
static void setBrightness(float v, BOOL onlyLower) {   // DisplayServices (privado, por dlsym)
    static int (*get)(CGDirectDisplayID, float *), (*set)(CGDirectDisplayID, float);
    if (!get) { void *h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
                get = h ? dlsym(h, "DisplayServicesGetBrightness") : NULL; set = h ? dlsym(h, "DisplayServicesSetBrightness") : NULL; }
    CGDirectDisplayID d = builtinDisplay(); float b = -1;
    if (!get || !set || !d || get(d, &b) || fabsf(b - v) < 0.005f || (onlyLower && b <= v)) return;
    int e = set(d, v);
    NSLog(@"tela: brilho %.0f%% -> %.0f%%: %@", b * 100, v * 100, e ? [NSString stringWithFormat:@"erro %d", e] : @"ok");
}
static void kbProfileLight(BOOL bat) {              // luz do teclado: Bateria 25%, Balanceado 50% (nivel do meio)
    kbBattery = bat;
    if (kbLevel != 1) { kbLevel = 1; [prefs setInteger:kbLevel forKey:@"level"]; }
    kbSend(kbPct(kbLevel));
    kbWindowRefresh();
}
static void batteryExtras(int p) {                 // p = perfil novo
    BOOL bat = profileRank(p) == 0;
    if (bat || profileRank(p) == 3) kbProfileLight(bat);              // Bateria 25%, Balanceado 50%
    else if (kbBattery) { kbBattery = NO; if (kbLevel == 1) kbSend(kbPct(1)); kbWindowRefresh(); }
    if (profileRank(p) == 3) setBrightness(0.9f, NO);                 // Balanceado: brilho 90%
    if (bat) {
        double hz = currentRefresh();
        if (hz > 61 && ![prefs objectForKey:@"hzAntesBateria"]) [prefs setDouble:hz forKey:@"hzAntesBateria"];
        setRefresh(60);
        setBrightness(0.5f, YES);
        if (rtxMode() != 0) rtxSetMode(0);
    } else {
        id hz = [prefs objectForKey:@"hzAntesBateria"];
        if (hz) { setRefresh([hz doubleValue]); [prefs removeObjectForKey:@"hzAntesBateria"]; }
        [prefs removeObjectForKey:@"rtxModeAntesBateria"];   // (versao de 11/11 cedo) nao usado mais
        if (rtxMode() == 0) { rtxSetMode(2); rtxPower(onAC()); }
    }
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
    rtxPower(ac);
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
    if ([s isEqualToString:@"kTCCServiceBluetoothAlways"]) return L("o Bluetooth", "Bluetooth");
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
        if ([bid isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {   // o proprio G15 (Bluetooth): reinicia
            NSLog(@"permissao do proprio G15: reiniciando");
            g15Quitting = YES;
            run(@"/bin/sh", @[@"-c", [NSString stringWithFormat:@"sleep 2; /usr/bin/open -g '%@' --args --daemon", NSBundle.mainBundle.bundlePath]]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
            return;
        }
        NSRunningApplication *ra = [NSRunningApplication runningApplicationsWithBundleIdentifier:bid].firstObject;
        if (!ra) { notify(app, [NSString stringWithFormat:L("Acesso a %@ permitido.", "Access to %@ allowed."), tccServiceName(svc)]); return; }
        NSAlert *r = [NSAlert new];                // o app so ve a permissao nova depois de reaberto
        r.messageText = [NSString stringWithFormat:L("Acesso a %@ permitido para “%@”.", "Access to %@ allowed for “%@”."), tccServiceName(svc), app];
        r.informativeText = L("O app só passa a usar a permissão depois de reaberto.", "The app only uses the permission after it is reopened.");
        [r addButtonWithTitle:L("Reabrir agora", "Reopen now")];
        [r addButtonWithTitle:L("Depois", "Later")];
        [NSApp activateIgnoringOtherApps:YES];
        if ([r runModal] != NSAlertFirstButtonReturn) return;
        NSURL *url = ra.bundleURL;
        NSLog(@"reabrindo %@ (%@)", app, bid);
        [ra terminate];
        __block int tries = 0;                     // espera fechar (ate 10 s; depois forca) e abre de novo
        __block void (^wait)(void);
        wait = ^{
            if (!ra.terminated && ++tries < 20) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), wait); return; }
            if (!ra.terminated) [ra forceTerminate];
            NSWorkspaceOpenConfiguration *c = [NSWorkspaceOpenConfiguration configuration];
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:c completionHandler:^(NSRunningApplication *a, NSError *e) {
                if (e) NSLog(@"reabrir %@: %@", bid, e.localizedDescription);
            }];
            wait = nil;
        };
        wait();
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
    if (![svc isEqualToString:@"kTCCServiceMicrophone"] && ![svc isEqualToString:@"kTCCServiceCamera"] &&
        ![svc isEqualToString:@"kTCCServiceBluetoothAlways"]) return;
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
    else NSLog(@"acompanhando os pedidos de microfone/camera/Bluetooth negados pelo tccd");
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

// ---------- janela da luz do teclado ----------
// Desenho do teclado do G15 5530 (4 zonas: esquerda, centro, direita, numerico) com previa ao vivo do efeito, cor por
// zona (NSColorWell ou paleta), efeito e velocidade, brilho, predefinicoes, perfis com nome e o tempo da luz (BIOS,
// pelo G15Fan: KbdTimeout). Tudo em prefs local.g15 (kbLight, kbProfiles, kbProfile).
typedef struct { CGFloat x, y, w, h; const char *t; int z; } KbKey;
static KbKey kbKeys[120]; static int kbNKeys;
static const CGFloat KB_W = 19.6, KB_H = 5.75;     // unidades: area principal 15 + vao 0.6 + numerico 4

static void kbAddRow(CGFloat y, CGFloat h, const char *spec) {   // "rotulo:largura|..." ; largura 0 = 1
    CGFloat x = 0; char buf[400]; strncpy(buf, spec, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    for (char *tok = strtok(buf, "|"); tok; tok = strtok(NULL, "|")) {
        char *c = strrchr(tok, ':'); CGFloat w = 1;
        if (c) { *c = 0; w = atof(c + 1); }
        if (strcmp(tok, "_")) {
            CGFloat cx = x + w / 2;
            kbKeys[kbNKeys] = (KbKey){x, y, w, h, strdup(tok), x >= 15.3 ? 3 : cx < 5.2 ? 0 : cx < 10.2 ? 1 : 2};
            kbNKeys++;
        }
        x += w;
    }
}

static void kbBuildKeys(void) {
    if (kbNKeys) return;
    CGFloat fr = 0.62;                             // linha das F (mais baixa), de cima para baixo
    kbAddRow(0, fr, "esc|F1|F2|F3|F4|F5|F6|F7|F8|F9|F10|F11|F12|prt|ins|_:0.6|del|home|end|pgup");
    CGFloat y = fr + 0.08;
    kbAddRow(y, 1, "'|1|2|3|4|5|6|7|8|9|0|-|=|⌫:2|_:0.6|num|/|*|−");
    kbAddRow(y + 1, 1, "⇥:1.5|Q|W|E|R|T|Y|U|I|O|P|´|[:1.25|↩:1.25|_:0.6|7|8|9|+");
    kbAddRow(y + 2, 1, "⇪:1.75|A|S|D|F|G|H|J|K|L|Ç|~|]|_:1.25|_:0.6|4|5|6");
    kbAddRow(y + 3, 1, "⇧:1.25|\\|Z|X|C|V|B|N|M|,|.|;|⇧:1.75|↑|_:0.6|1|2|3|⏎");
    kbAddRow(y + 4, 1, "ctrl:1.25|fn|❖|alt:1.25|:5.5|alt|ctrl|←|↓|→|_:0.6|0:2|,");
    for (int i = 0; i < kbNKeys; i++)              // Enter (ABNT) e + / Enter do numerico ocupam duas linhas
        if (!strcmp(kbKeys[i].t, "↩") || !strcmp(kbKeys[i].t, "⏎") || (!strcmp(kbKeys[i].t, "+") && kbKeys[i].z == 3)) kbKeys[i].h = 2;
}

static void rgbOf(uint32_t c, CGFloat v[3]) { v[0] = (c >> 16 & 255) / 255.0; v[1] = (c >> 8 & 255) / 255.0; v[2] = (c & 255) / 255.0; }

// cor de uma zona no instante t (s), imitando o controlador: cada acao de transicao vai da cor anterior ate a sua
static void kbPreview(NSDictionary *L, int z, double t, CGFloat out[3]) {
    NSString *fx = L[@"effect"] ?: @"static";
    double dur = KB_DUR[MAX(0, MIN(4, [L[@"speed"] intValue]))] / 1000.0;
    uint32_t seq[7]; int n = 0;
    uint32_t c = kbZoneColor(L, z);
    if ([fx isEqualToString:@"breath"]) { seq[n++] = c; seq[n++] = 0; }
    else if ([fx isEqualToString:@"morph"]) { seq[n++] = c; seq[n++] = hexColor(L[@"color2"]); }
    else if ([fx isEqualToString:@"spectrum"] || [fx isEqualToString:@"wave"]) {
        int sh = [fx isEqualToString:@"wave"] ? z : 0;
        for (int k = 0; k < 7; k++) seq[n++] = KB_RAINBOW[(k - sh + 7) % 7];
    } else { rgbOf(c, out); return; }
    double pos = t / dur; int i = (int)floor(pos) % n; double f = pos - floor(pos);
    f = f * f * (3 - 2 * f);
    CGFloat a[3], b[3]; rgbOf(seq[(i + n - 1) % n], a); rgbOf(seq[i], b);
    for (int k = 0; k < 3; k++) out[k] = a[k] + (b[k] - a[k]) * f;
}

@interface G15KbView : NSView
@property (copy) NSDictionary *light;
@property NSInteger level, selZone;
@property (copy) void (^onZone)(int z);
@end

@implementation G15KbView { NSTimer *_timer; CFTimeInterval _t0; }
- (BOOL)isFlipped { return YES; }
- (void)viewDidMoveToWindow {
    [_timer invalidate]; _timer = nil;
    if (!self.window) return;
    _t0 = NSProcessInfo.processInfo.systemUptime;
    __weak G15KbView *w = self;
    _timer = [NSTimer timerWithTimeInterval:1 / 30.0 repeats:YES block:^(NSTimer *t) {
        G15KbView *s = w; if (!s) { [t invalidate]; return; }
        if (s.window.isVisible && ![s.light[@"effect"] isEqualToString:@"static"] && s.level) s.needsDisplay = YES;
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (NSRect)keyArea {
    NSRect b = NSInsetRect(self.bounds, 34, 26);
    CGFloat u = MIN(b.size.width / KB_W, b.size.height / KB_H);
    return NSMakeRect(NSMidX(b) - u * KB_W / 2, NSMidY(b) - u * KB_H / 2, u * KB_W, u * KB_H);
}
- (NSRect)rectFor:(KbKey)k in:(NSRect)a {
    CGFloat u = a.size.width / KB_W, g = u * 0.09;
    return NSMakeRect(a.origin.x + k.x * u + g / 2, a.origin.y + k.y * u + g / 2, k.w * u - g, k.h * u - g);
}
- (void)drawRect:(NSRect)dirty {
    kbBuildKeys();
    BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
    // chassi: aluminio escuro com borda e brilho em cima
    NSRect ch = NSInsetRect(self.bounds, 6, 6);
    NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:ch xRadius:22 yRadius:22];
    NSGradient *gr = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:dark ? 0.17 : 0.24 alpha:1]
                                                   endingColor:[NSColor colorWithWhite:dark ? 0.09 : 0.14 alpha:1]];
    [gr drawInBezierPath:body angle:90];
    [[NSColor colorWithWhite:1 alpha:0.10] setStroke]; body.lineWidth = 1; [body stroke];

    NSRect a = [self keyArea];
    CGFloat u = a.size.width / KB_W;
    double t = NSProcessInfo.processInfo.systemUptime - _t0;
    CGFloat lv = self.level == 0 ? 0 : self.level == 1 ? 0.55 : 1;
    CGFloat zc[4][3];
    for (int z = 0; z < 4; z++) kbPreview(self.light, z, t, zc[z]);
    NSFont *f = [NSFont systemFontOfSize:MAX(7, u * 0.25) weight:NSFontWeightMedium];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
    for (int i = 0; i < kbNKeys; i++) {
        KbKey k = kbKeys[i];
        NSRect r = [self rectFor:k in:a];
        CGFloat *c = zc[k.z];
        NSColor *glow = [NSColor colorWithSRGBRed:c[0] green:c[1] blue:c[2] alpha:1];
        NSBezierPath *kp = [NSBezierPath bezierPathWithRoundedRect:r xRadius:u * 0.14 yRadius:u * 0.14];
        [NSGraphicsContext saveGraphicsState];
        if (lv > 0) {                              // brilho da luz vazando em volta da tecla
            NSShadow *sh = [NSShadow new];
            sh.shadowColor = [glow colorWithAlphaComponent:0.85 * lv]; sh.shadowBlurRadius = u * 0.35; sh.shadowOffset = NSZeroSize;
            [sh set];
        }
        [[NSColor colorWithWhite:0.07 alpha:1] setFill]; [kp fill];
        [NSGraphicsContext restoreGraphicsState];
        NSGradient *kg = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.20 alpha:1] endingColor:[NSColor colorWithWhite:0.11 alpha:1]];
        [kg drawInBezierPath:kp angle:-90];
        if (lv > 0) { [[glow colorWithAlphaComponent:0.30 * lv] setFill]; [kp fill]; }
        NSColor *tc = lv > 0 ? [NSColor colorWithSRGBRed:0.35 + 0.65 * c[0] green:0.35 + 0.65 * c[1] blue:0.35 + 0.65 * c[2] alpha:0.35 + 0.65 * lv]
                             : [NSColor colorWithWhite:0.45 alpha:1];
        NSString *s = [NSString stringWithUTF8String:k.t];
        NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: tc, NSParagraphStyleAttributeName: ps};
        NSSize sz = [s sizeWithAttributes:at];
        [s drawInRect:NSMakeRect(r.origin.x, NSMidY(r) - sz.height / 2, r.size.width, sz.height) withAttributes:at];
    }
    if ([self.light[@"zones"] intValue] == 4 && self.selZone >= 0) {   // zona escolhida: contorno na cor de destaque
        NSRect zr = NSZeroRect;
        for (int i = 0; i < kbNKeys; i++) if (kbKeys[i].z == self.selZone) zr = NSIsEmptyRect(zr) ? [self rectFor:kbKeys[i] in:a] : NSUnionRect(zr, [self rectFor:kbKeys[i] in:a]);
        NSBezierPath *zp = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(zr, -u * 0.12, -u * 0.12) xRadius:u * 0.25 yRadius:u * 0.25];
        zp.lineWidth = 2; [[NSColor.controlAccentColor colorWithAlphaComponent:0.95] setStroke]; [zp stroke];
    }
}
- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect a = [self keyArea];
    for (int i = 0; i < kbNKeys; i++)
        if (NSPointInRect(p, NSInsetRect([self rectFor:kbKeys[i] in:a], -3, -3))) { if (self.onZone) self.onZone(kbKeys[i].z); return; }
}
@end

static NSString *hexOf(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.whiteColor;
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)lround(s.redComponent * 255), (int)lround(s.greenComponent * 255), (int)lround(s.blueComponent * 255)];
}
static NSColor *colorOf(uint32_t c) { CGFloat v[3]; rgbOf(c, v); return [NSColor colorWithSRGBRed:v[0] green:v[1] blue:v[2] alpha:1]; }

// predefinicoes: nome, efeito ("off" = apaga a luz)
static NSArray<NSArray *> *kbPresets(void) {
    NSDictionary *(^S)(NSString *, int, NSArray *) = ^(NSString *fx, int zones, NSArray *cs) {
        return @{@"effect": fx, @"zones": @(zones), @"colors": cs.count == 4 ? cs : @[cs[0], cs[0], cs[0], cs[0]], @"color2": @"000000", @"speed": @2};
    };
    return @[@[L("Branco", "White"), S(@"static", 1, @[@"FFFFFF"])],
             @[@"Alienware", S(@"static", 1, @[@"00A6FF"])],
             @[L("Vermelho", "Red"), S(@"static", 1, @[@"FF1A1A"])],
             @[L("Roxo", "Purple"), S(@"static", 1, @[@"8A2BE2"])],
             @[@"Aurora", S(@"static", 4, @[@"00FFC8", @"00A0FF", @"7040FF", @"FF40C0"])],
             @[L("Pôr do sol", "Sunset"), S(@"static", 4, @[@"FF1500", @"FF5A00", @"FFA000", @"FF0060"])],
             @[L("Respiração", "Breathing"), S(@"breath", 1, @[@"00A6FF"])],
             @[L("Espectro", "Spectrum"), S(@"spectrum", 1, @[@"FFFFFF"])],
             @[L("Onda", "Wave"), S(@"wave", 4, @[@"FFFFFF"])],
             @[L("Apagada", "Off"), @"off"]];
}

static NSImage *presetImage(id p) {
    return [NSImage imageWithSize:NSMakeSize(34, 34) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSRect c = NSInsetRect(r, 2, 2);
        NSBezierPath *o = [NSBezierPath bezierPathWithOvalInRect:c];
        if (![p isKindOfClass:NSDictionary.class]) {
            [[NSColor colorWithWhite:0.15 alpha:1] setFill]; [o fill];
            [[NSColor colorWithWhite:0.5 alpha:1] setStroke]; [o stroke];
            return YES;
        }
        NSString *fx = p[@"effect"];
        [NSGraphicsContext saveGraphicsState]; [o addClip];
        if ([fx isEqualToString:@"spectrum"] || [fx isEqualToString:@"wave"]) {
            NSMutableArray *cs = [NSMutableArray array]; for (int k = 0; k < 7; k++) [cs addObject:colorOf(KB_RAINBOW[k])];
            [[[NSGradient alloc] initWithColors:cs] drawInRect:c angle:[fx isEqualToString:@"wave"] ? 0 : 90];
        } else if ([fx isEqualToString:@"breath"]) {
            [[[NSGradient alloc] initWithStartingColor:colorOf(kbZoneColor(p, 0)) endingColor:NSColor.blackColor] drawInBezierPath:o relativeCenterPosition:NSZeroPoint];
        } else if ([p[@"zones"] intValue] == 4) {
            for (int z = 0; z < 4; z++) { [colorOf(kbZoneColor(p, z)) setFill]; NSRectFill(NSMakeRect(c.origin.x + z * c.size.width / 4, c.origin.y, c.size.width / 4 + 0.5, c.size.height)); }
        } else { [colorOf(kbZoneColor(p, 0)) setFill]; [o fill]; }
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithWhite:1 alpha:0.25] setStroke]; [o stroke];
        return YES;
    }];
}

@interface G15KbWindow : NSObject <NSWindowDelegate>
@end

@implementation G15KbWindow {
    NSWindow *_w; G15KbView *_kb; NSMutableDictionary *_cur; NSInteger _zone;
    NSSegmentedControl *_zonesSeg, *_zoneSeg, *_levelSeg;
    NSColorWell *_well, *_well2; NSTextField *_well2Label; NSPopUpButton *_fx, *_tmo, *_prof; NSSlider *_speed;
    NSButton *_del;
}

static G15KbWindow *kbWin;

- (NSTextField *)label:(NSString *)s at:(NSPoint)p in:(NSView *)v {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; l.textColor = NSColor.secondaryLabelColor;
    [l sizeToFit]; [l setFrameOrigin:p]; [v addSubview:l];
    return l;
}
- (NSBox *)card:(NSRect)r in:(NSView *)v {
    NSBox *b = [[NSBox alloc] initWithFrame:r];
    b.boxType = NSBoxCustom; b.cornerRadius = 12; b.borderWidth = 0; b.titlePosition = NSNoTitle;
    b.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.05]; b.contentViewMargins = NSZeroSize;
    [v addSubview:b];
    return b;
}

- (void)build {
    _w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 610)
                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                       backing:NSBackingStoreBuffered defer:NO];
    _w.titlebarAppearsTransparent = YES; _w.titleVisibility = NSWindowTitleHidden; _w.movableByWindowBackground = YES;
    _w.releasedWhenClosed = NO; _w.delegate = self; _w.title = L("Luz do teclado", "Keyboard light");
    NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 800, 610)];
    v.material = NSVisualEffectMaterialSidebar; v.blendingMode = NSVisualEffectBlendingModeBehindWindow; v.state = NSVisualEffectStateActive;
    _w.contentView = v;

    NSTextField *t = [NSTextField labelWithString:L("Luz do teclado", "Keyboard light")];
    t.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold]; [t sizeToFit]; [t setFrameOrigin:NSMakePoint(28, 552)]; [v addSubview:t];
    NSTextField *st = [NSTextField labelWithString:@"Dell G15 5530 · Alienware AW-ELC · 4 zonas"];
    st.font = [NSFont systemFontOfSize:12]; st.textColor = NSColor.secondaryLabelColor; [st sizeToFit];
    [st setFrameOrigin:NSMakePoint(30, 534)]; [v addSubview:st];

    _kb = [[G15KbView alloc] initWithFrame:NSMakeRect(20, 270, 760, 256)];
    __weak G15KbWindow *ws = self;
    _kb.onZone = ^(int z) { [ws pickZone:z]; };
    [v addSubview:_kb];

    _zonesSeg = [NSSegmentedControl segmentedControlWithLabels:@[L("1 zona", "1 zone"), L("4 zonas", "4 zones")]
                                                  trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(zonesChanged:)];
    _zonesSeg.frame = NSMakeRect(28, 230, 170, 26); [v addSubview:_zonesSeg];
    _zoneSeg = [NSSegmentedControl segmentedControlWithLabels:@[L("Esquerda", "Left"), L("Centro", "Center"), L("Direita", "Right"), L("Numérico", "Numpad")]
                                                 trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(zoneChanged:)];
    _zoneSeg.frame = NSMakeRect(212, 230, 360, 26); [v addSubview:_zoneSeg];
    NSTextField *hint = [self label:L("ou clique numa zona do desenho", "or click a zone in the drawing") at:NSMakePoint(584, 235) in:v];
    hint.font = [NSFont systemFontOfSize:11];

    NSBox *ca = [self card:NSMakeRect(24, 96, 370, 120) in:v]; NSView *a = ca.contentView;
    [self label:L("Cor", "Color") at:NSMakePoint(16, 86) in:a];
    _well = [NSColorWell colorWellWithStyle:NSColorWellStyleExpanded];
    _well.frame = NSMakeRect(78, 80, 64, 28); _well.target = self; _well.action = @selector(colorChanged:); [a addSubview:_well];
    const uint32_t pal[8] = {0xFFFFFF, 0x00A6FF, 0x0040FF, 0x8A2BE2, 0xFF1A1A, 0xFF7A00, 0xFFD000, 0x00E060};
    for (int i = 0; i < 8; i++) {
        NSButton *b = [NSButton buttonWithImage:presetImage(@{@"effect": @"static", @"zones": @1, @"colors": @[[NSString stringWithFormat:@"%06X", pal[i]], @"", @"", @""]})
                                         target:self action:@selector(paletteClicked:)];
        b.bordered = NO; b.imageScaling = NSImageScaleProportionallyDown; b.tag = pal[i];
        b.frame = NSMakeRect(152 + i * 26, 82, 24, 24); [a addSubview:b];
    }
    [self label:L("Efeito", "Effect") at:NSMakePoint(16, 50) in:a];
    _fx = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(74, 44, 150, 26) pullsDown:NO];
    [_fx addItemsWithTitles:@[L("Fixo", "Static"), L("Respiração", "Breathing"), L("Transição", "Morph"), L("Espectro", "Spectrum"), L("Onda", "Wave")]];
    _fx.target = self; _fx.action = @selector(fxChanged:); [a addSubview:_fx];
    _well2Label = [self label:L("2ª cor", "2nd color") at:NSMakePoint(236, 50) in:a];
    _well2 = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
    _well2.frame = NSMakeRect(290, 44, 60, 26); _well2.target = self; _well2.action = @selector(color2Changed:); [a addSubview:_well2];
    [self label:L("Velocidade", "Speed") at:NSMakePoint(16, 14) in:a];
    _speed = [NSSlider sliderWithValue:2 minValue:0 maxValue:4 target:self action:@selector(speedChanged:)];
    _speed.numberOfTickMarks = 5; _speed.allowsTickMarkValuesOnly = YES; _speed.frame = NSMakeRect(100, 8, 250, 26); [a addSubview:_speed];

    NSBox *cb = [self card:NSMakeRect(406, 96, 370, 120) in:v]; NSView *b = cb.contentView;
    [self label:L("Brilho", "Brightness") at:NSMakePoint(16, 86) in:b];
    _levelSeg = [NSSegmentedControl segmentedControlWithLabels:@[L("Apagada", "Off"), @"50%", @"100%"]
                                                  trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(levelChanged:)];
    _levelSeg.frame = NSMakeRect(110, 80, 240, 26); [b addSubview:_levelSeg];
    [self label:L("Apagar após", "Turn off after") at:NSMakePoint(16, 50) in:b];
    _tmo = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 44, 150, 26) pullsDown:NO];
    const int ts[8] = {5, 10, 15, 30, 60, 300, 900, 0};
    for (int i = 0; i < 8; i++) {
        int s = ts[i];
        [_tmo addItemWithTitle:s == 0 ? L("Nunca", "Never") : s < 60 ? [NSString stringWithFormat:@"%d s", s] : [NSString stringWithFormat:@"%d min", s / 60]];
        _tmo.lastItem.tag = s;
    }
    _tmo.target = self; _tmo.action = @selector(timeoutChanged:); [b addSubview:_tmo];
    [self label:L("Perfil", "Profile") at:NSMakePoint(16, 14) in:b];
    _prof = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(66, 8, 150, 26) pullsDown:NO];
    _prof.target = self; _prof.action = @selector(profilePicked:); [b addSubview:_prof];
    NSButton *sv = [NSButton buttonWithTitle:L("Salvar…", "Save…") target:self action:@selector(profileSave:)];
    sv.frame = NSMakeRect(220, 8, 74, 26); [b addSubview:sv];
    _del = [NSButton buttonWithTitle:L("Apagar", "Delete") target:self action:@selector(profileDelete:)];
    _del.frame = NSMakeRect(294, 8, 68, 26); [b addSubview:_del];

    NSTextField *pt = [self label:L("PREDEFINIÇÕES", "PRESETS") at:NSMakePoint(30, 70) in:v];
    pt.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    NSArray *ps = kbPresets();
    for (NSUInteger i = 0; i < ps.count; i++) {
        NSButton *p = [NSButton buttonWithTitle:ps[i][0] image:presetImage(ps[i][1]) target:self action:@selector(presetClicked:)];
        p.imagePosition = NSImageAbove; p.bordered = NO; p.tag = i; p.font = [NSFont systemFontOfSize:11];
        p.frame = NSMakeRect(24 + i * 75.2, 12, 72, 56); [v addSubview:p];
    }
    [_w center];
}

- (void)sync {                                     // controles a partir do estado
    _cur = [kbLight() mutableCopy]; _cur[@"colors"] = [_cur[@"colors"] mutableCopy];
    BOOL four = [_cur[@"zones"] intValue] == 4;
    _zonesSeg.selectedSegment = four; _zoneSeg.enabled = four; _zoneSeg.selectedSegment = four ? _zone : -1;
    _well.color = colorOf(kbZoneColor(_cur, four ? (int)_zone : 0));
    _well2.color = colorOf(hexColor(_cur[@"color2"]));
    NSUInteger fi = [kbEffects() indexOfObject:_cur[@"effect"]]; [_fx selectItemAtIndex:fi == NSNotFound ? 0 : fi];
    NSString *fx = _cur[@"effect"];
    BOOL rainbow = [fx isEqualToString:@"spectrum"] || [fx isEqualToString:@"wave"];
    _well.enabled = !rainbow; _well2.hidden = _well2Label.hidden = ![fx isEqualToString:@"morph"];
    _speed.doubleValue = [_cur[@"speed"] intValue]; _speed.enabled = ![fx isEqualToString:@"static"];
    _levelSeg.selectedSegment = kbLevel;
    _kb.light = _cur; _kb.level = kbLevel; _kb.selZone = _zone; _kb.needsDisplay = YES;
    // perfis
    NSDictionary *pr = [prefs dictionaryForKey:@"kbProfiles"];
    [_prof removeAllItems]; [_prof addItemWithTitle:L("Personalizado", "Custom")];
    for (NSString *n in [pr.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) [_prof addItemWithTitle:n];
    NSString *sel = [prefs stringForKey:@"kbProfile"];
    if (sel && pr[sel] && [pr[sel] isEqual:kbLight()]) [_prof selectItemWithTitle:sel]; else [_prof selectItemAtIndex:0];
    _del.enabled = _prof.indexOfSelectedItem > 0;
    // tempo da luz (BIOS, pelo G15Fan)
    NSDictionary *kt = fanState(NO)[@"KbdTimeout"];
    _tmo.enabled = [kt isKindOfClass:NSDictionary.class];
    _tmo.toolTip = _tmo.enabled ? L("Tempo sem usar o teclado até a luz apagar (BIOS, na bateria e na tomada)", "Idle time until the light turns off (BIOS)")
                                : L("Precisa do G15Fan.kext com o tempo da luz", "Needs the G15Fan.kext with keyboard timeout");
    if (_tmo.enabled) [_tmo selectItemWithTag:[kt[@"Batt"] intValue]];
}

- (void)commit {                                   // grava, redesenha e manda ao controlador
    [prefs setObject:_cur forKey:@"kbLight"];
    [self sync];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(send) object:nil];
    [self performSelector:@selector(send) withObject:nil afterDelay:0.12 inModes:@[NSRunLoopCommonModes]];
}
- (void)send { if (kbLevel == 0) kbSet(2, NO); kbApply(); }   // escolher uma cor com a luz apagada acende

- (void)toFour {                                   // 1 -> 4 zonas: as quatro comecam na cor unica
    NSString *c = _cur[@"colors"][0];
    _cur[@"colors"] = [@[c, c, c, c] mutableCopy]; _cur[@"zones"] = @4;
}
- (void)pickZone:(int)z {                          // clique no desenho: escolhe a zona (e passa para 4 zonas)
    _zone = z;
    if ([_cur[@"zones"] intValue] != 4) { [self toFour]; [self commit]; } else [self sync];
}
- (void)zonesChanged:(NSSegmentedControl *)s {
    if (s.selectedSegment == 1) { if ([_cur[@"zones"] intValue] != 4) [self toFour]; } else _cur[@"zones"] = @1;
    [self commit];
}
- (void)zoneChanged:(NSSegmentedControl *)s { _zone = s.selectedSegment; [self sync]; }
- (void)setColorHex:(NSString *)h {
    NSMutableArray *cs = _cur[@"colors"];
    if ([_cur[@"zones"] intValue] == 4) cs[_zone] = h; else for (int z = 0; z < 4; z++) cs[z] = h;
    if ([_cur[@"effect"] isEqualToString:@"spectrum"] || [_cur[@"effect"] isEqualToString:@"wave"]) _cur[@"effect"] = @"static";
    [self commit];
}
- (void)colorChanged:(NSColorWell *)w { [self setColorHex:hexOf(w.color)]; }
- (void)paletteClicked:(NSButton *)b { [self setColorHex:[NSString stringWithFormat:@"%06lX", (long)b.tag]]; }
- (void)color2Changed:(NSColorWell *)w { _cur[@"color2"] = hexOf(w.color); [self commit]; }
- (void)fxChanged:(NSPopUpButton *)p { _cur[@"effect"] = kbEffects()[p.indexOfSelectedItem]; [self commit]; }
- (void)speedChanged:(NSSlider *)s {
    if ([_cur[@"speed"] intValue] == (int)lround(s.doubleValue)) return;
    _cur[@"speed"] = @((int)lround(s.doubleValue)); [self commit];
}
- (void)levelChanged:(NSSegmentedControl *)s { kbSet(s.selectedSegment, NO); }
- (void)timeoutChanged:(NSPopUpButton *)p {
    if (fanWrite(@{@"KbdTimeout": @(p.selectedTag)}) != KERN_SUCCESS) NSBeep();
    [self sync];
}
- (void)presetClicked:(NSButton *)b {
    id p = kbPresets()[b.tag][1];
    if (![p isKindOfClass:NSDictionary.class]) { kbSet(0, NO); return; }
    _cur = [p mutableCopy]; _cur[@"colors"] = [p[@"colors"] mutableCopy]; _cur[@"speed"] = _cur[@"speed"] ?: @2;
    _zone = 0; [self commit];
}
- (void)profilePicked:(NSPopUpButton *)p {
    if (p.indexOfSelectedItem <= 0) { [prefs removeObjectForKey:@"kbProfile"]; [self sync]; return; }
    NSDictionary *pr = [prefs dictionaryForKey:@"kbProfiles"][p.titleOfSelectedItem];
    if (!pr) return;
    [prefs setObject:p.titleOfSelectedItem forKey:@"kbProfile"];
    _cur = [pr mutableCopy]; _cur[@"colors"] = [pr[@"colors"] mutableCopy]; [self commit];
}
- (void)profileSave:(id)s {
    NSAlert *a = [NSAlert new];
    a.messageText = L("Salvar perfil de luz", "Save light profile");
    a.informativeText = L("Nome do perfil (o mesmo nome substitui o anterior):", "Profile name (same name replaces it):");
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    f.placeholderString = L("Ex.: Jogo, Noite", "e.g. Gaming, Night");
    NSString *cur = [prefs stringForKey:@"kbProfile"]; if (cur) f.stringValue = cur;
    a.accessoryView = f;
    [a addButtonWithTitle:L("Salvar", "Save")]; [a addButtonWithTitle:L("Cancelar", "Cancel")];
    a.window.initialFirstResponder = f;
    [a beginSheetModalForWindow:_w completionHandler:^(NSModalResponse r) {
        NSString *n = [f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (r != NSAlertFirstButtonReturn || !n.length) return;
        NSMutableDictionary *pr = [[prefs dictionaryForKey:@"kbProfiles"] mutableCopy] ?: [NSMutableDictionary dictionary];
        pr[n] = [self->_cur copy];
        [prefs setObject:pr forKey:@"kbProfiles"]; [prefs setObject:n forKey:@"kbProfile"];
        NSLog(@"luz: perfil \"%@\" salvo", n);
        [self sync];
    }];
}
- (void)profileDelete:(id)s {
    NSString *n = _prof.titleOfSelectedItem; if (_prof.indexOfSelectedItem <= 0) return;
    NSMutableDictionary *pr = [[prefs dictionaryForKey:@"kbProfiles"] mutableCopy];
    [pr removeObjectForKey:n]; [prefs setObject:pr forKey:@"kbProfiles"]; [prefs removeObjectForKey:@"kbProfile"];
    [self sync];
}
@end

static void kbWindowOpen(void) {
    if (!kbWin) { kbWin = [G15KbWindow new]; [kbWin build]; }
    [kbWin sync];
    [NSApp activateIgnoringOtherApps:YES];
    [[kbWin valueForKey:@"_w"] makeKeyAndOrderFront:nil];
}
static void kbWindowRefresh(void) { if (kbWin) [kbWin sync]; }

// ---------- Bluetooth automatico (#87, 10/11) ----------
// Com o BT ligado o pacote nao passa de PC2 (NOT_L1 do CNVi) e o G15 gasta ~7-10 W a mais parado. Se o BT ficar ligado
// sem nenhum aparelho conectado por 3 min (1 min no perfil Bateria, 11/11), o app desliga o BT (preferencia "btAuto",
// padrao ligada; seletor no painel).
// Estado e aparelhos: system_profiler SPBluetoothDataType -json (sem permissao, ~0,2 s, fora da thread principal, a
// cada 15 s). Ligar/desligar: IOBluetoothPreferenceSetControllerPowerState (IOBluetooth, por dlsym; o macOS pede a
// permissao de Bluetooth ao G15 na 1a vez: NSBluetoothAlwaysUsageDescription no Info.plist).
static int btLimit(void);                         // 60 s no perfil Bateria, senao 180 s
static int btOn = -1, btConnected = -1;             // -1 = ainda nao lido
static NSArray<NSString *> *btNames;               // aparelhos conectados
static int btIdleSecs;
static BOOL btBusy;
static dispatch_queue_t btq;
static BOOL btAuto(void) { id v = [prefs objectForKey:@"btAuto"]; return v ? [v boolValue] : YES; }
static void btRead(void (^done)(void)) {           // assincrono; done roda na thread principal
    if (btBusy) {                                  // leitura em curso: tenta de novo em 1 s (nao perde o "done")
        if (done) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ btRead(done); });
        return;
    }
    btBusy = YES;
    if (!btq) btq = dispatch_queue_create("g15.bt", DISPATCH_QUEUE_SERIAL);
    dispatch_async(btq, ^{
        NSTask *t = [NSTask new]; NSPipe *p = [NSPipe pipe];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/system_profiler"];
        t.arguments = @[@"SPBluetoothDataType", @"-json"]; t.standardOutput = p; t.standardError = NSFileHandle.fileHandleWithNullDevice;
        int on = -1, n = -1; NSMutableArray *names = [NSMutableArray array];
        if ([t launchAndReturnError:nil]) {
            NSData *d = [p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            NSDictionary *bt = [j[@"SPBluetoothDataType"] firstObject];
            NSString *s = bt[@"controller_properties"][@"controller_state"];
            if (s) on = [s isEqualToString:@"attrib_on"];
            NSArray *c = bt[@"device_connected"];
            n = (int)c.count;
            for (NSDictionary *e in c) [names addObjectsFromArray:e.allKeys];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ btOn = on; btConnected = n; btNames = names; btBusy = NO; if (done) done(); });
    });
}
static void btSetPower(BOOL on, const char *why) {  // fora da thread principal: a 1a chamada pode esperar a permissao
    if (!btq) btq = dispatch_queue_create("g15.bt", DISPATCH_QUEUE_SERIAL);
    dispatch_async(btq, ^{
        void (*set)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "IOBluetoothPreferenceSetControllerPowerState");
        if (!set) { void *h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY);
                    set = h ? (void (*)(int))dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") : NULL; }
        if (set) set(on ? 1 : 0);
        NSLog(@"Bluetooth %s (%s): %s", on ? "ligar" : "desligar", why, set ? "pedido" : "sem a funcao do IOBluetooth");
        sleep(2);                                  // confere: o bluetoothd ignora o pedido sem a permissao de Bluetooth
        dispatch_async(dispatch_get_main_queue(), ^{ btIdleSecs = 0; btRead(^{
            if (g15Quitting) return;
            if (btOn == (on ? 1 : 0)) {
                NSLog(@"Bluetooth %s", on ? "ligado" : "desligado");
                if (!on && strcmp(why, "painel"))
                    notify(@"Bluetooth", btLimit() <= 60 ? L("Desligado: 1 minuto sem aparelhos conectados (perfil Bateria).", "Turned off: no devices connected for 1 minute (Battery profile).")
                                                         : L("Desligado: 3 minutos sem aparelhos conectados.", "Turned off: no devices connected for 3 minutes."));
            } else {
                NSLog(@"Bluetooth continua %s: pedido ignorado (permissao de Bluetooth do G15?)", btOn == 1 ? "ligado" : "desligado");
                notify(@"Bluetooth", L("Não consegui mudar o Bluetooth: o G15 precisa da permissão de Bluetooth.",
                                       "Could not change Bluetooth: G15 needs the Bluetooth permission."));
            }
        }); });
    });
}
static int curProfile = -1;                        // ultimo perfil lido pelo tick
static int btLimit(void) { return curProfile >= 0 && profileRank(curProfile) == 0 ? 60 : 180; }
static void btTick(int secs) {                     // chamado a cada 15 s pelo tick
    btRead(^{
        if (btOn != 1 || btConnected != 0 || !btAuto()) { btIdleSecs = 0; return; }
        btIdleSecs += secs;
        if (btIdleSecs >= btLimit()) btSetPower(NO, btLimit() <= 60 ? "1 min sem aparelhos (Bateria)" : "3 min sem aparelhos");
    });
}

@class G15Panel;
static G15Panel *panel;
static void rtxSetMode(int m);
static void panelToggle(NSStatusBarButton *b);

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
    if (st[@"Profile"]) {
        curProfile = [st[@"Profile"] intValue];
        rtxDenySync(profileRank(curProfile) == 0);
        if (profileApplied < 0) profileApplied = curProfile;          // ao abrir: so acompanha (nao mexe na luz)
        else if (profileApplied != curProfile) {                       // trocado por fora (G15 --perfil): luz do teclado
            profileApplied = curProfile;
            int rk = profileRank(curProfile);
            if (rk == 0 || rk == 3) kbProfileLight(rk == 0);
        }
        BOOL kb = profileRank(curProfile) == 0;
        if (kb != kbBattery) { kbBattery = kb; if (kbLevel == 1) kbSend(kbPct(1)); kbWindowRefresh(); }
    }
    rtxTick(st, onAC());
    static int n; if (n++ % 3 == 0) btTick(15);       // Bluetooth a cada 15 s
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

        if (st[@"RtxParked"]) {                     // G15Fan com RtxPm: seletor RTX ( Desligada | Ligada | Automática )
            [menu addItem:NSMenuItem.separatorItem];
            NSMenuItem *ri = [NSMenuItem new];
            NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 30)];
            NSTextField *lb = [NSTextField labelWithString:@"RTX"];
            lb.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; lb.frame = NSMakeRect(16, 6, 36, 18);
            NSSegmentedControl *sc = [NSSegmentedControl segmentedControlWithLabels:@[L("Desligada", "Off"), L("Ligada", "On"), L("Automática", "Auto")]
                                                                    trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(rtxMode:)];
            sc.frame = NSMakeRect(52, 3, 236, 24); sc.controlSize = NSControlSizeSmall; sc.font = [NSFont systemFontOfSize:11];
            sc.selectedSegment = rtxMode();
            sc.toolTip = [st[@"RtxParked"] boolValue] ? L("Agora: desligada", "Now: off") : L("Agora: ligada", "Now: on");
            [v addSubview:lb]; [v addSubview:sc];
            ri.view = v; [menu addItem:ri];
        }
    }

    {   // luz do teclado: abre a janela (cores, zonas, efeitos, perfis); o Fn+F5 continua no brilho
        NSDictionary *Lt = kbLight();
        NSArray *fxn = @[L("fixa", "static"), L("respiração", "breathing"), L("transição", "morph"), L("espectro", "spectrum"), L("onda", "wave")];
        NSUInteger fi = [kbEffects() indexOfObject:Lt[@"effect"]];
        NSString *st = kbLevel ? [NSString stringWithFormat:@"%d%% · %@", kbPct(kbLevel), fxn[fi == NSNotFound ? 0 : fi]] : L("apagada", "off");
        NSMenuItem *ki = [self add:menu title:[NSString stringWithFormat:L("Luz do teclado: %@…", "Keyboard light: %@…"), st] action:@selector(openKb:) tag:0 on:NO];
        ki.image = [NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:nil];
    }

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
                                  [p.lastObject isEqualToString:@"kTCCServiceCamera"] ? L("câmera", "camera") : [p.lastObject isEqualToString:@"kTCCServiceBluetoothAlways"] ? @"Bluetooth" : L("microfone", "microphone"),
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
- (void)rtxMode:(NSSegmentedControl *)sc { rtxSetMode((int)sc.selectedSegment); }
@end
static void rtxSetMode(int m) {
    [[NSUserDefaults standardUserDefaults] setInteger:m forKey:@"rtxMode"];
    rtxIdleTicks = 0;
    BOOL parked = [fanState(NO)[@"RtxParked"] boolValue];
    NSLog(@"RTX: modo %d", m);
    if (m == 1 && parked) rtxSet(YES, "modo ligada");
    else if (m == 0 && !parked) {
        if (!rtxIdleNow(fanState(NO)) || rtxExternal())
            notify(@"RTX", L("Em uso (programa ou monitor externo): desliga quando ficar ociosa.", "In use (app or external display): turns off when idle."));
        else rtxSet(NO, "modo desligada");
    }
}
@interface G15Menu (Acoes)
@end
@implementation G15Menu (Acoes)
- (void)setProfile:(NSMenuItem *)i { applyProfile((int)i.tag); }
- (void)openKb:(id)s { kbWindowOpen(); }
- (void)openLog:(id)s {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/g15.log"]]];
}
- (void)tccForget:(id)s { [prefs removeObjectForKey:@"tccDecisions"]; [tccSeen removeAllObjects]; NSLog(@"respostas de permissao esquecidas"); }
- (void)quit:(id)s { [NSApp terminate:nil]; }      // saida normal: o LaunchAgent nao relanca ate o proximo login
- (void)clicked:(NSStatusBarButton *)b {          // esquerdo: painel; direito (ou ctrl): menu classico
    NSEvent *e = NSApp.currentEvent;
    if (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl)) {
        NSMenu *m = [NSMenu new]; m.delegate = self; self.item.menu = m;
        [b performClick:nil];
        self.item.menu = nil;
    } else panelToggle(b);
}
@end

// ---------- painel (10/11): popover no estilo da Central de Controle ----------
// Clique esquerdo no icone abre; direito abre o menu classico. Cartoes: temperaturas/RPM, perfil, ventoinhas, RTX,
// Bluetooth (ligado/desligado e o automatico de 3 min), luz do teclado (brilho + janela de cores) e supressor do mic.
// Enquanto aberto, atualiza a cada 2 s.
static NSColor *cardFill(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        BOOL dark = [[a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithWhite:1 alpha:0.07] : [NSColor colorWithWhite:0 alpha:0.045];
    }];
}
static NSTextField *lbl(NSString *s, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:s ?: @""];
    t.font = [NSFont systemFontOfSize:size weight:w]; t.textColor = c ?: NSColor.labelColor;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}
static NSImageView *sym(NSString *name, CGFloat size, NSColor *tint) {
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    i = [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium]];
    NSImageView *v = [NSImageView imageViewWithImage:i ?: [NSImage new]];
    v.contentTintColor = tint ?: NSColor.secondaryLabelColor;
    [v setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return v;
}
static NSStackView *hstack(NSArray<NSView *> *v, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:v];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal; s.spacing = spacing; s.alignment = NSLayoutAttributeCenterY;
    return s;
}
static NSStackView *vstack(NSArray<NSView *> *v, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:v];
    s.orientation = NSUserInterfaceLayoutOrientationVertical; s.spacing = spacing; s.alignment = NSLayoutAttributeLeading;
    return s;
}
static NSView *spacer(void) {
    NSView *v = [NSView new];
    [v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return v;
}
static NSBox *card(NSView *content) {
    NSBox *b = [NSBox new];
    b.boxType = NSBoxCustom; b.borderWidth = 0; b.cornerRadius = 12; b.fillColor = cardFill();
    b.titlePosition = NSNoTitle; b.contentViewMargins = NSMakeSize(12, 10);
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [b.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:b.contentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:b.contentView.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:b.contentView.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:b.contentView.bottomAnchor]]];
    return b;
}
// cabecalho de cartao: icone, titulo e um valor a direita
static NSStackView *head(NSString *symbol, NSString *title, NSTextField *value) {
    NSStackView *h = hstack(@[sym(symbol, 13, NSColor.controlAccentColor), lbl(title, 13, NSFontWeightSemibold, nil), spacer(), value], 7);
    return h;
}

@interface G15Panel : NSObject <NSPopoverDelegate>
@property NSPopover *pop;
- (void)refresh;
@end

@implementation G15Panel {
    NSTextField *_cpuT, *_rtxT, *_rpmT, *_hzT, *_btAutoL, *_rtxCap, *_profV, *_fanV, *_rtxV, *_btV, *_kbV, *_micV, *_sub;
    NSView *_rtxDot;
    NSSegmentedControl *_profSeg, *_fanSeg, *_rtxSeg, *_kbSeg;
    NSArray<NSNumber *> *_profIds;
    NSSwitch *_btPower, *_btAutoSw;
    NSSlider *_mic;
    NSButton *_perm;
    NSBox *_rtxCard;
    NSTextField *_appV, *_appInfo; NSButton *_bgBtn; NSImageView *_appIcon; NSBox *_appCard; pid_t _bgShownPid; NSString *_bgShownName;
    NSTimer *_timer;
}
- (NSView *)tile:(NSString *)symbol value:(NSTextField *)v caption:(NSTextField *)c {
    v.font = [NSFont monospacedDigitSystemFontOfSize:17 weight:NSFontWeightSemibold];   // 4 quadros: 17 cabe "2550"
    NSStackView *s = vstack(@[hstack(@[sym(symbol, 12, nil), c], 4), v], 2);
    return card(s);
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    const CGFloat W = 340;
    // topo
    _sub = lbl(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSImageView *logo = sym(@"laptopcomputer", 18, NSColor.controlAccentColor);
    NSStackView *title = vstack(@[lbl(@"Dell G15", 15, NSFontWeightBold, nil), _sub], 0);
    NSButton *more = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis.circle" accessibilityDescription:@"Mais"]
                                        target:self action:@selector(more:)];
    more.bordered = NO; more.contentTintColor = NSColor.secondaryLabelColor;
    NSStackView *top = hstack(@[logo, title, spacer(), more], 10);

    // temperaturas
    _cpuT = lbl(@"--", 20, NSFontWeightSemibold, nil); _rtxT = lbl(@"--", 20, NSFontWeightSemibold, nil); _rpmT = lbl(@"--", 20, NSFontWeightSemibold, nil);
    _hzT = lbl(@"--", 20, NSFontWeightSemibold, nil);
    _rtxCap = lbl(@"RTX", 11, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSView *t1 = [self tile:@"cpu" value:_cpuT caption:lbl(@"CPU", 11, NSFontWeightMedium, NSColor.secondaryLabelColor)];
    NSView *t2 = [self tile:@"memorychip" value:_rtxT caption:_rtxCap];
    NSView *t3 = [self tile:@"fan" value:_rpmT caption:lbl(@"RPM", 11, NSFontWeightMedium, NSColor.secondaryLabelColor)];
    NSView *t4 = [self tile:@"display" value:_hzT caption:lbl(@"Hz", 11, NSFontWeightMedium, NSColor.secondaryLabelColor)];
    NSStackView *tiles = hstack(@[t1, t2, t3, t4], 8);
    tiles.distribution = NSStackViewDistributionFillEqually;

    // perfil
    _profV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _profSeg = [NSSegmentedControl segmentedControlWithLabels:@[@""] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(profile:)];
    _profSeg.segmentDistribution = NSSegmentDistributionFillEqually;
    NSBox *profCard = card(vstack(@[head(@"gauge.with.dots.needle.67percent", L("Perfil", "Profile"), _profV), _profSeg], 8));

    // ventoinhas
    _fanV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _fanSeg = [NSSegmentedControl segmentedControlWithLabels:@[L("Auto", "Auto"), @"25", @"50", @"75", @"90", @"100"]
                                                trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(fan:)];
    _fanSeg.segmentDistribution = NSSegmentDistributionFillEqually;
    NSBox *fanCard = card(vstack(@[head(@"wind", L("Ventoinhas", "Fans"), _fanV), _fanSeg], 8));

    // RTX
    _rtxV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _rtxDot = [NSView new]; _rtxDot.wantsLayer = YES; _rtxDot.layer.cornerRadius = 4;
    [_rtxDot.widthAnchor constraintEqualToConstant:8].active = YES; [_rtxDot.heightAnchor constraintEqualToConstant:8].active = YES;
    _rtxSeg = [NSSegmentedControl segmentedControlWithLabels:@[L("Desligada", "Off"), L("Ligada", "On"), L("Automática", "Auto")]
                                                trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(rtx:)];
    _rtxSeg.segmentDistribution = NSSegmentDistributionFillEqually;
    NSStackView *rh = head(@"cpu.fill", @"RTX 4050", _rtxV); [rh insertView:_rtxDot atIndex:3 inGravity:NSStackViewGravityLeading];
    _rtxCard = card(vstack(@[rh, _rtxSeg], 8));

    // app usando a RTX (11/11): cartao proprio, so aparece com um app na RTX; botao "Pausar em 2º plano" so nesta execucao
    _appV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _appInfo = lbl(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _appInfo.lineBreakMode = NSLineBreakByWordWrapping; _appInfo.maximumNumberOfLines = 2;
    [_appInfo setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _bgBtn = [NSButton buttonWithTitle:L("Pausar em 2º plano", "Pause in background") target:self action:@selector(bgPause:)];
    _bgBtn.controlSize = NSControlSizeSmall; _bgBtn.bezelStyle = NSBezelStyleRounded;
    _bgBtn.toolTip = L("Só para este app e só enquanto ele estiver aberto: 30 s fora da frente, ele é congelado e a RTX pode desligar; ao voltar para ele, continua.",
                       "Only for this app while it is open: after 30 s in the background it is frozen and the RTX can turn off; switching back resumes it.");
    _appIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"gamecontroller" accessibilityDescription:nil]];
    _appIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [_appIcon.widthAnchor constraintEqualToConstant:32].active = YES; [_appIcon.heightAnchor constraintEqualToConstant:32].active = YES;
    NSStackView *ah = hstack(@[_appIcon, lbl(L("App na RTX", "App on RTX"), 13, NSFontWeightSemibold, nil), spacer(), _appV], 7);
    _appCard = card(vstack(@[ah, hstack(@[_appInfo, spacer(), _bgBtn], 8)], 8));

    // Bluetooth
    _btV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _btPower = [NSSwitch new]; _btPower.target = self; _btPower.action = @selector(btPower:); _btPower.controlSize = NSControlSizeSmall;
    _btAutoSw = [NSSwitch new]; _btAutoSw.target = self; _btAutoSw.action = @selector(btAuto:); _btAutoSw.controlSize = NSControlSizeSmall;
    NSTextField *autoL = _btAutoL = lbl(L("Desligar sem aparelhos (3 min)", "Turn off with no devices (3 min)"), 12, NSFontWeightRegular, nil);
    // (o SF Symbol "bluetooth" nao existe; ondas de radio no lugar)
    NSStackView *bh = hstack(@[sym(@"dot.radiowaves.left.and.right", 13, NSColor.controlAccentColor),
                               vstack(@[lbl(@"Bluetooth", 13, NSFontWeightSemibold, nil), _btV], 1), spacer(), _btPower], 7);
    NSBox *btCard = card(vstack(@[bh, hstack(@[autoL, spacer(), _btAutoSw], 6)], 8));

    // luz do teclado
    _kbV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _kbSeg = [NSSegmentedControl segmentedControlWithLabels:@[L("Apagada", "Off"), @"50%", @"100%"]
                                               trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(kb:)];
    _kbSeg.segmentDistribution = NSSegmentDistributionFillEqually;
    NSButton *colors = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"paintpalette" accessibilityDescription:nil]
                                          target:self action:@selector(colors:)];
    colors.bezelStyle = NSBezelStyleRounded; colors.toolTip = L("Cores, zonas e efeitos…", "Colors, zones and effects…");
    [colors setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSBox *kbCard = card(vstack(@[head(@"keyboard", L("Luz do teclado", "Keyboard light"), _kbV), hstack(@[_kbSeg, colors], 8)], 8));

    // microfone
    _micV = lbl(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _mic = [NSSlider sliderWithValue:0 minValue:0 maxValue:NS_MAXDB target:self action:@selector(mic:)]; _mic.continuous = YES;
    NSBox *micCard = card(vstack(@[head(@"mic", L("Supressor de ruído", "Noise suppression"), _micV), _mic], 6));

    // rodape
    _perm = [NSButton buttonWithTitle:L("Permissões", "Permissions") image:[NSImage imageWithSystemSymbolName:@"lock.shield" accessibilityDescription:nil]
                               target:self action:@selector(perms:)];
    NSButton *log = [NSButton buttonWithTitle:L("Log", "Log") image:[NSImage imageWithSystemSymbolName:@"doc.text" accessibilityDescription:nil]
                                       target:self action:@selector(log:)];
    NSButton *quit = [NSButton buttonWithTitle:L("Sair", "Quit") image:[NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:nil]
                                        target:self action:@selector(quit:)];
    for (NSButton *b in @[_perm, log, quit]) { b.bordered = NO; b.imagePosition = NSImageLeading; b.contentTintColor = NSColor.secondaryLabelColor;
                                               b.font = [NSFont systemFontOfSize:12]; }
    NSStackView *foot = hstack(@[_perm, spacer(), log, quit], 14);

    NSStackView *root = vstack(@[top, tiles, profCard, fanCard, _rtxCard, _appCard, btCard, kbCard, micCard, foot], 8);
    root.edgeInsets = NSEdgeInsetsMake(14, 14, 10, 14);
    root.alignment = NSLayoutAttributeLeading;
    for (NSView *v in root.arrangedSubviews)
        [v.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-28].active = YES;
    [root.widthAnchor constraintEqualToConstant:W].active = YES;
    [root setCustomSpacing:12 afterView:top];
    [root setCustomSpacing:4 afterView:micCard];

    NSViewController *vc = [NSViewController new];
    vc.view = root;
    _pop = [NSPopover new];
    _pop.contentViewController = vc; _pop.behavior = NSPopoverBehaviorTransient; _pop.animates = YES; _pop.delegate = self;
    return self;
}
- (void)refresh {
    NSDictionary *st = fanState(YES);
    int cpu = st ? fanTemp(st, @"0x01") : -1;
    RtxInfo r = rtxInfo(st);
    _cpuT.stringValue = cpu >= 0 ? [NSString stringWithFormat:@"%d°", cpu] : @"--";
    _rtxT.stringValue = r.temp >= 0 ? [NSString stringWithFormat:@"%d°", r.temp] : @"--";
    NSNumber *rpm = [st[@"Fans"] firstObject][@"RPM"];
    NSMutableArray *rr = [NSMutableArray array]; for (NSDictionary *f in st[@"Fans"]) if (f[@"RPM"]) [rr addObject:f[@"RPM"]];
    int avg = 0; for (NSNumber *n in rr) avg += n.intValue; if (rr.count) avg /= (int)rr.count;
    _rpmT.stringValue = rpm ? [NSString stringWithFormat:@"%d", avg] : @"--";
    _rpmT.toolTip = [rr componentsJoinedByString:@" / "];
    double hz = currentRefresh();                  // taxa atual da tela interna
    _hzT.stringValue = hz > 0 ? [NSString stringWithFormat:@"%.0f", hz] : @"--";
    _btAutoL.stringValue = [NSString stringWithFormat:L("Desligar sem aparelhos (%d min)", "Turn off with no devices (%d min)"), btLimit() / 60];
    NSColor *rc = r.state == 2 ? NSColor.systemGreenColor : r.state == 1 ? NSColor.systemYellowColor : NSColor.systemRedColor;
    _rtxDot.layer.backgroundColor = rc.CGColor;
    _rtxCap.stringValue = @"RTX";

    int cur = [st[@"Profile"] intValue];
    _profIds = st ? profileRing(st) : @[];
    if (_profSeg.segmentCount != (NSInteger)_profIds.count) {
        _profSeg.segmentCount = MAX(1, _profIds.count);
        for (NSUInteger i = 0; i < _profIds.count; i++) {
            [_profSeg setImage:[NSImage imageWithSystemSymbolName:profileSymbol(_profIds[i].intValue) accessibilityDescription:nil] forSegment:i];
            [_profSeg setLabel:@"" forSegment:i];
            [_profSeg setToolTip:profileName(_profIds[i].intValue) forSegment:i];
        }
    }
    _profSeg.selectedSegment = [_profIds indexOfObject:@(cur)] == NSNotFound ? -1 : [_profIds indexOfObject:@(cur)];
    _profV.stringValue = st ? profileName(cur) : L("G15Fan não carregado", "G15Fan not loaded");
    _profSeg.enabled = st != nil;
    _sub.stringValue = st ? [NSString stringWithFormat:@"%@ · %@", profileName(cur), onAC() == 1 ? L("na tomada", "on AC") : L("na bateria", "on battery")]
                          : L("G15Fan.kext não carregado", "G15Fan.kext not loaded");

    int b = fanBoost(st);
    NSArray *fv = @[@0, @25, @50, @75, @90, @100];
    _fanSeg.selectedSegment = [fv indexOfObject:@(b)] == NSNotFound ? -1 : [fv indexOfObject:@(b)];
    _fanV.stringValue = b >= 0 ? boostName(b) : @"";
    _fanSeg.enabled = st != nil;

    _rtxCard.hidden = !st[@"RtxParked"];
    _rtxSeg.selectedSegment = rtxMode();
    {                                              // app usando a RTX + chave "Pausar em segundo plano" (so nesta execucao)
        NSString *an = nil; pid_t ap = rtxAppPid(&an);
        if (bgPid) { ap = bgPid; an = bgName; }    // o app escolhido continua aparecendo (mesmo congelado/parada)
        _bgShownPid = ap; _bgShownName = an;
        _appCard.hidden = ap == 0 || _rtxCard.hidden;
        _appV.stringValue = an ?: @"";
        NSImage *ic = ap ? [NSRunningApplication runningApplicationWithProcessIdentifier:ap].icon : nil;   // icone do proprio app
        _appIcon.image = ic ?: [NSImage imageWithSystemSymbolName:@"gamecontroller" accessibilityDescription:nil];
        _appIcon.contentTintColor = ic ? nil : NSColor.controlAccentColor;
        BOOL on = bgPid && bgPid == ap;
        _appInfo.stringValue = !on ? L("Usando a RTX", "Using the RTX")
                             : bgPaused ? L("Pausado. Volte para ele para continuar.", "Paused. Switch back to it to continue.")
                             : L("Pausa após 30 s em segundo plano", "Pauses after 30 s in the background");
        _bgBtn.title = !on ? L("Pausar em 2º plano", "Pause in background") : bgPaused ? L("Retomar agora", "Resume now") : L("Cancelar", "Cancel");
    }
    _rtxV.stringValue = [NSString stringWithFormat:@"%@%@", rtxStateName(r.state), r.state == 2 ? [NSString stringWithFormat:@" · %d%%", r.util] : @""];

    _btPower.state = btOn == 1 ? NSControlStateValueOn : NSControlStateValueOff;
    _btPower.enabled = btOn >= 0;
    _btAutoSw.state = btAuto() ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *bs = btOn < 0 ? @"…" : btOn == 0 ? L("desligado", "off")
                 : btConnected > 0 ? [btNames componentsJoinedByString:@", "]
                 : btAuto() ? [NSString stringWithFormat:L("sem aparelhos · desliga em %d s", "no devices · off in %d s"), MAX(0, btLimit() - btIdleSecs)]
                            : L("sem aparelhos", "no devices");
    _btV.stringValue = bs;

    _kbSeg.selectedSegment = kbLevel;
    [_kbSeg setLabel:[NSString stringWithFormat:@"%d%%", kbPct(1)] forSegment:1];
    NSDictionary *Lt = kbLight();
    NSArray *fxn = @[L("fixa", "static"), L("respiração", "breathing"), L("transição", "morph"), L("espectro", "spectrum"), L("onda", "wave")];
    NSUInteger fi = [kbEffects() indexOfObject:Lt[@"effect"]];
    _kbV.stringValue = fxn[fi == NSNotFound ? 0 : fi];

    int db = nsAtten();
    if (!_mic.highlighted) _mic.intValue = db;
    _mic.enabled = nsWritable();
    _micV.stringValue = db >= NS_MAXDB ? L("máximo", "max") : [NSString stringWithFormat:@"%d dB", db];
    _micV.toolTip = nsWritable() ? L("Menos dB = voz mais natural; mais dB = silêncio mais limpo", "Fewer dB = more natural voice; more dB = cleaner silence")
                                 : L("Rode audio/install.sh (EFI) para liberar", "Run audio/install.sh (EFI) to enable");

    _perm.hidden = [prefs dictionaryForKey:@"tccDecisions"].count == 0;
}
- (void)popoverWillShow:(NSNotification *)n {
    [self refresh];
    btRead(^{ [self refresh]; });
    _timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)popoverDidClose:(NSNotification *)n { [_timer invalidate]; _timer = nil; }
- (void)profile:(NSSegmentedControl *)s { if (s.selectedSegment >= 0 && s.selectedSegment < (NSInteger)_profIds.count) applyProfile(_profIds[s.selectedSegment].intValue); [self refresh]; }
- (void)fan:(NSSegmentedControl *)s { setBoost((int)[@[@0, @25, @50, @75, @90, @100][s.selectedSegment] intValue]); [self refresh]; }
- (void)rtx:(NSSegmentedControl *)s { rtxSetMode((int)s.selectedSegment); [self refresh]; }
- (void)bgPause:(NSButton *)b {                    // liga para o app mostrado; ligado: cancela (e descongela)
    if (bgPid && bgPid == _bgShownPid) bgSet(0, nil);
    else if (_bgShownPid) bgSet(_bgShownPid, _bgShownName);
    [self refresh];
}
- (void)btPower:(NSSwitch *)s { btSetPower(s.state == NSControlStateValueOn, "painel"); _btV.stringValue = @"…"; }
- (void)btAuto:(NSSwitch *)s { [prefs setBool:s.state == NSControlStateValueOn forKey:@"btAuto"]; btIdleSecs = 0;
                               NSLog(@"Bluetooth automatico: %s", s.state == NSControlStateValueOn ? "ligado" : "desligado"); [self refresh]; }
- (void)kb:(NSSegmentedControl *)s { kbSet(s.selectedSegment, NO); [self refresh]; }
- (void)colors:(id)s { [_pop performClose:nil]; kbWindowOpen(); }
- (void)mic:(NSSlider *)sl {
    int db = (int)lround(sl.doubleValue);
    _micV.stringValue = db >= NS_MAXDB ? L("máximo", "max") : [NSString stringWithFormat:@"%d dB", db];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(micSave:) object:nil];
    [self performSelector:@selector(micSave:) withObject:@(db) afterDelay:0.4 inModes:@[NSRunLoopCommonModes]];
}
- (void)micSave:(NSNumber *)db { nsSetAtten(db.intValue); }
- (void)perms:(NSButton *)b {
    NSMenu *tm = [NSMenu new];
    NSDictionary *dec = [prefs dictionaryForKey:@"tccDecisions"];
    for (NSString *k in [dec.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray *p = [k componentsSeparatedByString:@"|"];
        [tm addItemWithTitle:[NSString stringWithFormat:@"%@: %@ (%@)", tccAppName(p.firstObject),
                              [p.lastObject isEqualToString:@"kTCCServiceCamera"] ? L("câmera", "camera") : [p.lastObject isEqualToString:@"kTCCServiceBluetoothAlways"] ? @"Bluetooth" : L("microfone", "microphone"),
                              [dec[k] isEqualToString:@"permitido"] ? L("permitido", "allowed") : L("negado", "denied")] action:nil keyEquivalent:@""];
    }
    [tm addItem:NSMenuItem.separatorItem];
    [tm addItemWithTitle:L("Esquecer respostas (perguntar de novo)", "Forget answers (ask again)") action:@selector(forget:) keyEquivalent:@""].target = self;
    [tm popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, b.bounds.size.height + 4) inView:b];
}
- (void)forget:(id)s { [prefs removeObjectForKey:@"tccDecisions"]; [tccSeen removeAllObjects]; NSLog(@"respostas de permissao esquecidas"); [self refresh]; }
- (void)more:(NSButton *)b {
    NSMenu *m = [NSMenu new];
    [m addItemWithTitle:L("Abrir log", "Open log") action:@selector(log:) keyEquivalent:@""].target = self;
    [m addItemWithTitle:L("Luz do teclado…", "Keyboard light…") action:@selector(colors:) keyEquivalent:@""].target = self;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:L("Sair do G15", "Quit G15") action:@selector(quit:) keyEquivalent:@""].target = self;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, b.bounds.size.height + 4) inView:b];
}
- (void)log:(id)s {
    [_pop performClose:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/g15.log"]]];
}
- (void)quit:(id)s { [NSApp terminate:nil]; }
@end

static void panelRefreshSoon(void) { if (panel && panel.pop.isShown) [panel refresh]; }
static void panelToggle(NSStatusBarButton *b) {
    if (!panel) panel = [G15Panel new];
    if (panel.pop.shown) { [panel.pop performClose:nil]; return; }
    [NSApp activateIgnoringOtherApps:YES];
    [panel.pop showRelativeToRect:b.bounds ofView:b preferredEdge:NSRectEdgeMinY];
}

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
        if (argc == 4 && !strcmp(argv[1], "--painel-png")) {            // teste: desenha o painel num PNG (claro|escuro)
            PT = [NSLocale.preferredLanguages.firstObject hasPrefix:@"pt"];
            prefs = [[NSUserDefaults alloc] initWithSuiteName:@"local.g15"];
            [NSApplication sharedApplication];
            NSApp.appearance = [NSAppearance appearanceNamed:!strcmp(argv[3], "escuro") ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            btOn = 1; btConnected = 0; btIdleSecs = 45;
            if (getenv("G15_PAINEL_APP")) {          // previa do cartao "App na RTX" (G15_PAINEL_APP=nome [G15_PAINEL_PAUSADO=1])
                bgPid = getpid(); bgName = @(getenv("G15_PAINEL_APP")); bgPaused = getenv("G15_PAINEL_PAUSADO") != NULL;
            }
            G15Panel *p = [G15Panel new];
            NSView *v = p.pop.contentViewController.view;
            NSVisualEffectView *bg = [NSVisualEffectView new];
            bg.material = NSVisualEffectMaterialPopover; bg.state = NSVisualEffectStateActive; bg.blendingMode = NSVisualEffectBlendingModeWithinWindow;
            [p refresh];
            NSSize sz = v.fittingSize; bg.frame = NSMakeRect(0, 0, sz.width, sz.height); v.frame = bg.bounds; [bg addSubview:v];
            NSWindow *w = [[NSWindow alloc] initWithContentRect:bg.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            w.contentView = bg; w.appearance = NSApp.appearance; [w layoutIfNeeded];
            for (int i = 0; i < 3; i++) { sz = v.fittingSize; [w setContentSize:sz]; bg.frame = NSMakeRect(0, 0, sz.width, sz.height); v.frame = bg.bounds; [w layoutIfNeeded]; }
            [w display];
            NSBitmapImageRep *rep = [bg bitmapImageRepForCachingDisplayInRect:bg.bounds];
            [bg cacheDisplayInRect:bg.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[2]) atomically:YES];
            printf("%.0fx%.0f\n", sz.width, sz.height);
            return 0;
        }
        if (argc >= 2 && !strncmp(argv[1], "--", 2) && strcmp(argv[1], "--daemon")) {   // ventoinhas pela linha de comando
            kern_return_t r = KERN_SUCCESS;
            prefs = [[NSUserDefaults alloc] initWithSuiteName:@"local.g15"];   // --perfil: extras da Bateria guardam o estado
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
        ui.item.button.target = ui; ui.item.button.action = @selector(clicked:);
        [ui.item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

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
        bgRestore();                                // pausa em 2o plano guardada (o app dela ainda aberto)

        NSLog(@"G15 iniciado, luz nivel %ld", (long)kbLevel);
        kbApplySoon(0.2);
        [NSApp run];
    }
    return 0;
}
