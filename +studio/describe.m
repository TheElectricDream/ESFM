function d = describe(v, name, deep, mode)
%DESCRIBE What Event Studio shows for a value: class, size, a short preview,
%   and (DEEP) its fields, elements or numbers. With MODE 'flatten', a
%   struct becomes a list of its leaf fields {path, value, class, size}
%   (the parameters page reads cfg this way).
if nargin < 3
    deep = false;
end
if nargin >= 4 && strcmp(mode, 'flatten')
    d = flatten(v, name);
    return
end
d = struct('name', name, 'class', class(v), 'size', sizeText(v), 'preview', preview(v), ...
    'expandable', isstruct(v) || iscell(v) || (isobject(v) && ~isstring(v)) || istable(v) || ...
    ((isnumeric(v) || islogical(v)) && numel(v) > 10));
if ~deep
    return
end
if isstruct(v) && isscalar(v)
    f = fieldnames(v);
    d.children = cellfun(@(k) studio.describe(v.(k), [name '.' k], false), f', 'UniformOutput', false);
elseif isstruct(v)
    n = min(numel(v), 100);
    d.children = arrayfun(@(k) studio.describe(v(k), sprintf('%s(%d)', name, k), false), 1:n, 'UniformOutput', false);
    d.fields = fieldnames(v)';
elseif iscell(v)
    n = min(numel(v), 100);
    d.children = arrayfun(@(k) studio.describe(v{k}, sprintf('%s{%d}', name, k), false), 1:n, 'UniformOutput', false);
elseif (isnumeric(v) || islogical(v)) && ismatrix(v)
    r = min(size(v, 1), 200);
    c = min(size(v, 2), 40);
    block = double(v(1:r, 1:c));
    d.values = num2cell(block, 2)';
    d.shown = [r c];
    x = double(v(:));
    x = x(isfinite(x));
    if ~isempty(x)
        d.stats = struct('min', min(x), 'max', max(x), 'mean', mean(x), 'std', std(x), ...
            'nan', nnz(isnan(double(v(:)))), 'nnz', nnz(v));
    end
elseif ischar(v) || isstring(v)
    t = char(join(string(v), newline));
    d.text = t(1:min(end, 20000));
elseif istable(v)
    d.columns = v.Properties.VariableNames;
    d.text = evalc('disp(head(v, 20))');
elseif isobject(v)
    try
        p = properties(v);
        d.children = cellfun(@(k) studio.describe(v.(k), [name '.' k], false), p', 'UniformOutput', false);
    catch
        d.text = evalc('disp(v)');
    end
end
end

function list = flatten(v, prefix)
list = struct('path', {}, 'value', {}, 'class', {}, 'size', {});
if isstruct(v) && isscalar(v)
    f = fieldnames(v);
    for k = 1:numel(f)
        sub = flatten(v.(f{k}), [prefix '.' f{k}]);
        list = [list, sub]; %#ok<AGROW>
    end
else
    p = prefix;
    if startsWith(p, 'cfg.')
        p = p(5:end);
    end
    list(1).path = p;
    list(1).value = preview(v, 400);
    list(1).class = class(v);
    list(1).size = sizeText(v);
end
end

function s = sizeText(v)
s = strjoin(arrayfun(@num2str, size(v), 'UniformOutput', false), char(215));
end

function p = preview(v, maxLen)
if nargin < 2
    maxLen = 80;
end
if ischar(v) && (isrow(v) || isempty(v))
    p = ['''' v ''''];
elseif isstring(v) && isscalar(v)
    p = ['"' char(v) '"'];
elseif (isnumeric(v) || islogical(v)) && numel(v) <= 12 && ismatrix(v)
    if isempty(v)
        p = '[]';
    elseif isinteger(v) || islogical(v)
        p = mat2str(v);
    else
        p = mat2str(v, 6);
    end
elseif (isnumeric(v) || islogical(v)) && numel(v) > 2e6
    p = sprintf('[%s %s]', sizeText(v), class(v));
elseif isnumeric(v) || islogical(v)
    x = double(v(:));
    x = x(isfinite(x));
    if isempty(x)
        p = sprintf('[%s %s]', sizeText(v), class(v));
    else
        p = sprintf('[%s %s]  %.4g … %.4g', sizeText(v), class(v), min(x), max(x));
    end
elseif isa(v, 'function_handle')
    p = func2str(v);
elseif isstruct(v) && isscalar(v)
    p = sprintf('struct, %d fields', numel(fieldnames(v)));
elseif isstruct(v)
    p = sprintf('%s struct array', sizeText(v));
elseif iscell(v)
    p = sprintf('{%s cell}', sizeText(v));
elseif istable(v)
    p = sprintf('%s table', sizeText(v));
else
    p = sprintf('%s %s', sizeText(v), class(v));
end
if numel(p) > maxLen
    p = [p(1:maxLen - 1) char(8230)];
end
end
