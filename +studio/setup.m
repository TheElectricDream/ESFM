function python = setup(force)
%SETUP Prepare the Python environment Event Studio's server runs in.
%   python = studio.setup() finds a Python 3.10+ on this computer, creates
%   the Studio's own environment for it (outside the project folder, one
%   per machine and Python version, so copying or syncing the project
%   never breaks it), installs the packages it needs (numpy, h5py and,
%   optionally, dv-processing for AEDAT4 and the camera) and returns that
%   environment's python. Progress is printed as it happens. After the
%   first time it only checks, which takes about a second.
%   studio.setup(true) rebuilds the environment from scratch.
%   studio.start calls this; run it yourself to set up ahead of time.
%
%   Set STUDIO_PYTHON to choose the base Python, and STUDIO_VENV_DIR to
%   choose where the environment goes.
if nargin < 1
    force = false;
end
studio.ensureShell();
fprintf('[Event Studio] Setting up Python (once per machine; later starts only check)\n');
base = findPython();
script = fullfile(fileparts(mfilename('fullpath')), 'webapp', 'setup_env.py');
report = [tempname '.json'];
cleanup = onCleanup(@() deleteIfThere(report));
flags = sprintf('--report "%s"', report);
if force
    flags = [flags ' --force'];
end
% MATLAB's library path would make Python load MATLAB's C++ runtime: clear it
status = system(sprintf('%s "%s" "%s" %s 2>&1', cleanEnv(), base, script, flags), '-echo');
if status ~= 0 || ~isfile(report)
    error('studio:setup', ['Setting up the Python environment failed (see the messages above). ' ...
        'Fix the cause and run studio.setup again; studio.setup(true) rebuilds it.']);
end
r = jsondecode(fileread(report));
python = r.python;
end

function py = findPython()
cands = {getenv('STUDIO_PYTHON'), 'python3', 'python3.14', 'python3.13', 'python3.12', 'python3.11', ...
    'python3.10', 'python'};
tried = {};
for k = 1:numel(cands)
    c = cands{k};
    if isempty(c)
        continue
    end
    [s, out] = system(sprintf('%s "%s" -c "import sys; print(sys.executable); print(sys.version_info >= (3, 10))" 2>/dev/null', cleanEnv(), c));
    lines = strsplit(strtrim(out), newline);
    if s == 0 && numel(lines) >= 2 && strcmp(strtrim(lines{end}), 'True')
        py = strtrim(lines{end - 1});
        [~, v] = system(sprintf('%s "%s" --version', cleanEnv(), py));
        fprintf('[Event Studio] Using %s (%s)\n', py, strtrim(v));
        return
    end
    if s == 0
        tried{end + 1} = sprintf('%s (too old)', c); %#ok<AGROW>
    end
end
msg = 'No Python 3.10 or newer was found on this computer';
if ~isempty(tried)
    msg = [msg ' (found: ' strjoin(tried, ', ') ')'];
end
error('studio:setup', ['%s. Install one (Ubuntu/Jetson: sudo apt install python3 python3-venv; ' ...
    'Fedora: sudo dnf install python3) or set STUDIO_PYTHON to its path, then run studio.start again.'], msg);
end

function s = cleanEnv()
if ispc
    s = '';
else
    s = 'env -u LD_LIBRARY_PATH -u LD_PRELOAD -u PYTHONHOME -u PYTHONPATH';
end
end

function deleteIfThere(f)
if isfile(f)
    delete(f);
end
end
