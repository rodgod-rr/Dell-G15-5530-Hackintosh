// stencilfix: correcao dos quadrados brancos do 3D na UHD do G15 (WhateverXe + driver Metal TGL da Apple), para todo app.
// Causa (testes 49-52, 04/11): ler o stencil de uma Depth32Float_Stencil8 (ou Depth24Unorm_Stencil8) por uma VIEW de
// formato X32_Stencil8/X24_Stencil8 num shader devolve dados errados (o dado escrito esta certo: teste de stencil e blit
// leem certo; a view de uma COPIA por blit tambem). O Unity (nb3d) faz isso nas areas de luz/reflexo.
//
// Vai no lugar do impostor.dylib do AppleIntelTGLGraphicsMTLDriver.bundle (o driver o carrega por @loader_path em todo
// processo que usa Metal na UHD); o original vira impostor-real.dylib e e reexportado inteiro (LC_REEXPORT_DYLIB).
// Modo em /Library/G15-uhd/stencilfix.conf (uma palavra; sem o arquivo = copy):
//   copy   a view de stencil devolvida e de uma copia-sombra da textura, atualizada por blit no fim de cada passe de
//          render que escreve nela (o contorno provado no nb3d, teste 52)
//   noopt  cria as texturas de profundidade+stencil com allowGPUOptimizedContents = NO (sem compressao); sem custo,
//          vale se o teste NOOPT do xe-depthstencil der certo
//   both   os dois     off   nada (so registra que carregou)
// skipasm (06/11): o plugin Intel do MPS (AppleIntelTGLGraphicsMTLDriver) compila ~600 bibliotecas de kernel a partir de fonte que usam __asm("air.convert...");
//   o compilador do macOS 26 as REJEITA ("illegal string literal in 'asm'"), todas falham (~12 ms cada, ~7 s no total, a cada processo que usa MPS CNN, ex.: OCR do Vision) e o MPS cai nos kernels genericos.
//   Aqui essas compilacoes falham NA HORA, sem tentar: OCR de ~8 s para ~1,4 s, mesmo resultado. Vale tambem para processos do sistema (Preview, Fotos, mediaanalysisd), menos o WindowServer.
//   Desligar: echo off > /Library/G15-uhd/skipasm.conf (padrao: ligado). NAO reescrever o __asm para compilar: os kernels compilam mas o OCR devolve 0 linhas.
// Log: log show --last 10m --predicate 'subsystem == "com.g15.stencilfix"' --style compact
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <os/log.h>
#include <atomic>
#include <mach-o/dyld.h>

static os_log_t lg;
static bool doCopy, doNoopt;
static std::atomic<long> nSkip{0};
static std::atomic<long> nShadow{0}, nCopies{0}, nNoopt{0};

static bool dsFormat(MTLPixelFormat f) { return f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatDepth24Unorm_Stencil8; }
static bool stencilView(MTLPixelFormat f) { return f == MTLPixelFormatX32_Stencil8 || f == MTLPixelFormatX24_Stencil8; }

// troca o metodo so nesta classe (se for herdado, acrescenta um override que chama o original)
static void hook(Class c, SEL s, id (^mk)(IMP)) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, s);
    if (!m) { os_log(lg, "stencilfix: %{public}s sem %{public}s", class_getName(c), sel_getName(s)); return; }
    IMP o = method_getImplementation(m);
    class_replaceMethod(c, s, imp_implementationWithBlock(mk(o)), method_getTypeEncoding(m));
}

static const void *kShadow = &kShadow, *kSrc = &kSrc, *kCB = &kCB;

// copia-sombra com o mesmo tipo/fatias/mips (o Unity usa 2D e 2DArray de 1 fatia); multisample e textura de buffer ficam de fora
static id<MTLTexture> shadowFor(id<MTLTexture> t) {
    id<MTLTexture> sh = objc_getAssociatedObject(t, kShadow);
    if (sh) return sh;
    MTLTextureType ty = t.textureType;
    bool ok = (ty == MTLTextureType2D || ty == MTLTextureType2DArray || ty == MTLTextureTypeCube || ty == MTLTextureTypeCubeArray)
              && t.sampleCount == 1 && !t.buffer && !t.parentTexture;
    if (!ok) { os_log(lg, "stencilfix: PULADA %lux%lu fmt %lu tipo %lu amostras %lu fatias %lu pai %d buffer %d", (unsigned long)t.width,
                      (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)ty, (unsigned long)t.sampleCount,
                      (unsigned long)t.arrayLength, t.parentTexture != nil, t.buffer != nil); return nil; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = ty; d.pixelFormat = t.pixelFormat; d.width = t.width; d.height = t.height; d.depth = t.depth;
    d.arrayLength = t.arrayLength; d.mipmapLevelCount = t.mipmapLevelCount; d.sampleCount = 1;
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    d.storageMode = MTLStorageModePrivate;
    sh = [t.device newTextureWithDescriptor:d];
    if (sh) { objc_setAssociatedObject(t, kShadow, sh, OBJC_ASSOCIATION_RETAIN); ++nShadow; }
    os_log(lg, "stencilfix: copia-sombra %lux%lu fmt %lu tipo %lu fatias %lu mips %lu %{public}s (total %ld)", (unsigned long)t.width,
           (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)ty, (unsigned long)t.arrayLength,
           (unsigned long)t.mipmapLevelCount, sh ? "ok" : "FALHOU", nShadow.load());
    return sh;
}

static void installSkipAsm() {
    Class dev = objc_getClass("MTLIGAccelDevice"); if (!dev) { os_log(lg, "stencilfix: skipasm: sem MTLIGAccelDevice em %{public}s", getprogname()); return; }
    SEL s = @selector(newLibraryWithSource:options:compilerTask:error:);
    hook(dev, s, ^id(IMP o) { return ^id(id self, NSString *src, id opts, id task, NSError **err) {
        if (src && [src containsString:@"__asm(\"air.convert"]) {
            long c = ++nSkip; if (c == 1 || c % 200 == 0) os_log(lg, "stencilfix: skipasm: %ld compilacoes puladas em %{public}s", c, getprogname());
            if (err) *err = [NSError errorWithDomain:@"com.g15.stencilfix" code:1 userInfo:@{NSLocalizedDescriptionKey: @"stencilfix: __asm(air.convert) nao compila no macOS 26 (pulado)"}];
            return nil; }
        return ((id (*)(id, SEL, id, id, id, NSError **))o)(self, s, src, opts, task, err); }; });
}

// leakfix (06/11): o driver TGL 16.0.32 vaza 72 KB por command buffer. -[MTLIGAccelCommandBuffer initWithQueue:...] aloca um buffer
// POSH proprio (new 0x12010) quando o command buffer e o unico ativo e a fila nao tem o compartilhado (queue.m_pPoshUsedAsTarget
// nunca e preenchido), mas deixa m_isOnlyActiveCommandBuffer = 1; o dealloc so libera com o flag 0. Embrulhamos o dealloc e liberamos
// o buffer orfao antes (seguro: o buffer compartilhado da fila nunca existe, entao o ponteiro e sempre do proprio command buffer).
// Desligar: echo off > /Library/G15-uhd/leakfix.conf (reabra os apps).
static IMP gLeakDealloc; static ptrdiff_t oPosh = -1, oOnly = -1; static std::atomic<long> nLeakFreed{0};
static void leakFixDealloc(__unsafe_unretained id self, SEL sel) {
    char *b = (char *)(__bridge void *)self; void **pp = (void **)(b + oPosh);
    if (*pp && *(unsigned char *)(b + oOnly)) { operator delete(*pp); *pp = nullptr; if (++nLeakFreed == 1) os_log(lg, "stencilfix: leakfix liberou o 1o buffer POSH em %{public}s", getprogname()); }
    ((void (*)(id, SEL))gLeakDealloc)(self, sel); }
static void installLeakFix() {
    NSString *c = [[NSString stringWithContentsOfFile:@"/Library/G15-uhd/leakfix.conf" encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (c && [c isEqualToString:@"off"]) { os_log(lg, "stencilfix: leakfix desligado (leakfix.conf)"); return; }
    Class cb = objc_getClass("MTLIGAccelCommandBuffer"); if (!cb) { os_log(lg, "stencilfix: leakfix: sem MTLIGAccelCommandBuffer"); return; }
    Ivar a = class_getInstanceVariable(cb, "_pPoshUsedAsTarget"), o = class_getInstanceVariable(cb, "m_isOnlyActiveCommandBuffer");
    Method m = class_getInstanceMethod(cb, sel_registerName("dealloc"));
    if (!a || !o || !m || !ivar_getTypeEncoding(o) || ivar_getTypeEncoding(o)[0] != 'B') { os_log(lg, "stencilfix: leakfix: ivars/dealloc nao conferem, nao instalado"); return; }
    oPosh = ivar_getOffset(a); oOnly = ivar_getOffset(o); gLeakDealloc = method_setImplementation(m, (IMP)leakFixDealloc);
    os_log(lg, "stencilfix: leakfix instalado em %{public}s (posh +%td, only +%td)", getprogname(), oPosh, oOnly); }
static void install() {
    Class tex = objc_getClass("MTLIGAccelTexture"), cbc = objc_getClass("MTLIGAccelCommandBuffer"),
          rec = objc_getClass("MTLIGAccelRenderCommandEncoder"), dev = objc_getClass("MTLIGAccelDevice");
    os_log(lg, "stencilfix: carregado em %{public}s (copy %d, noopt %d; classes %d%d%d%d)", getprogname(), doCopy, doNoopt,
           tex != nil, cbc != nil, rec != nil, dev != nil);
    if (doNoopt && dev) {
        SEL s = @selector(newTextureWithDescriptor:);
        hook(dev, s, ^id(IMP o) { return ^id(id self, MTLTextureDescriptor *d) {
            if (d && dsFormat(d.pixelFormat) && (d.usage & (MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView)) &&
                d.allowGPUOptimizedContents) {
                MTLTextureDescriptor *dd = [d copy]; dd.allowGPUOptimizedContents = NO;
                if (++nNoopt <= 8) os_log(lg, "stencilfix: noopt %lux%lu fmt %lu", (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat);
                return ((id (*)(id, SEL, id))o)(self, s, dd);
            }
            return ((id (*)(id, SEL, id))o)(self, s, d); }; });
    }
    if (!doCopy || !tex || !cbc || !rec) return;
    SEL v1 = @selector(newTextureViewWithPixelFormat:);
    hook(tex, v1, ^id(IMP o) { return ^id(id self, MTLPixelFormat f) {
        id<MTLTexture> t = self;
        if (dsFormat(t.pixelFormat) && stencilView(f)) {
            os_log(lg, "stencilfix: view %lu->%lu %lux%lu", (unsigned long)t.pixelFormat, (unsigned long)f, (unsigned long)t.width, (unsigned long)t.height);
            if (id<MTLTexture> sh = shadowFor(t)) return ((id (*)(id, SEL, MTLPixelFormat))o)(sh, v1, f); }
        return ((id (*)(id, SEL, MTLPixelFormat))o)(self, v1, f); }; });
    SEL v2 = @selector(newTextureViewWithPixelFormat:textureType:levels:slices:);
    hook(tex, v2, ^id(IMP o) { return ^id(id self, MTLPixelFormat f, MTLTextureType ty, NSRange l, NSRange sl) {
        id<MTLTexture> t = self;
        if (dsFormat(t.pixelFormat) && stencilView(f)) {
            os_log(lg, "stencilfix: view2 %lu->%lu tipo %lu %lux%lu", (unsigned long)t.pixelFormat, (unsigned long)f, (unsigned long)ty, (unsigned long)t.width, (unsigned long)t.height);
            if (id<MTLTexture> sh = shadowFor(t)) return ((id (*)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange))o)(sh, v2, f, ty, l, sl); }
        return ((id (*)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange))o)(self, v2, f, ty, l, sl); }; });
    SEL rs = @selector(renderCommandEncoderWithDescriptor:);
    hook(cbc, rs, ^id(IMP o) { return ^id(id self, MTLRenderPassDescriptor *d) {
        id enc = ((id (*)(id, SEL, id))o)(self, rs, d);
        id<MTLTexture> t = d.depthAttachment.texture ?: d.stencilAttachment.texture;
        if (t && !objc_getAssociatedObject(t, kShadow) && t.parentTexture) t = t.parentTexture;  // passe por view (fatia/mip)
        if (enc && t && objc_getAssociatedObject(t, kShadow)) {
            objc_setAssociatedObject(enc, kSrc, t, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(enc, kCB, self, OBJC_ASSOCIATION_ASSIGN);
        }
        return enc; }; });
    SEL ee = @selector(endEncoding);
    hook(rec, ee, ^id(IMP o) { return ^void(id self) {
        ((void (*)(id, SEL))o)(self, ee);
        id<MTLTexture> src = objc_getAssociatedObject(self, kSrc);
        if (!src) return;
        id<MTLTexture> sh = objc_getAssociatedObject(src, kShadow);
        id<MTLCommandBuffer> cb = objc_getAssociatedObject(self, kCB);
        objc_setAssociatedObject(self, kSrc, nil, OBJC_ASSOCIATION_RETAIN);
        if (sh && cb) { id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder]; [bl copyFromTexture:src toTexture:sh]; [bl endEncoding];
            long c = ++nCopies; if (c == 1 || c % 500 == 0) os_log(lg, "stencilfix: %ld copias por blit", c); } }; });
}

__attribute__((constructor)) static void init() { @autoreleasepool {
    lg = os_log_create("com.g15.stencilfix", "fix");
    // seguranca: nada em processos do sistema (WindowServer etc.): um erro aqui nao pode derrubar a tela
    char exe[1024]; uint32_t n = sizeof exe;
    NSString *sk = [[NSString stringWithContentsOfFile:@"/Library/G15-uhd/skipasm.conf" encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    bool skipAsm = !(sk && [sk isEqualToString:@"off"]);
    bool sysUi = _NSGetExecutablePath(exe, &n) == 0 && (strstr(exe, "WindowServer") || strstr(exe, "loginwindow"));
    n = sizeof exe; if (!sysUi) installLeakFix();
    if (_NSGetExecutablePath(exe, &n) == 0 && (!strncmp(exe, "/System/", 8) || !strncmp(exe, "/usr/", 5))) {
        // processo do sistema: so o skipasm (barato e sem efeito colateral), e nunca no WindowServer
        if (skipAsm && !strstr(exe, "WindowServer") && !strstr(exe, "loginwindow")) installSkipAsm();
        return; }
    if (skipAsm) installSkipAsm();
    NSString *m = [NSString stringWithContentsOfFile:@"/Library/G15-uhd/stencilfix.conf" encoding:NSUTF8StringEncoding error:nil];
    m = [m stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"copy";
    if (!m.length) m = @"copy";
    doCopy = [m isEqualToString:@"copy"] || [m isEqualToString:@"both"];
    doNoopt = [m isEqualToString:@"noopt"] || [m isEqualToString:@"both"];
    install();
} }
