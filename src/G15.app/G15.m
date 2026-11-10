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
// AW-ELC (testado no Fedora em 09/11/2026, tools/test-kbd-elc.py; protocolo do OpenRGB AlienwareController): relatorio
// de saida de 33 bytes, resposta lida por GET_REPORT de entrada (83 <cmd> ...). Zonas 00 esquerda, 01 centro,
// 02 direita, 03 numerico. Uma cor/efeito = 21 0001 FFFF (nova animacao temporaria) -> {23 01 <n> <zonas> ->
// 24 <acoes>} por zona -> 21 0003 FFFF (fim e toca). Acao (8 bytes, ate 3 por pacote): modo 00 cor / 01 pulso /
// 02 transicao, duracao em ms (16 bits: menor = mais rapido), tempo (16 bits), r g b. Brilho: 26 <dim> 00 04 00 01 02 03.
// Nada e gravado na memoria do controlador: no boot ele volta a animacao padrao, e o app reaplica.
static IOHIDManagerRef mgr;
static NSInteger kbLevel = 2;                      // 0, 1, 2
static const int KB_PCT[3] = {0, 50, 100};
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
    uint8_t dm[] = {0x26, (uint8_t)(100 - KB_PCT[kbLevel]), 0x00, 0x04, 0x00, 0x01, 0x02, 0x03};
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
    kbSend(KB_PCT[kbLevel]);
    kbWindowRefresh();
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

// ---------- RTX automatica (G15Fan RtxPm, 10/11) ----------
// Sem nenhum programa na RTX (clientes do NVAccel) e sem monitor externo por 30 s na bateria ou 3 min na tomada, para a
// RTX (NVRM e audio HDMI no estado 0; com -g15fan-rtxpm-corte o G15Fan corta a energia). Ao conectar o carregador:
// religa (e ela volta a parar depois de 3 min ociosa). Parada, a RTX nao ve o cabo HDMI: modo "Ligada" antes. Modo no menu (seletor RTX), preferencia local.g15 "rtxMode".
static int rtxIdleTicks;
// modo (preferencia "rtxMode"): 0 desligada (para sempre que ociosa 30 s; um programa que a pedir ainda a religa),
// 1 ligada (nunca para), 2 automatica (ociosa: 30 s na bateria, 3 min na tomada; religa no carregador)
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
static BOOL rtxExternal(void) {                    // mais de uma tela ligada (espelhada conta)
    uint32_t n = 0; CGGetOnlineDisplayList(0, NULL, &n);
    return n > 1;
}
static BOOL rtxSet(BOOL on, const char *why) {
    kern_return_t r = fanWrite(@{@"RtxPm": on ? @1 : @2});
    NSLog(@"RTX %s (%s): %s", on ? "ligar" : "parar", why, r == KERN_SUCCESS ? "ok" : "erro");
    rtxIdleTicks = 0;
    return r == KERN_SUCCESS;
}
static void rtxTick(NSDictionary *st, int ac) {    // a cada 5 s
    int mode = rtxMode();
    if (!st || mode == 1 || (mode == 2 && ac < 0) || !st[@"RtxParked"] || [st[@"RtxParked"] boolValue]) { rtxIdleTicks = 0; return; }
    if (rtxClients() || rtxExternal()) { rtxIdleTicks = 0; return; }
    if (mode == 0) { if (++rtxIdleTicks >= 6) rtxSet(NO, "modo desligada, ociosa 30 s"); return; }
    if (++rtxIdleTicks >= (ac ? 36 : 6)) rtxSet(NO, ac ? "tomada, ociosa 3 min" : "bateria, ociosa 30 s");
}
static void rtxPower(int ac) {                     // carregador mudou
    rtxIdleTicks = 0;
    if (ac != 1 || rtxMode() != 2) return;
    NSDictionary *st = fanState(NO);
    if ([st[@"RtxParked"] boolValue]) rtxSet(YES, "carregador conectado");
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
    rtxTick(st, onAC());
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
        NSString *st = kbLevel ? [NSString stringWithFormat:@"%d%% · %@", KB_PCT[kbLevel], fxn[fi == NSNotFound ? 0 : fi]] : L("apagada", "off");
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
- (void)rtxMode:(NSSegmentedControl *)sc {
    int m = (int)sc.selectedSegment;
    [[NSUserDefaults standardUserDefaults] setInteger:m forKey:@"rtxMode"];
    rtxIdleTicks = 0;
    BOOL parked = [fanState(NO)[@"RtxParked"] boolValue];
    NSLog(@"RTX: modo %d", m);
    if (m == 1 && parked) rtxSet(YES, "modo ligada");
    else if (m == 0 && !parked) {
        if (rtxClients() || rtxExternal())
            notify(@"RTX", L("Em uso (programa ou monitor externo): desliga quando ficar ociosa.", "In use (app or external display): turns off when idle."));
        else rtxSet(NO, "modo desligada");
    }
}
- (void)setProfile:(NSMenuItem *)i { applyProfile((int)i.tag); }
- (void)openKb:(id)s { kbWindowOpen(); }
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
