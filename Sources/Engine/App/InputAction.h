#pragma once
#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, InputAction) {
    InputActionToggleCamera = 1 << 0,
    InputActionSwapAxes     = 1 << 1,
    InputActionInvertThrottle = 1 << 2,
    InputActionInvertMouse  = 1 << 3,
    InputActionRestart      = 1 << 4,
    InputActionToggleHelp   = 1 << 5,
    InputActionUp           = 1 << 6,   // menus
    InputActionDown         = 1 << 7,
    InputActionLeft         = 1 << 8,
    InputActionRight        = 1 << 9,
    InputActionConfirm      = 1 << 10,  // Return / Enter / stick button 1
    InputActionBack         = 1 << 11,  // Esc (mouse free) / M / Backspace
    InputActionTarget       = 1 << 12,  // T / stick button 6: next target
    InputActionSecondary    = 1 << 13,  // G / stick button 5: launch the secondary weapon
    InputActionMultiplayer  = 1 << 14,  // N: the LAN game browser
};
