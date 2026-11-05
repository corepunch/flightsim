#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef struct { CGFloat r, g, b; } UIRGB;

// The interface theme, from Resources/UI/theme.json:
//
//   { "colors":  { "ink": [0.55, 0.95, 0.85], … },     linear 0..1 RGB
//     "fonts":   { "interface": "Oxanium-Regular", … },  PostScript names
//     "metrics": { "slant": 0.36, … } }
//
// The roles: ink (phosphor text and outlines), amber (emphasis), red
// (danger); panel, background and map fills; the console variant's steel,
// copper edge and glass; menu night/title for the main menu. Fonts: mono and
// monoBold for cockpit telemetry, interface/interfaceBold/body/bodyMedium for
// the front end. UIStyle.h names each one (UIInk, UIInterfaceFont, …).
//
// A missing key logs once and draws magenta / Menlo / 0, so it is easy to
// spot; Tools/validate_strings.py checks that the file has every key UIStyle.h uses.
// Thread-safe; loads once on first use.
UIRGB UIThemeColor(NSString *name);
NSString *UIThemeFont(NSString *name);
CGFloat UIThemeMetric(NSString *name);

