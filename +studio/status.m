function info = status(root)
%STATUS The running Event Studio server of a project, or [] if none answers.
if nargin < 1 || isempty(root)
    root = fileparts(fileparts(mfilename('fullpath')));
end
info = [];
f = fullfile(root, '.studio_cache', 'studio.json');
if ~isfile(f)
    return
end
s = jsondecode(fileread(f));
if ~isfolder(sprintf('/proc/%d', s.pid))
    return
end
try
    webread([s.url 'api/state'], weboptions('Timeout', 2));
    info = s;
catch
end
end
