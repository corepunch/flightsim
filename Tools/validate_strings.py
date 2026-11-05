#!/usr/bin/env python3
"""Validate the string catalogs and the UI theme against the code that reads them.

- Resources/Strings/en.json has every key the sources name (L10n, L10nFormat,
  L10nList, and key literals passed to them indirectly);
- every other locale has a name and direction, only keys English has, and
  the same format specifiers, in the same order, as English;
- Resources/UI/theme.json has every colour, font and metric UI.h names;
- every catalog key a screen layout (Resources/UI/menus/*.json) names exists, and
  every layout the code loads is there.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STRINGS = ROOT / "Resources/Strings"
THEME = ROOT / "Resources/UI/theme.json"
STYLE = ROOT / "Sources/Engine/UI/UI.h"

# Catalog keys are dotted, under one of these areas. Any string literal of
# that shape in the sources counts as a key, so keys picked by a ternary or
# from an array are covered too.
AREAS = ("app", "audio", "briefing", "browser", "cockpit", "combat", "controls", "debrief", "game", "hud",
         "input", "loading", "menu", "mission", "missions", "net", "part", "pause", "story", "touch", "units")
KEY = re.compile(r'@"((?:%s)(?:\.[a-z0-9_]+)+)"' % "|".join(AREAS))
FILES = (".dylib", ".json", ".png", ".jpg", ".cfg")   # file names that look like keys
# Keys built at run time from a prefix: the catalog must hold these.
DYNAMIC = {"briefing.subsystem.": ["core", "engine", "shield", "turret"]}
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])")


def specifiers(text):
    return [s for s in SPEC.findall(text) if s != "%"]


def values(value):
    return value if isinstance(value, list) else [value]


def main():
    catalogs = {}
    for path in sorted(STRINGS.glob("*.json")):
        catalogs[path.stem] = json.loads(path.read_text(encoding="utf-8"))
    assert "en" in catalogs, "Resources/Strings/en.json is missing"
    english = catalogs["en"]["strings"]

    used = set()
    for source in [*(ROOT / "Sources").rglob("*.m"), *(ROOT / "Games").glob("*/Game/*.m")]:
        used.update(k for k in KEY.findall(source.read_text(encoding="utf-8")) if not k.endswith(FILES))
    # Screen layouts name catalog keys in "text"/"detail" ("$name" is a variable).
    layouts = sorted((ROOT / "Resources/UI/menus").glob("*.json"))
    for path in layouts:
        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in ("text", "detail") and isinstance(value, str) and not value.startswith("$"):
                        used.add(value)
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(json.loads(path.read_text(encoding="utf-8")))
    for prefix, names in DYNAMIC.items():
        used.update(prefix + name for name in names)
    missing = sorted(used - english.keys())
    assert not missing, f"en.json lacks keys the code uses: {missing}"
    unused = sorted(k for k in english.keys() - used)
    assert not unused, f"en.json has keys no code uses: {unused}"

    # A game's catalogs (Games/<name>/Strings) layer over the engine's: they
    # override engine keys, so they hold only English keys, of the same kind
    # and format, and need no name or direction of their own.
    overlays = 0
    for path in sorted((ROOT / "Games").glob("*/Strings/*.json")):
        overlays += 1
        locale = f"{path.parent.parent.name}/{path.stem}"
        strings = json.loads(path.read_text(encoding="utf-8")).get("strings")
        assert isinstance(strings, dict), f"{locale}: no strings"
        for key, value in strings.items():
            assert key in english, f"{locale}: {key} is not an engine key"
            items, reference = values(value), values(english[key])
            assert isinstance(value, list) == isinstance(english[key], list), f"{locale}: {key} differs from English in kind"
            for item in items:
                assert isinstance(item, str), f"{locale}: {key} must be text or a list of text"
                assert specifiers(item) == specifiers(reference[0]), \
                    f"{locale}: {key} has format {specifiers(item)}, English has {specifiers(reference[0])}"

    for locale, catalog in catalogs.items():
        assert isinstance(catalog.get("name"), str) and catalog.get("direction") in ("ltr", "rtl"), \
            f"{locale}: needs a name and direction ltr/rtl"
        strings = catalog.get("strings")
        assert isinstance(strings, dict), f"{locale}: no strings"
        for key, value in strings.items():
            assert key in english, f"{locale}: {key} is not an English key"
            items, reference = values(value), values(english[key])
            assert all(isinstance(v, str) and v for v in items), f"{locale}: {key} must be text or a list of text"
            assert isinstance(value, list) == isinstance(english[key], list), f"{locale}: {key} differs from English in kind"
            for item in items:
                assert specifiers(item) == specifiers(reference[0]), \
                    f"{locale}: {key} has format {specifiers(item)}, English has {specifiers(reference[0])}"

    theme = json.loads(THEME.read_text(encoding="utf-8"))
    style = STYLE.read_text(encoding="utf-8")
    for section, call in (("colors", "UIThemeColor"), ("fonts", "UIThemeFont"), ("metrics", "UIThemeMetric")):
        for name in re.findall(call + r'\(@"(\w+)"\)', style):
            value = theme.get(section, {}).get(name)
            if section == "colors":
                assert isinstance(value, list) and len(value) == 3 and all(0 <= c <= 1 for c in value), \
                    f"theme.json: colors.{name} must be three numbers 0..1"
            elif section == "fonts":
                assert isinstance(value, str) and value, f"theme.json: fonts.{name} missing"
            else:
                assert isinstance(value, (int, float)), f"theme.json: metrics.{name} missing"

    # Every layout the code loads exists.
    named = set()
    for source in (ROOT / "Sources").rglob("*.m"):
        named.update(re.findall(r'\[UILayout named:@"(\w+)"\]', source.read_text(encoding="utf-8")))
    missing_layouts = sorted(n for n in named if not (ROOT / "Resources/UI/menus" / f"{n}.json").is_file())
    assert not missing_layouts, f"layouts the code loads but Resources/UI/menus lacks: {missing_layouts}"

    # Colours and fonts a layout names must be in the theme.
    for path in layouts:
        def check(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in ("color", "stroke", "fill"):
                        name = value[0] if isinstance(value, list) else value
                        assert name in theme["colors"], f"{path.name}: unknown theme colour {name!r}"
                    elif key == "font":
                        assert value in theme["fonts"], f"{path.name}: unknown theme font {value!r}"
                    else:
                        check(value)
            elif isinstance(node, list):
                for value in node:
                    check(value)
        check(json.loads(path.read_text(encoding="utf-8")))

    print(f"PASS: {len(english)} strings in {len(catalogs)} locales, {len(used)} used by the code and "
          f"{len(layouts)} layouts, {overlays} game catalogs; theme complete")


if __name__ == "__main__":
    main()
