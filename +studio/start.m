function url = start(root, openBrowser)
%START Start Event Studio and connect this MATLAB session to it.
%   url = studio.start() starts the Studio's local web server for the
%   project this package lives in (or ROOT), connects this MATLAB session
%   as its worker (the Studio's MATLAB console, workspace, pipeline steps
%   and builds run here), and opens it in the browser. A server that is
%   already running for the project is reused. MATLAB's current folder is
%   set to the project folder (main.m writes its output relative to it).
%   Stop with studio.stop. studio.start([], false) does not open a browser
%   (open the printed address yourself).
if nargin < 1 || isempty(root)
    root = fileparts(fileparts(mfilename('fullpath')));
end
if nargin < 2
    openBrowser = true;
end
root = char(root);
studio.ensureShell();
addpath(root);
if ~strcmp(pwd, root)
    fprintf('[Event Studio] Current folder set to %s\n', root);
    cd(root);
end
cache = fullfile(root, '.studio_cache');
if ~isfolder(cache)
    mkdir(cache);
end

info = studio.status(root);
if isempty(info)
    python = studio.setup();
    ready = fullfile(cache, 'ready.json');
    if isfile(ready)
        delete(ready);
    end
    app = fullfile(fileparts(mfilename('fullpath')), 'webapp', 'app.py');
    logFile = fullfile(cache, 'server.log');
    fprintf('[Event Studio] Starting the web server (log: %s)\n', logFile);
    % MATLAB's own LD_LIBRARY_PATH would make Python load MATLAB's older C++
    % runtime, which breaks numpy / dv_processing: start it without
    % PYTHONNOUSERSITE: only the Studio's environment, never ~/.local packages
    cmd = sprintf(['env -u LD_LIBRARY_PATH -u LD_PRELOAD -u PYTHONHOME -u PYTHONPATH PYTHONNOUSERSITE=1 "%s" "%s" --root "%s" ' ...
        '--no-browser --ready-file "%s" > "%s" 2>&1 &'], python, app, root, ready, logFile);
    system(cmd);
    t0 = tic;
    lastNote = 0;
    while ~isfile(ready) && toc(t0) < 60
        pause(0.2);
        if toc(t0) - lastNote >= 5
            lastNote = toc(t0);
            fprintf('[Event Studio] Waiting for the server to come up (%.0f s)\n', toc(t0));
        end
        if serverDied(logFile)
            break
        end
    end
    if ~isfile(ready)
        showLog(logFile);
        error('studio:start', 'Event Studio''s server did not start (its log is above, and in %s).', logFile);
    end
    pause(0.1);
    info = jsondecode(fileread(ready));
    fprintf('[Event Studio] Server running (pid %d)\n', info.pid);
else
    fprintf('[Event Studio] Reusing the server already running for this project (pid %d)\n', info.pid);
end

fprintf('[Event Studio] Connecting this MATLAB session as the Studio''s worker\n');
w = studio.Worker.instance();
if ~isempty(w)
    delete(w);
end
w = studio.Worker(root);
w.connect(info.worker_port, info.token);
studio.Worker.instance(w);
url = info.url;
fprintf('[Event Studio] Ready: %s (this MATLAB session runs its MATLAB commands)\n', url);
if openBrowser
    system(sprintf('env -u LD_LIBRARY_PATH xdg-open "%s" > /dev/null 2>&1 &', url));
end
end

function dead = serverDied(logFile)
% The server writes a Python traceback to its log when it fails to start
dead = false;
if isfile(logFile)
    t = fileread(logFile);
    dead = contains(t, 'Traceback') || contains(t, 'Error:') || contains(t, '[Event Studio] Could not');
end
end

function showLog(logFile)
if isfile(logFile)
    lines = strsplit(fileread(logFile), newline);
    fprintf(2, '%s\n', strjoin(lines(max(1, end - 30):end), newline));
end
end
