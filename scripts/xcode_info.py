"""Write the Info.plists for Xcode builds: xtool's files plus the keys xtool
adds itself. The extension gets the app's version and build number (App Store
Connect rejects a mismatch). Prints "<version> <build>".
Used by scripts/xcode-prepare.sh.

Usage: xcode_info.py <build-suffix> <app src> <app dst> <ext src> <ext dst>"""
import plistlib, sys

suffix, app_src, app_dst, ext_src, ext_dst = sys.argv[1:6]

def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)

def dump(info, path):
    with open(path, "wb") as f:
        plistlib.dump(info, f)

common = {
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "$(PRODUCT_BUNDLE_PACKAGE_TYPE)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleDevelopmentRegion": "en",
}

app = load(app_src)
version = app["CFBundleShortVersionString"]
build = app["CFBundleVersion"] + (f".{suffix}" if suffix else "")
app.update(common)
app.update({
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "LSRequiresIPhoneOS": True,
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "UISupportedInterfaceOrientations~ipad": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
})
dump(app, app_dst)

ext = load(ext_src)
ext.update(common)
ext.update({"CFBundleShortVersionString": version, "CFBundleVersion": build})
dump(ext, ext_dst)

print(version, build)
