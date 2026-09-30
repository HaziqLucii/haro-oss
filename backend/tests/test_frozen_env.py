from __future__ import annotations

from haro.frozen_env import restore_host_library_path


def test_bundle_path_is_dropped_when_the_host_had_none():
    env = {"LD_LIBRARY_PATH": "/tmp/.mount_x/usr/lib/haro/backend/haro-backend/_internal", "HOME": "/h"}
    restore_host_library_path(env)
    assert env == {"HOME": "/h"}


def test_the_hosts_own_value_comes_back():
    env = {"LD_LIBRARY_PATH": "/bundle/_internal", "LD_LIBRARY_PATH_ORIG": "/opt/cuda/lib64"}
    restore_host_library_path(env)
    assert env == {"LD_LIBRARY_PATH": "/opt/cuda/lib64"}


def test_macos_dyld_path_too():
    env = {"DYLD_LIBRARY_PATH": "/bundle/_internal"}
    restore_host_library_path(env)
    assert env == {}
