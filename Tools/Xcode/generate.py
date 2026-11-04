"""Generate SpaceFight's native iPhone/iPad project using only local files."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

from pbxproj import load

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "SpaceFight.xcodeproj"
TARGET = "SpaceFight-iOS"
PRODUCT = "SpaceFight.app"
MAC_ONLY = {"FXRecorder.m", "GameView.m", "Input.m", "main.m"}
FRAMEWORKS = (
    "UIKit", "SceneKit", "SpriteKit", "Metal", "CoreGraphics", "QuartzCore",
    "ImageIO", "GameController", "AVFoundation",
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
            if path.suffix == ".h" or (relative.parts[1] == "Engine" and path.name in MAC_ONLY):
                continue
            settings = {}
            if path.suffix == ".m":
                prefix = f'Sources/{relative.parts[1]}/Prefix.h'
                if (ROOT / prefix).is_file():
                    settings["COMPILER_FLAGS"] = f'-include "$(SRCROOT)/{prefix}"'
            fields = {"settings": settings} if settings else {}
            sources.append(self.add(f"compile/{relative}", "PBXBuildFile", fileRef=reference, **fields))
        return self.add(f"group/{directory.relative_to(ROOT)}", "PBXGroup", path=directory.name,
                        children=children, sourceTree="<group>")


def shared_scheme(target):
    path = BUNDLE / "xcshareddata/xcschemes" / f"{TARGET}.xcscheme"
    if path.exists():
        return  # Keep local launch arguments and environment settings from Xcode.
    root = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    build = ET.SubElement(root, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", **{
        f"buildFor{purpose}": "YES" for purpose in ("Testing", "Running", "Profiling", "Archiving", "Analyzing")
    })
    reference = dict(BuildableIdentifier="primary", BlueprintIdentifier=target, BuildableName=PRODUCT,
                     BlueprintName=TARGET, ReferencedContainer=f"container:{BUNDLE.name}")
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
    info = plistlib.loads((ROOT / "Resources/Info-iOS.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    info.pop("UIDeviceFamily", None)  # Xcode inserts this from TARGETED_DEVICE_FAMILY.
    info.update(CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleExecutable="$(EXECUTABLE_NAME)")
    common = dict(
        SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator",
        IPHONEOS_DEPLOYMENT_TARGET="16.0", TARGETED_DEVICE_FAMILY="1,2",
        SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO",
        CLANG_ENABLE_OBJC_ARC="YES", ENABLE_USER_SCRIPT_SANDBOXING="NO",
        ALWAYS_SEARCH_USER_PATHS="NO",
        GCC_C_LANGUAGE_STANDARD="gnu11", OTHER_CFLAGS=["$(inherited)", "-Wno-deprecated-declarations"],
        HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/Sources/Shared", "$(SRCROOT)/Sources/Game"] +
                            [f"$(SRCROOT)/{path.relative_to(ROOT)}"
                             for path in sorted((ROOT / "Sources/Engine").iterdir()) if path.is_dir()],
    )
    target_settings = dict(
        PRODUCT_NAME="SpaceFight", PRODUCT_BUNDLE_IDENTIFIER=bundle_id, CODE_SIGN_STYLE="Automatic",
        INFOPLIST_FILE="$(PROJECT_FILE_PATH)/Generated/ios-Info.plist", GENERATE_INFOPLIST_FILE="NO",
        ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
        OTHER_LDFLAGS=["$(inherited)"] + [item for framework in FRAMEWORKS for item in ("-framework", framework)],
        SKIP_INSTALL="NO", INSTALL_PATH="$(LOCAL_APPS_DIR)",
    )
    overrides = {key: value for key, value in (
        ("DEVELOPMENT_TEAM", args.team), ("PRODUCT_BUNDLE_IDENTIFIER", args.bundle_id)
    ) if value is not None}
    project_configs = project.configurations("project", common, overrides)
    target_configs = project.configurations("target", target_settings, overrides)

    sources = []
    source_group = project.source_group(ROOT / "Sources", sources)
    resources_ref = project.add("resources/ref", "PBXFileReference", path="Resources", sourceTree="<group>",
                                lastKnownFileType="folder")
    assets_ref = project.add("assets/ref", "PBXFileReference", path="Resources/Assets.xcassets",
                             sourceTree="<group>", lastKnownFileType="folder.assetcatalog")
    assets_file = project.add("assets/file", "PBXBuildFile", fileRef=assets_ref)
    assets_phase = project.add("assets/phase", "PBXResourcesBuildPhase", files=[assets_file],
                               buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    compile_phase = project.add("compile", "PBXSourcesBuildPhase", files=sources,
                                buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0)
    resources_phase = project.add("resources/phase", "PBXShellScriptBuildPhase", name="Bundle runtime resources",
                                  shellPath="/bin/zsh", shellScript=
                                  'set -e\ncd "$SRCROOT"\n/bin/zsh Tools/bundle-resources.sh '
                                  '"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH" '
                                  '"$PROJECT_TEMP_DIR/SpaceFightResources"\n',
                                  buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0,
                                  alwaysOutOfDate=1, files=[])
    product = project.add("product", "PBXFileReference", path=PRODUCT, sourceTree="BUILT_PRODUCTS_DIR",
                          explicitFileType="wrapper.application")
    products = project.add("products", "PBXGroup", name="Products", children=[product], sourceTree="<group>")
    main_group = project.add("group/main", "PBXGroup", children=[source_group, resources_ref, assets_ref, products],
                             sourceTree="<group>")
    target = project.add("target", "PBXNativeTarget", name=TARGET, productName="SpaceFight",
                         productReference=product, productType="com.apple.product-type.application",
                         buildConfigurationList=target_configs, buildPhases=[compile_phase, assets_phase, resources_phase],
                         buildRules=[], dependencies=[])
    root = project.add("project", "PBXProject", buildConfigurationList=project_configs,
                       compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"],
                       mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="",
                       targets=[target])
    project.objects[root]["attributes"] = existing.get(root, {}).get("attributes", {"LastUpgradeCheck": "1600"})
    contents = encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=project.objects, rootObject=root))
    write(path, ("// !$*UTF8*$!\n" + contents + "\n").encode())
    write(BUNDLE / "Generated/ios-Info.plist", plistlib.dumps(info))
    shared_scheme(target)
    print(BUNDLE)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team", help="Apple development team for physical devices")
    parser.add_argument("--bundle-id", help="Override the app's bundle identifier")
    try:
        generate(parser.parse_args())
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
