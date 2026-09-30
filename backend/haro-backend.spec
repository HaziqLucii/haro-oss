# -*- mode: python ; coding: utf-8 -*-
from PyInstaller.utils.hooks import collect_submodules

hiddenimports = ['uvloop', 'httptools', 'watchfiles', 'aiosqlite']
hiddenimports += collect_submodules('uvicorn')
hiddenimports += collect_submodules('websockets')


a = Analysis(
    ['desktop_app.py'],
    pathex=[],
    binaries=[],
    datas=[('haro/assets', 'haro/assets'), ('haro/adapters/test_runner/vitest_reporter.mjs', 'haro/adapters/test_runner')],
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    # Size only, not startup time (onedir loads modules lazily). pytest/pluggy
    # ride along today because requirements.txt lists pytest for the test suite,
    # but nothing under haro/ imports it at runtime — same for the stdlib bits
    # below, which PyInstaller's dependency walk pulls in transitively but the
    # app never touches.
    excludes=['pytest', '_pytest', 'pluggy', 'tkinter', 'pydoc', 'doctest', 'lib2to3'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

# onedir (EXE bootloader + COLLECT), NOT onefile: a onefile build re-unpacks the
# whole bundle (interpreter + libs + assets) into a temp dir on EVERY launch,
# which is the dominant desktop-app cold-start cost. onedir keeps those files
# unpacked on disk inside the .app/AppImage, so launch skips the unpack. UPX is
# off too — it shrinks the binary but must decompress at startup (and trips AV
# false-positives), trading the exact thing we're optimising. The frozen dir is
# `dist/haro-backend/` (the `haro-backend` exe + `_internal/`); desktop/main.js
# launches the exe INSIDE it, and electron-builder ships the dir's contents.
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='haro-backend',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='haro-backend',
)
