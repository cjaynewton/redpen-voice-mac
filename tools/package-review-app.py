#!/usr/bin/env python3
"""Package a local review app from an existing release build. Never installs or starts the app."""
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
products = root / '.build/out/Products/Release'
if not products.is_dir():
    products = root / '.build/release'
app = root / 'build/Redpen Voice Review.app'
if app.exists():
    raise SystemExit(f'Refusing to replace existing review app: {app}')
for name in ['RedpenVoice', 'Sparkle.framework', 'mlx-swift_Cmlx.bundle', 'swift-transformers_Hub.bundle']:
    if not (products / name).exists():
        raise SystemExit(f'Missing release product: {products / name}')
contents = app / 'Contents'
for name in ['MacOS', 'Resources', 'Frameworks']:
    (contents / name).mkdir(parents=True)
shutil.copy2(products / 'RedpenVoice', contents / 'MacOS/RedpenVoice')
shutil.copytree(products / 'Sparkle.framework', contents / 'Frameworks/Sparkle.framework', symlinks=True)
shutil.copytree(root / 'Resources/Fonts', contents / 'Resources/Fonts')
for name in ['mlx-swift_Cmlx.bundle', 'swift-transformers_Hub.bundle']:
    shutil.copytree(products / name, contents / 'Resources' / name, symlinks=True)
shutil.copy2(root / 'Resources/Icon/AppIcon.icns', contents / 'Resources/AppIcon.icns')
# A separate identity and no update feed keep this local build separate from the installed app.
info = dict(CFBundleIdentifier='io.github.redpen-voice.talking-bar-review', CFBundleName='Redpen Voice Review',
            CFBundleExecutable='RedpenVoice', CFBundleIconFile='AppIcon', CFBundlePackageType='APPL',
            CFBundleShortVersionString='0.12.2', CFBundleVersion='14', LSMinimumSystemVersion='26.0',
            LSUIElement=True, SUEnableAutomaticChecks=False,
            NSMicrophoneUsageDescription='Redpen Voice records speech when you choose to dictate.',
            NSSpeechRecognitionUsageDescription='Redpen Voice turns your speech into text on this Mac.',
            NSAudioCaptureUsageDescription='Redpen Voice captures meeting audio when you choose to record.',
            NSAppleEventsUsageDescription='Redpen Voice pauses and resumes media during dictation.')
with (contents / 'Info.plist').open('wb') as f:
    plistlib.dump(info, f)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
