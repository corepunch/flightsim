#import "Input.h"
#import "Common.h"

@implementation InputBinding
- (instancetype)initWithAction:(InputHintAction)action symbols:(NSArray<NSString *> *)symbols text:(NSString *)text {
    if ((self = [super init])) { _action = action; _symbols = [symbols copy]; _text = [text copy] ?: @""; }
    return self;
}
@end

@implementation InputGuide
- (instancetype)initWithScheme:(InputScheme)scheme name:(NSString *)name bindings:(NSArray<InputBinding *> *)bindings
                 confirmSymbol:(NSString *)symbol text:(NSString *)text {
    if ((self = [super init])) {
        _scheme = scheme; _name = [name copy]; _bindings = [bindings copy];
        _confirmSymbol = [symbol copy]; _confirmText = [text copy] ?: @"";
    }
    return self;
}
@end

InputGuide *InputGuideMake(InputScheme scheme, NSString *name, InputPadSymbols p) {
    NSMutableArray<InputBinding *> *bindings = [NSMutableArray array];
    void (^add)(InputHintAction, NSArray<NSString *> *, NSString *) = ^(InputHintAction action, NSArray *symbols, NSString *text) {
        [bindings addObject:[[InputBinding alloc] initWithAction:action symbols:symbols text:text]];
    };
    NSString *confirmSymbol = nil, *confirmText = nil;
    if (scheme == InputSchemeTouch || scheme == InputSchemeGamepad) {
        BOOL touch = scheme == InputSchemeTouch;
        add(InputHintSteer, @[p.leftStick ?: @"l.joystick"], nil);
        add(InputHintSpeed, touch ? @[p.rightStick ?: @"r.joystick"] :
            @[p.leftShoulder ?: @"lb.rectangle.roundedbottom", p.rightShoulder ?: @"rb.rectangle.roundedbottom"], touch ? @"↑↓" : nil);
        add(InputHintFire, @[touch ? @"x.circle" : (p.rightTrigger ?: @"rt.rectangle.roundedtop")], nil);
        add(InputHintSecondary, @[touch ? @"a.circle" : (p.b ?: @"b.circle")], nil);
        add(InputHintTarget, @[touch ? @"y.circle" : (p.y ?: @"y.circle")], nil);
        add(InputHintRoll, @[p.rightStick ?: @"r.joystick"], @"←→");
        add(InputHintBoost, touch ? @[p.rightStick ?: @"r.joystick"] : @[p.leftTrigger ?: @"lt.rectangle.roundedtop"],
            touch ? L10n(@"controls.guide.boost") : nil);
        if (!touch) add(InputHintCamera, @[p.x ?: @"x.circle"], nil);
        add(InputHintPause, @[touch ? @"b.circle" : (p.menu ?: @"line.3.horizontal.circle")], nil);
        name = name ?: L10n(touch ? @"controls.device.touch" : @"input.controller");
        confirmSymbol = touch ? @"hand.tap.fill" : (p.a ?: @"a.circle");
    } else {
        NSArray<NSString *> *keys = L10nList(@"controls.desktop.keys");
        BOOL stick = scheme == InputSchemeJoystick;
        add(InputHintSteer, @[], stick ? L10n(@"input.joystick") : keys[0]);
        add(InputHintSpeed, @[], stick ? L10n(@"controls.guide.lever") : keys[4]);
        add(InputHintFire, @[], stick ? @"B1" : keys[1]);
        add(InputHintSecondary, @[], stick ? @"B5" : keys[2]);
        add(InputHintTarget, @[], stick ? @"B6" : keys[3]);
        add(InputHintRoll, @[], @"Q / E");
        add(InputHintBoost, @[], stick ? @"B2 / B4" : keys[5]);
        add(InputHintCamera, @[], stick ? @"B3" : @"C");
        add(InputHintPause, @[], @"Esc / M");
        name = name ?: L10n(stick ? @"input.joystick" : @"controls.device.keyboard");
        confirmSymbol = stick ? nil : @"return";
        confirmText = stick ? @"B1" : nil;
    }
    return [[InputGuide alloc] initWithScheme:scheme name:name bindings:bindings confirmSymbol:confirmSymbol text:confirmText];
}
