// Desenha o icone do G15.app (simbolo "fan.fill" sobre um quadrado arredondado) em um .iconset.
// Uso (na VM, durante o build): mkicon <pasta.iconset>
#import <AppKit/AppKit.h>

static void draw(int s, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:s pixelsHigh:s
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGFloat m = s * 0.1;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(m, m, s - 2 * m, s - 2 * m) xRadius:s * 0.19 yRadius:s * 0.19];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.09 green:0.11 blue:0.15 alpha:1]
                                   endingColor:[NSColor colorWithSRGBRed:0.20 green:0.25 blue:0.33 alpha:1]] drawInBezierPath:bg angle:90];
    NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:s * 0.42 weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:
            [NSColor colorWithSRGBRed:0.36 green:0.84 blue:1.0 alpha:1]]];
    NSImage *fan = [[NSImage imageWithSystemSymbolName:@"fan.fill" accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    NSSize z = fan.size;
    [fan drawInRect:NSMakeRect((s - z.width) / 2, (s - z.height) / 2, z.width, z.height)];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *dir = @(argv[1]);
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            int s = n.intValue;
            draw(s, [dir stringByAppendingFormat:@"/icon_%dx%d.png", s, s]);
            draw(2 * s, [dir stringByAppendingFormat:@"/icon_%dx%d@2x.png", s, s]);
        }
    }
    return 0;
}
