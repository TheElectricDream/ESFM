#!/usr/bin/env python3
"""Generate the self-contained deployable package from the production tree.

Copies the +io, +geom, +surface, +track, +warm, +traj, +adjust and +prog
packages into +<package>/+<pkg>/ with every package reference rewritten to
<package>.<pkg>, writes <package>.config (arguments instead of hard-coded
paths, plus any parameter overrides), <package>.run_pipeline (main.m as a
function, no figures) and <package>.build_standalone (MATLAB Compiler
build), and copies the calibration file config.m names. The generated
package has no dependency on the prototyping code at run time; rerun this
script after changing production (the Studio's Build page does).

Usage:
    python3 diagnostics/make_deployable.py [--package deployable]
                                           [--overrides overrides.json]
overrides.json maps a config path to a MATLAB expression, e.g.
{"init.thin_every": "2", "adjust.solver": "'schur'"}; they are appended to
the generated config, after the production values.
"""
import argparse
import json
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKGS = ["io", "geom", "surface", "track", "warm", "traj", "adjust", "prog"]
SKIP = {("surface", "compute_baseline.m")}
REF = re.compile(r"(?<![\w.])(io|geom|surface|track|warm|traj|adjust|prog)\.(?=[A-Za-z_])")
PATH_RE = re.compile(r"^[A-Za-z]\w*(\.[A-Za-z]\w*)+$")


def sub_one(text, pattern, repl, what, flags=0):
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f"make_deployable: could not find {what} in config.m")
    return new


def calibration_name(cfg_text):
    m = re.search(r"cfg\.camera\.calibration_xml\s*=\s*(.*?);", cfg_text, re.S)
    if not m:
        raise SystemExit("make_deployable: cfg.camera.calibration_xml not found in config.m")
    parts = re.findall(r"'([^']*)'", m.group(1))
    if not parts:
        raise SystemExit("make_deployable: cfg.camera.calibration_xml is not a literal file name")
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", default="deployable")
    ap.add_argument("--overrides", type=Path)
    args = ap.parse_args()
    pkg_name = args.package
    if not re.fullmatch(r"[A-Za-z]\w*", pkg_name):
        raise SystemExit(f"make_deployable: invalid package name {pkg_name!r}")
    overrides = {}
    if args.overrides:
        overrides = json.loads(args.overrides.read_text())
        for k in overrides:
            if not PATH_RE.match("cfg." + k):
                raise SystemExit(f"make_deployable: invalid override path {k!r}")

    out = ROOT / f"+{pkg_name}"

    def rewrite(text: str) -> str:
        return REF.sub(lambda m: f"{pkg_name}.{m.group(1)}.", text)

    if out.exists():
        shutil.rmtree(out)
    out.mkdir()
    n = 0
    for pkg in PKGS:
        src = ROOT / f"+{pkg}"
        dst = out / f"+{pkg}"
        dst.mkdir()
        for f in sorted(src.glob("*.m")):
            if (pkg, f.name) in SKIP:
                continue
            text = rewrite(f.read_text())
            if pkg == "io" and f.name == "read_calibration.m":
                text = re.sub(r"    xml_path = fullfile\(fileparts\(which\('config'\)\),\.\.\.\n\s*camera_cfg\.calibration_xml\);\n",
                              "    xml_path = camera_cfg.calibration_xml;   % full path (config)\n", text)
                text = re.sub(r"\s*errordlg\(errMsg, 'Calibration File Missing', 'modal'\);\n", "\n", text)
                if "which('config')" in text:
                    raise SystemExit("make_deployable: read_calibration.m no longer matches; update the rewrite")
            (dst / f.name).write_text(text)
            n += 1

    # config: arguments instead of the hard-coded recording and output folder
    cfg = (ROOT / "config.m").read_text()
    xml = calibration_name(cfg)
    if not (ROOT / xml).is_file():
        raise SystemExit(f"make_deployable: calibration file {xml} not found")
    body = cfg[cfg.index("\n", cfg.index("function cfg = config")) + 1:]
    body = sub_one(body, r"^[ \t]*cfg\.data\.hdf5_dir\s*=.*?\n", "    [cfg.data.hdf5_dir, name, ext] = fileparts(hdf5_path);\n", "cfg.data.hdf5_dir", re.M)
    body = sub_one(body, r"^[ \t]*cfg\.data\.hdf5_file\s*=.*?\n", "    cfg.data.hdf5_file    = [name ext];\n", "cfg.data.hdf5_file", re.M)
    body = sub_one(body, r"^[ \t]*cfg\.data\.start_time_s\s*=.*?\n", "    cfg.data.start_time_s = start_s;   % T0 [s]: first event time used\n", "cfg.data.start_time_s", re.M)
    body = sub_one(body, r"^[ \t]*cfg\.data\.end_time_s\s*=.*?\n", "    cfg.data.end_time_s   = end_s;     % T1 [s]: last event time used\n", "cfg.data.end_time_s", re.M)
    body = sub_one(body, r"^[ \t]*cfg\.camera\.calibration_xml\s*=.*?;[^\n]*\n",
                   "    cfg.camera.calibration_xml = fullfile(fileparts(mfilename('fullpath')), ...\n"
                   f"        '{xml}');   % bundled with the package\n", "cfg.camera.calibration_xml", re.M | re.S)
    body = sub_one(body, r"^[ \t]*cfg\.output\.dir\s*=.*?\n", "    cfg.output.dir                = output_dir;\n", "cfg.output.dir", re.M)
    body = rewrite(body)
    if overrides:
        end = body.rstrip().rfind("end")
        block = ["", "    % Parameter overrides from the Studio (not in config.m), "
                 + datetime.now().strftime("%Y-%m-%d %H:%M")]
        block += [f"    cfg.{k} = {v};" for k, v in overrides.items()]
        body = body[:end] + "\n".join(block) + "\nend\n"
    config_m = (
        "function cfg = config(hdf5_path, output_dir, start_s, end_s)\n"
        "    %   Configuration of the deployable pipeline: the production\n"
        "    %   constants of config.m (generated copy, see README.md) with the\n"
        "    %   recording, the time window and the output folder as arguments.\n"
        "    %\n"
        "    %   Inputs:\n"
        "    %       HDF5_PATH -> Char, event recording\n"
        "    %       OUTPUT_DIR -> Char, folder for the results\n"
        "    %       START_S, END_S -> Scalars, time window [s]\n"
        "    %\n"
        "    %   Outputs:\n"
        "    %       CFG -> Struct, contains user parameters.\n\n" + body)
    (out / "config.m").write_text(config_m)

    # run_pipeline: main.m as a function, without the figure at the end
    main_m = (ROOT / "main.m").read_text()
    # outputs main.m never reads (harmless in a script, flagged in a function)
    for old_s, new_s in [("[map, linfo] = prog.local_adjust", "[map, ~] = prog.local_adjust"),
                         ("\n    [scale, votes] = prog.closure_vote", "\n    [scale, ~] = prog.closure_vote"),
                         ("[scale, votes, scales] = prog.closure_vote", "[scale, votes] = prog.closure_vote")]:
        main_m = main_m.replace(old_s, new_s, 1)
    try:
        start = main_m.index("% Load in event data")
    except ValueError:
        raise SystemExit("make_deployable: main.m has no '% Load in event data' line")
    stop = main_m.find("viz.inspect_reconstruction(result);")
    if stop < 0:
        stop = len(main_m)
    body = rewrite(main_m[start:stop]).rstrip() + "\n"
    body = "\n".join(("    " + ln if ln.strip() else "") for ln in body.split("\n"))
    run_m = (
        "function result = run_pipeline(hdf5_path, output_dir, start_s, end_s)\n"
        "    %   Offline point-cloud reconstruction of a spinning rigid target from\n"
        "    %   an event recording: the entry point of the deployable pipeline\n"
        f"    %   ({pkg_name}.build_standalone compiles it). The stages are those of\n"
        "    %   main.m in the prototyping tree, as a function and without figures.\n"
        "    %\n"
        "    %   Inputs:\n"
        "    %       HDF5_PATH -> Char, event recording with datasets /timestamp [us],\n"
        "    %              /x, /y [px] and /polarity\n"
        "    %       OUTPUT_DIR -> Char, folder for result.mat, the PLY clouds and the\n"
        "    %              CSV tables (created if missing)\n"
        "    %       START_S, END_S -> Scalars or chars (command line), time window [s];\n"
        "    %              default 60 and 185\n"
        "    %\n"
        "    %   Outputs:\n"
        f"    %       RESULT -> Struct from {pkg_name}.prog.package_result\n\n"
        "    if nargin < 3 || isempty(start_s), start_s = 60; end\n"
        "    if nargin < 4 || isempty(end_s), end_s = 185; end\n"
        "    if ischar(start_s) || isstring(start_s), start_s = str2double(start_s); end\n"
        "    if ischar(end_s) || isstring(end_s), end_s = str2double(end_s); end\n"
        "    hdf5_path  = char(hdf5_path);\n"
        "    output_dir = char(output_dir);\n"
        "    assert(isfile(hdf5_path), 'Recording not found: %s', hdf5_path);\n"
        "    t_all = tic;\n\n"
        "    % Set up the configuration\n"
        f"    cfg = {pkg_name}.config(hdf5_path, output_dir, start_s, end_s);\n\n"
        + body +
        "\n    fprintf('Total: %f [sec]\\n', toc(t_all));\n"
        "end\n")
    (out / "run_pipeline.m").write_text(run_m)

    (out / "build_standalone.m").write_text(
        "function build_standalone(out_dir)\n"
        "    %   Compiles the deployable pipeline into a standalone application with\n"
        "    %   MATLAB Compiler. The executable takes the recording, the output\n"
        "    %   folder and optionally the time window:\n"
        "    %       posefromevents <recording.hdf5> <output_dir> [start_s end_s]\n"
        "    %   It runs on a machine with the MATLAB Runtime of this release (or a\n"
        "    %   full MATLAB installation) through run_posefromevents.sh <runtime root>.\n"
        "    %\n"
        "    %   Inputs:\n"
        "    %       OUT_DIR -> Char, build folder (default <repo>/build_<package>)\n"
        "    here = fileparts(mfilename('fullpath'));\n"
        "    root = fileparts(here);\n"
        "    if nargin < 1 || isempty(out_dir)\n"
        f"        out_dir = fullfile(root, 'build_{pkg_name}');\n"
        "    end\n"
        "    if ~isfolder(out_dir)\n"
        "        mkdir(out_dir);\n"
        "    end\n"
        "    addpath(root);\n\n"
        "    % MATLAB Compiler needs a top-level main function: a one-line launcher\n"
        "    % written into the build folder, outside the package\n"
        "    launcher = fullfile(out_dir, 'posefromevents.m');\n"
        "    fid = fopen(launcher, 'w');\n"
        "    assert(fid > 0, 'Cannot write %s', launcher);\n"
        f"    fprintf(fid, 'function posefromevents(varargin)\\n    {pkg_name}.run_pipeline(varargin{{:}});\\nend\\n');\n"
        "    fclose(fid);\n\n"
        "    target = fullfile(out_dir, 'standalone');\n"
        "    mcc('-m', launcher, '-d', target, '-a', here, '-R', '-nodisplay', '-v');\n"
        "    fprintf('built %s\\n', fullfile(target, 'posefromevents'));\n"
        "end\n")

    shutil.copy2(ROOT / xml, out / xml)
    stamp = {"generated": datetime.now().isoformat(timespec="seconds"), "package": pkg_name,
             "overrides": overrides, "files": n}
    (out / "generated.json").write_text(json.dumps(stamp, indent=2) + "\n")
    (out / "README.md").write_text(
        f"# {pkg_name}: the pipeline as one self-contained package\n\n"
        "Generated copy of the production pipeline for a compiled standalone:\n"
        "the packages +io, +geom, +surface, +track, +warm, +traj, +adjust and +prog\n"
        f"as nested packages with every reference rewritten to `{pkg_name}.<pkg>`,\n"
        f"`{pkg_name}.config` (recording, window and output folder as arguments,\n"
        "plus any parameter overrides listed in generated.json),\n"
        f"`{pkg_name}.run_pipeline` (main.m as a function, no figures) and the\n"
        "calibration file. Nothing here calls or changes the prototyping code;\n"
        "`diagnostics/make_deployable.py` (or the Studio's Build page) regenerates\n"
        "this folder from the production tree. Do not edit it by hand.\n\n"
        "Run in MATLAB:\n\n"
        f"    {pkg_name}.run_pipeline('/path/ROT-NOM.hdf5', 'out', 60, 185)\n\n"
        "Build the standalone (MATLAB Compiler), then run it with the MATLAB\n"
        "Runtime of this release or a full installation:\n\n"
        f"    {pkg_name}.build_standalone\n"
        f"    build_{pkg_name}/standalone/run_posefromevents.sh ~/Applications/MATLAB/R2026a \\\n"
        "        /path/ROT-NOM.hdf5 out 60 185\n\n"
        "The executable needs the MATLAB Runtime (x86-64 Linux), so it is not the\n"
        "Jetson (aarch64) path; that path is MATLAB Coder on this same package.\n")
    print(f"generated +{pkg_name}: {n} package files + config, run_pipeline, build_standalone, README, "
          f"calibration, {len(overrides)} override(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
