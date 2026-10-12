function stop(root)
%STOP Disconnect this MATLAB session from Event Studio and stop its server.
if nargin < 1 || isempty(root)
    root = fileparts(fileparts(mfilename('fullpath')));
end
studio.ensureShell();
w = studio.Worker.instance();
if ~isempty(w)
    delete(w);
    studio.Worker.instance([]);
end
info = studio.status(root);
if ~isempty(info)
    system(sprintf('kill %d', info.pid));
    fprintf('[Event Studio] Stopped (pid %d)\n', info.pid);
end
end
