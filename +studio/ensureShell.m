function ensureShell()
%ENSURESHELL Make MATLAB's system() work when $SHELL is not a usable path.
%   MATLAB runs system() commands through $MATLAB_SHELL, or $SHELL. Some
%   containers (e.g. distrobox) set SHELL to a bare name such as "bash",
%   and then every system() call fails with status 127. This points
%   MATLAB_SHELL at a real shell for this session and says so.
if ispc || ~isempty(getenv('MATLAB_SHELL'))
    return
end
sh = getenv('SHELL');
if ~isempty(sh) && sh(1) == '/' && isfile(sh)
    return
end
for c = {'/bin/bash', '/usr/bin/bash', '/bin/sh'}
    if isfile(c{1})
        setenv('MATLAB_SHELL', c{1});
        fprintf('[Event Studio] SHELL is "%s", which MATLAB cannot run commands with; using %s for this session\n', ...
            sh, c{1});
        return
    end
end
error('studio:shell', 'No usable shell found for MATLAB''s system() (SHELL is "%s").', sh);
end
