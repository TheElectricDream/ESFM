function serve(port, token, root, serverPid)
%SERVE Headless worker for Event Studio (the Studio's "Start MATLAB" button).
%   Started by the Studio as matlab -batch "studio.serve(...)": connects to
%   the Studio and runs its commands until the Studio's server exits.
if nargin < 4
    serverPid = [];
end
addpath(root);
cd(root);
w = studio.Worker(root);
w.connect(port, token);
studio.Worker.instance(w);
fprintf('Event Studio worker connected (port %d)\n', port);
k = 0;
while isvalid(w)
    pause(0.05);
    k = k + 1;
    if mod(k, 40) == 0 && ~isempty(serverPid) && ~isfolder(sprintf('/proc/%d', serverPid))
        fprintf('Event Studio server is gone; exiting\n');
        break
    end
end
end
