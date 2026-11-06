// Generates the Theme4Logic / T4L logo set into Logo/. Build + run: clang -fobjc-arc -framework Cocoa -o /tmp/make_logo tools/make_logo.m && /tmp/make_logo Logo
#import <Cocoa/Cocoa.h>

static NSColor *Hex(unsigned v) { return [NSColor colorWithSRGBRed:((v>>16)&255)/255.0 green:((v>>8)&255)/255.0 blue:(v&255)/255.0 alpha:1]; }
static NSArray<NSColor *> *RingColors(void) {
  return @[Hex(0xff453a), Hex(0xff9f0a), Hex(0xffd60a), Hex(0x32d74b), Hex(0x0a84ff), Hex(0xbf5af2)];
}
static NSFont *RoundedHeavy(CGFloat size, NSFontWeight weight) {
  NSFont *base = [NSFont systemFontOfSize:size weight:weight];
  NSFontDescriptor *d = [base.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
  NSFont *f = d ? [NSFont fontWithDescriptor:d size:size] : nil;
  return f ?: base;
}
static NSBitmapImageRep *Canvas(int w, int h) {
  return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4
    hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
}
static void WithCanvas(NSBitmapImageRep *rep, void (^draw)(void)) {
  NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:ctx];
  ctx.imageInterpolation = NSImageInterpolationHigh;
  draw();
  [NSGraphicsContext restoreGraphicsState];
}
static void Save(NSBitmapImageRep *rep, NSString *path) {
  [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
// Draws the icon (rounded square + color ring + "T4L") into the square `box`.
// `square` fills the whole box edge to edge, for hosts that round the corners themselves.
static void DrawIconShape(NSRect box, BOOL shadow, BOOL square) {
  CGFloat s = box.size.width;
  NSBezierPath *shape = square ? [NSBezierPath bezierPathWithRect:box]
                               : [NSBezierPath bezierPathWithRoundedRect:box xRadius:s*0.2237 yRadius:s*0.2237];
  if (shadow) {
    [NSGraphicsContext saveGraphicsState];
    NSShadow *sh = [NSShadow new]; sh.shadowOffset = NSMakeSize(0, -s*0.012); sh.shadowBlurRadius = s*0.03; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
    [sh set]; [Hex(0x15171b) setFill]; [shape fill];
    [NSGraphicsContext restoreGraphicsState];
  }
  [NSGraphicsContext saveGraphicsState];
  [shape addClip];
  NSGradient *bg = [[NSGradient alloc] initWithStartingColor:Hex(0x2b2e36) endingColor:Hex(0x111317)];
  [bg drawInRect:box angle:-90];
  // soft color bloom behind the ring
  NSGradient *glow = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithSRGBRed:0.45 green:0.35 blue:1 alpha:0.18], 0.0, [NSColor colorWithSRGBRed:0.45 green:0.35 blue:1 alpha:0.0], 1.0, nil];
  [glow drawFromCenter:NSMakePoint(NSMidX(box), NSMidY(box)) radius:0 toCenter:NSMakePoint(NSMidX(box), NSMidY(box)) radius:s*0.5 options:0];
  [NSGraphicsContext restoreGraphicsState];

  NSPoint c = NSMakePoint(NSMidX(box), NSMidY(box));
  CGFloat r = s*0.335, w = s*0.074, gap = 17.0;
  NSArray *cols = RingColors();
  for (NSUInteger i = 0; i < cols.count; i++) {
    CGFloat fi = (CGFloat)i; CGFloat start = 90 - fi*60 - gap/2, end = 90 - (fi+1)*60 + gap/2;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:c radius:r startAngle:start endAngle:end clockwise:YES];
    arc.lineWidth = w; arc.lineCapStyle = NSLineCapStyleRound;
    [cols[i] setStroke]; [arc stroke];
  }
  // wordmark
  NSString *t = @"T4L";
  CGFloat fs = s*0.27;
  NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
  NSDictionary *attrs = @{NSFontAttributeName: RoundedHeavy(fs, NSFontWeightBlack), NSForegroundColorAttributeName: [NSColor whiteColor], NSKernAttributeName: @(-fs*0.03), NSParagraphStyleAttributeName: ps};
  NSSize ts = [t sizeWithAttributes:attrs];
  CGFloat maxW = (r - w*0.5)*2*0.86;
  if (ts.width > maxW) { fs *= maxW/ts.width; attrs = @{NSFontAttributeName: RoundedHeavy(fs, NSFontWeightBlack), NSForegroundColorAttributeName: [NSColor whiteColor], NSKernAttributeName: @(-fs*0.03), NSParagraphStyleAttributeName: ps}; ts = [t sizeWithAttributes:attrs]; }
  // optical centering using cap height
  NSFont *f = attrs[NSFontAttributeName];
  CGFloat capH = f.capHeight;
  [t drawAtPoint:NSMakePoint(c.x - ts.width/2, c.y - capH/2 - (ts.height - capH)/2 + (f.ascender - capH)/2 - (f.ascender - capH)/2) withAttributes:attrs];
}
static void DrawIcon(NSRect box, BOOL shadow) { DrawIconShape(box, shadow, NO); }
static void DrawWordmark(NSPoint origin, CGFloat size, NSTextAlignment align) {
  NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:@"Theme4Logic"];
  NSDictionary *base = @{NSFontAttributeName: RoundedHeavy(size, NSFontWeightBold), NSForegroundColorAttributeName: [NSColor whiteColor], NSKernAttributeName: @(-size*0.01)};
  [a addAttributes:base range:NSMakeRange(0, a.length)];
  [a addAttribute:NSForegroundColorAttributeName value:Hex(0x0a84ff) range:NSMakeRange(5, 1)];
  NSSize sz = [a size];
  NSPoint p = origin; if (align == NSTextAlignmentCenter) p.x -= sz.width/2;
  [a drawAtPoint:p];
}
static void ColorBar(NSRect r) {
  NSArray *cols = RingColors();
  CGFloat segW = r.size.width / cols.count;
  for (NSUInteger i = 0; i < cols.count; i++) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(r.origin.x + i*segW + 3, r.origin.y, segW - 6, r.size.height) xRadius:r.size.height/2 yRadius:r.size.height/2];
    [cols[i] setFill]; [p fill];
  }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *out = argc > 1 ? @(argv[1]) : @".";
    // 1024 icon with macOS-style margin + shadow
    NSBitmapImageRep *i1024 = Canvas(1024, 1024);
    WithCanvas(i1024, ^{ DrawIcon(NSMakeRect(100, 100, 824, 824), YES); });
    Save(i1024, [out stringByAppendingPathComponent:@"Theme4Logic-icon-1024.png"]);
    // 512 (website / README / app about)
    NSBitmapImageRep *i512 = Canvas(512, 512);
    WithCanvas(i512, ^{ DrawIcon(NSMakeRect(50, 50, 412, 412), YES); });
    Save(i512, [out stringByAppendingPathComponent:@"Theme4Logic-icon-512.png"]);
    // full-bleed square (websites and stores that apply their own corner mask)
    NSBitmapImageRep *sq = Canvas(1024, 1024);
    WithCanvas(sq, ^{ DrawIconShape(NSMakeRect(0, 0, 1024, 1024), NO, YES); });
    Save(sq, [out stringByAppendingPathComponent:@"Theme4Logic-icon-square-1024.png"]);
    // banners 924x540
    NSColor *bgc = Hex(0x111317);
    NSBitmapImageRep *iconOnly = Canvas(924, 540);
    WithCanvas(iconOnly, ^{ [bgc setFill]; NSRectFill(NSMakeRect(0,0,924,540)); DrawIcon(NSMakeRect(462-200, 70, 400, 400), YES); });
    Save(iconOnly, [out stringByAppendingPathComponent:@"Theme4Logic-icon-only.png"]);
    NSBitmapImageRep *textOnly = Canvas(924, 540);
    WithCanvas(textOnly, ^{ [bgc setFill]; NSRectFill(NSMakeRect(0,0,924,540)); DrawWordmark(NSMakePoint(462, 250), 132, NSTextAlignmentCenter); ColorBar(NSMakeRect(262, 205, 400, 14));
      NSDictionary *tag = @{NSFontAttributeName: RoundedHeavy(34, NSFontWeightMedium), NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.62]}; NSString *s = @"Color themes for Logic Pro"; NSSize sz = [s sizeWithAttributes:tag]; [s drawAtPoint:NSMakePoint(462 - sz.width/2, 150) withAttributes:tag]; });
    Save(textOnly, [out stringByAppendingPathComponent:@"Theme4Logic-text-only.png"]);
    NSBitmapImageRep *both = Canvas(924, 540);
    WithCanvas(both, ^{ [bgc setFill]; NSRectFill(NSMakeRect(0,0,924,540)); DrawIcon(NSMakeRect(40, 100, 340, 340), YES); DrawWordmark(NSMakePoint(412, 285), 76, NSTextAlignmentLeft); ColorBar(NSMakeRect(416, 250, 300, 12));
      NSDictionary *tag = @{NSFontAttributeName: RoundedHeavy(30, NSFontWeightMedium), NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.62]}; [@"Color themes for Logic Pro" drawAtPoint:NSMakePoint(418, 200) withAttributes:tag]; });
    Save(both, [out stringByAppendingPathComponent:@"Theme4Logic-icon-with-text.png"]);
  }
  return 0;
}
