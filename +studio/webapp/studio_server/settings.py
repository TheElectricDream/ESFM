"""Studio settings kept between sessions (.studio_cache/settings.json).

The remote camera's SSH login lives here, password included, in plain text
on this computer: use an SSH key (key_file) instead where you can.
"""
import copy

from .common import cache, read_json, write_json

DEFAULTS = {
    "remote": {"host": "192.168.1.115", "user": "spot-vision", "password": "srcl2023", "port": 22,
               "key_file": "", "remote_dir": "~/.event-studio", "python": "python3", "serial": ""},
}


def _file():
    return cache() / "settings.json"


def get(section):
    s = read_json(_file(), {})
    out = copy.deepcopy(DEFAULTS.get(section, {}))
    out.update(s.get(section, {}))
    return out


def put(section, values):
    s = read_json(_file(), {})
    cur = get(section)
    for k, v in values.items():
        if k in DEFAULTS.get(section, {}):
            cur[k] = type(DEFAULTS[section][k])(v) if v is not None else DEFAULTS[section][k]
    s[section] = cur
    write_json(_file(), s)
    return cur
