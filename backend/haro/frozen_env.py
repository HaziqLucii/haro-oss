"""Give the processes haro starts the host's library path, not the frozen bundle's.

The PyInstaller bootloader points ``LD_LIBRARY_PATH`` (``DYLD_LIBRARY_PATH`` on macOS)
at the bundle's ``_internal`` dir so the frozen Python finds its own libssl, libffi,
libsqlite. Every child inherits that: setup scripts, ``git``, the gate's ``node``, the
agent CLI. A host ``node`` built against a newer OpenSSL then dies at load with
"version OPENSSL_3.x not found", so setup and every Vitest gate fail in the AppImage.

The dynamic loader reads these variables once, at process start, so resetting them in
``os.environ`` afterwards changes only what children inherit, never the frozen
process's own library lookups.
"""

from __future__ import annotations

from collections.abc import MutableMapping

_VARS = ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH")


def restore_host_library_path(env: MutableMapping[str, str]) -> None:
    """Put back the value the bootloader saved in ``<VAR>_ORIG``, or drop the variable
    when the host had none."""
    for var in _VARS:
        orig = env.pop(f"{var}_ORIG", None)
        if orig:
            env[var] = orig
        else:
            env.pop(var, None)
