"""Generate Kestrel Frontier's native iOS and macOS project using only local files."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

from pbxproj import load

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "KestrelFrontier.xcodeproj"
GAME = "KestrelFrontier"
PRODUCT = f"{GAME}.app"
# The game the app builds with (Games/<name>; build.sh and Makefile: GAME).
DEFAULT_GAME = "KestrelFrontier"
MAC_ONLY = {"FXRecorder.m", "GameView.m", "Input.m", "main.m"}
IOS_ONLY = {"GameViewIOS.m", "InputIOS.m", "mainIOS.m", "TouchFlightControls.m"}
IOS_FRAMEWORKS = (
    "UIKit", "SceneKit", "SpriteKit", "Metal", "CoreGraphics", "CoreText", "QuartzCore",
    "ImageIO", "GameController", "AVFoundation",
)
MAC_FRAMEWORKS = (
    "Cocoa", "SceneKit", "SpriteKit", "Metal", "CoreGraphics", "CoreText", "QuartzCore",
    "IOKit", "Carbon", "ImageIO", "AVFoundation", "CoreMedia", "CoreVideo",
)
PRESERVED = ("CODE_SIGN", "DEVELOPMENT_TEAM", "PROVISIONING_PROFILE", "PRODUCT_BUNDLE_IDENTIFIER")


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != content:
        path.write_bytes(content)


def encode(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        if not value:
            return "{}"
        entries = "".join(f"{indent}\t{encode(key)} = {encode(item, depth + 1)};\n"
                          for key, item in value.items())
        return "{\n" + entries + indent + "}"
    if isinstance(value, list):
        if not value:
            return "()"
        entries = "".join(f"{indent}\t{encode(item, depth + 1)},\n" for item in value)
        return "(\n" + entries + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


class Project:
    def __init__(self, existing):
        self.objects = {}
        self.existing = existing

    def add(self, key, kind, **fields):
        identifier = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
        if identifier in self.objects:
            raise ValueError(f"Duplicate project object: {key}")
        self.objects[identifier] = dict(isa=kind, **fields)
        return identifier

    def configurations(self, key, settings, overrides):
        configurations = []
        for name in ("Debug", "Release"):
            debug = name == "Debug"
            values = dict(settings, GCC_OPTIMIZATION_LEVEL="0" if debug else "2",
                          DEBUG_INFORMATION_FORMAT="dwarf" if debug else "dwarf-with-dsym",
                          ONLY_ACTIVE_ARCH="YES" if debug else "NO")
            config = self.add(f"{key}/{name}", "XCBuildConfiguration", name=name, buildSettings=values)
            previous = self.existing.get(config, {}).get("buildSettings", {})
            values.update({field: value for field, value in previous.items() if field.startswith(PRESERVED)})
            # Explicit options also replace any SDK-specific copies of that setting.
            for field in list(values):
                if field.partition("[")[0] in overrides:
                    del values[field]
            values.update(overrides)
            configurations.append(config)
        return self.add(f"{key}/configs", "XCConfigurationList", buildConfigurations=configurations,
                        defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")

    def source_group(self, directory, sources):
        children = []
        for path in sorted(directory.iterdir()):
            relative = path.relative_to(ROOT)
            if path.is_dir():
                children.append(self.source_group(path, sources))
                continue
            suffixes = {".h": "sourcecode.c.h", ".m": "sourcecode.c.objc", ".c": "sourcecode.c.c"}
            if path.suffix not in suffixes:
                continue
            reference = self.add(f"file/{relative}", "PBXFileReference", path=path.name,
                                 sourceTree="<group>", lastKnownFileType=suffixes[path.suffix])
            children.append(reference)
            if path.suffix == ".h":
                continue
            settings = {}
            # The mission runtime is engine code that links into game modules
            # (Makefile: MISSION_SOURCES), built like game code.
            mission = relative.parts[:2] == ("Sources", "Mission")
            game_code = relative.parts[0] == "Games"
            if path.suffix == ".m":
                prefix = (f"Games/{DEFAULT_GAME}/Game/Prefix.h" if game_code or mission
                          else "Sources/Prefix.h" if relative.parts[1] != "Shared" else "")
                if prefix and (ROOT / prefix).is_file():
                    settings["COMPILER_FLAGS"] = f'-include "$(SRCROOT)/{prefix}"'
            fields = {"settings": settings} if settings else {}
            module = "Game" if game_code else "Shared" if relative.parts[1] == "Shared" else "Engine"
            for platform, files in sources.items():
                if platform == "ios" and module == "Engine" and path.name in MAC_ONLY:
                    continue
                if platform == "mac" and (module == "Game" or mission or path.name in IOS_ONLY):
                    continue
                if platform == "game" and module == "Engine" and not mission:
                    continue
                files.append(self.add(f"compile/{platform}/{relative}", "PBXBuildFile",
                                      fileRef=reference, **fields))
        return self.add(f"group/{directory.relative_to(ROOT)}", "PBXGroup", path=directory.name,
                        children=children, sourceTree="<group>")


def shared_scheme(target, name):
    path = BUNDLE / "xcshareddata/xcschemes" / f"{name}.xcscheme"
    reference = dict(BuildableIdentifier="primary", BlueprintIdentifier=target, BuildableName=PRODUCT,
                     BlueprintName=name, ReferencedContainer=f"container:{BUNDLE.name}")
    if path.exists():
        root = ET.parse(path).getroot()
        for buildable in root.iter("BuildableReference"):
            if buildable.get("BlueprintIdentifier") == target:
                buildable.attrib.update(reference)
        ET.indent(root)
        write(path, ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n")
        return  # Keep local launch arguments and environment settings from Xcode.
    root = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    build = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", **{
        f"buildFor{purpose}": "YES" for purpose in ("Testing", "Running", "Profiling", "Archiving", "Analyzing")
    })
    ET.SubElement(entry, "BuildableReference", **reference)
    ET.SubElement(root, "TestAction", buildConfiguration="Debug")
    for tag, configuration in (("LaunchAction", "Debug"), ("ProfileAction", "Release")):
        attributes = dict(buildConfiguration=configuration, useCustomWorkingDirectory="NO")
        if tag == "LaunchAction":
            attributes.update(selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                              selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0")
        action = ET.SubElement(root, tag, **attributes)
        runnable = ET.SubElement(action, "BuildableProductRunnable", runnableDebuggingMode="0")
        ET.SubElement(runnable, "BuildableReference", **reference)
    ET.SubElement(root, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(root, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    ET.indent(root)
    write(path, ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n")


def generate(args):
    path = BUNDLE / "project.pbxproj"
    existing = load(path)["objects"] if path.exists() else {}
    project = Project(existing)
    bundle_ids = {}
    for platform, source in (("ios", "Info-iOS.plist"), ("macos", "Info.plist")):
        info = plistlib.loads((ROOT / "Resources" / source).read_bytes())
        bundle_ids[platform] = info["CFBundleIdentifier"]
        info.pop("UIDeviceFamily", None)  # Xcode inserts this from TARGETED_DEVICE_FAMILY.
        info.update(CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleExecutable="$(EXECUTABLE_NAME)",
                    CFBundleName="Kestrel Frontier", CFBundleDisplayName="Kestrel Frontier")
        write(BUNDLE / f"Generated/{platform}-Info.plist", plistlib.dumps(info))
    common = dict(
        CLANG_ENABLE_OBJC_ARC="YES", ENABLE_USER_SCRIPT_SANDBOXING="NO",
        ALWAYS_SEARCH_USER_PATHS="NO",
        GCC_C_LANGUAGE_STANDARD="gnu11", OTHER_CFLAGS=["$(inherited)", "-Wno-deprecated-declarations"],
        HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/Sources/Shared", f"$(SRCROOT)/Games/{DEFAULT_GAME}/Game"] +
                            [f"$(SRCROOT)/{path.relative_to(ROOT)}"
                             for path in sorted((ROOT / "Sources").iterdir()) if path.is_dir() and path.name != "Shared"],
    )
    app_settings = dict(
        PRODUCT_NAME=GAME, CODE_SIGN_STYLE="Automatic", GENERATE_INFOPLIST_FILE="NO",
        SKIP_INSTALL="NO", INSTALL_PATH="$(LOCAL_APPS_DIR)",
    )
    overrides = {key: value for key, value in (
        ("DEVELOPMENT_TEAM", args.team), ("PRODUCT_BUNDLE_IDENTIFIER", args.bundle_id)
    ) if value is not None}
    project_configs = project.configurations("project", common, overrides)
    ios_settings = dict(app_settings, SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
                        IPHONEOS_DEPLOYMENT_TARGET="16.0", TARGETED_DEVICE_FAMILY="1,2",
                        SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO",
                        PRODUCT_BUNDLE_IDENTIFIER=bundle_ids["ios"],
                        INFOPLIST_FILE="$(PROJECT_FILE_PATH)/Generated/ios-Info.plist",
                        ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                        OTHER_LDFLAGS=["$(inherited)"] +
                        [item for framework in IOS_FRAMEWORKS for item in ("-framework", framework)])
    mac_platform = dict(SDKROOT="macosx", SUPPORTED_PLATFORMS="macosx", MACOSX_DEPLOYMENT_TARGET="13.0")
    mac_settings = dict(app_settings, **mac_platform,
                        PRODUCT_BUNDLE_IDENTIFIER=bundle_ids["macos"],
                        CODE_SIGN_ENTITLEMENTS="$(SRCROOT)/Resources/KestrelFrontier-macOS.entitlements",
                        INFOPLIST_FILE="$(PROJECT_FILE_PATH)/Generated/macos-Info.plist",
                        OTHER_LDFLAGS=["$(inherited)"] +
                        [item for framework in MAC_FRAMEWORKS for item in ("-framework", framework)])
    game_settings = dict(mac_platform, PRODUCT_NAME=DEFAULT_GAME, EXECUTABLE_PREFIX="",
                         MACH_O_TYPE="mh_dylib", SKIP_INSTALL="YES", GCC_SYMBOLS_PRIVATE_EXTERN="YES",
                         DYLIB_INSTALL_NAME_BASE="@rpath", CODE_SIGN_STYLE="Automatic",
                         OTHER_LDFLAGS=["$(inherited)", "-framework", "Foundation"])
    target_configs = project.configurations("target", ios_settings, overrides)
    mac_configs = project.configurations("target/mac", mac_settings, overrides)
    game_overrides = {key: value for key, value in overrides.items() if key != "PRODUCT_BUNDLE_IDENTIFIER"}
    game_configs = project.configurations("target/game", game_settings, game_overrides)

    sources = {"ios": [], "mac": [], "game": []}
    source_group = project.source_group(ROOT / "Sources", sources)
    game_group = project.source_group(ROOT / "Games" / DEFAULT_GAME / "Game", sources)
    games_group = project.add(f"group/Games/{DEFAULT_GAME}", "PBXGroup", path=f"Games/{DEFAULT_GAME}",
                              children=[game_group], sourceTree="<group>")
    resources_ref = project.add("resources/ref", "PBXFileReference", path="Resources", sourceTree="<group>",
                                lastKnownFileType="folder")
    assets_ref = project.add("assets/ref", "PBXFileReference", path="Resources/Assets.xcassets",
                             sourceTree="<group>", lastKnownFileType="folder.assetcatalog")
    assets_file = project.add("assets/file", "PBXBuildFile", fileRef=assets_ref)
    assets_phase = project.add("assets/phase", "PBXResourcesBuildPhase", files=[assets_file],
                               buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    compile_phases = {
        platform: project.add(f"compile/{platform}", "PBXSourcesBuildPhase", files=files,
                              buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
        for platform, files in sources.items()
    }
    resource_phases = {}
    for platform in ("ios", "mac"):
        # The iOS app links one game in, so it ships only that game's folder.
        games = f"GAMES={DEFAULT_GAME} " if platform == "ios" else ""
        script = ('set -e\ncd "$SRCROOT"\n' + games + '/bin/zsh Tools/bundle-resources.sh '
                  '"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH" '
                  '"$PROJECT_TEMP_DIR/KestrelFrontierResources"\n')
        if platform == "mac":
            script += 'cp -p Resources/AppIcon.icns "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"\n'
        resource_phases[platform] = project.add(
            f"resources/phase/{platform}", "PBXShellScriptBuildPhase", name="Bundle runtime resources",
            shellPath="/bin/zsh", shellScript=script, buildActionMask=2147483647,
            runOnlyForDeploymentPostprocessing=0, alwaysOutOfDate=1, files=[])
    product = project.add("product", "PBXFileReference", path=PRODUCT, sourceTree="BUILT_PRODUCTS_DIR",
                          explicitFileType="wrapper.application")
    mac_product = project.add("product/mac", "PBXFileReference", path=PRODUCT, sourceTree="BUILT_PRODUCTS_DIR",
                              explicitFileType="wrapper.application")
    game_product = project.add("product/game", "PBXFileReference", path=f"{DEFAULT_GAME}.dylib", sourceTree="BUILT_PRODUCTS_DIR",
                               explicitFileType="compiled.mach-o.dylib")
    products = project.add("products", "PBXGroup", name="Products", children=[product, mac_product, game_product],
                           sourceTree="<group>")
    main_group = project.add("group/main", "PBXGroup", children=[source_group, games_group, resources_ref, assets_ref, products],
                             sourceTree="<group>")
    target = project.add("target", "PBXNativeTarget", name=f"{GAME}-iOS", productName=GAME,
                         productReference=product, productType="com.apple.product-type.application",
                         buildConfigurationList=target_configs,
                         buildPhases=[compile_phases["ios"], assets_phase, resource_phases["ios"]],
                         buildRules=[], dependencies=[])
    game_target = project.add("target/game", "PBXNativeTarget", name=f"{GAME}-Game", productName=DEFAULT_GAME,
                              productReference=game_product, productType="com.apple.product-type.library.dynamic",
                              buildConfigurationList=game_configs, buildPhases=[compile_phases["game"]],
                              buildRules=[], dependencies=[])
    proxy = project.add("game/proxy", "PBXContainerItemProxy",
                        containerPortal=hashlib.sha256(b"project").hexdigest()[:24].upper(), proxyType=1,
                        remoteGlobalIDString=game_target, remoteInfo=f"{GAME}-Game")
    dependency = project.add("game/dependency", "PBXTargetDependency", target=game_target, targetProxy=proxy)
    embed_file = project.add("game/embed/file", "PBXBuildFile", fileRef=game_product,
                             settings={"ATTRIBUTES": ["CodeSignOnCopy"]})
    embed_phase = project.add("game/embed", "PBXCopyFilesBuildPhase", name="Embed game module",
                              dstPath="", dstSubfolderSpec=13, files=[embed_file],
                              buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    mac_target = project.add("target/mac", "PBXNativeTarget", name=f"{GAME}-macOS", productName=GAME,
                             productReference=mac_product, productType="com.apple.product-type.application",
                             buildConfigurationList=mac_configs,
                             buildPhases=[compile_phases["mac"], embed_phase, resource_phases["mac"]],
                             buildRules=[], dependencies=[dependency])
    root = project.add("project", "PBXProject", buildConfigurationList=project_configs,
                       compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"],
                       mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="",
                       targets=[target, mac_target, game_target])
    project.objects[root]["attributes"] = existing.get(root, {}).get("attributes", {"LastUpgradeCheck": "1600"})
    contents = encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=project.objects, rootObject=root))
    write(path, ("// !$*UTF8*$!\n" + contents + "\n").encode())
    shared_scheme(target, f"{GAME}-iOS")
    shared_scheme(mac_target, f"{GAME}-macOS")
    print(BUNDLE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", help="Apple development team for physical devices")
    parser.add_argument("--bundle-id", help="Override the app's bundle identifier")
    try:
        generate(parser.parse_args())
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
