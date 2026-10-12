classdef Worker < handle
%WORKER Runs Event Studio's commands in this MATLAB session.
%   The Studio's web server listens on a local port; the worker connects
%   to it and receives one JSON command per line,
%       {"id": 7, "cmd": "eval", "args": {...}}
%   answering {"id": 7, "ok": true, "result": ...} or {"id": 7, "ok":
%   false, "error": "...", "report": "...", "output": "..."}. Commands run
%   on MATLAB's main thread from the connection's callback, so the Command
%   Window stays usable while the worker is idle. Code from the Studio
%   (console commands, pipeline steps) runs in the base workspace, with its
%   output captured through MATLAB's diary so the Studio can show it live.
%
%   Try a command from the Command Window:
%       w = studio.Worker.instance(); w.dispatch('ws.list', struct())

    properties (SetAccess = private)
        Client          % tcpclient connected to the Studio
        Root            % project folder
    end

    properties (Access = private)
        Buffer = uint8([])
    end

    methods (Static)
        function w = instance(w)
            % The running worker, if any.
            persistent current
            if nargin
                current = w;
            end
            if ~isempty(current) && ~isvalid(current)
                current = [];
            end
            w = current;
        end

        function restoreDiary(state, file)
            diary off;
            if strcmp(state, 'on')
                diary(file);
            end
        end
    end

    methods
        function obj = Worker(root)
            obj.Root = root;
        end

        function connect(obj, port, token)
            obj.Client = tcpclient('127.0.0.1', port, 'Timeout', 20);
            configureTerminator(obj.Client, 'LF');
            obj.send(struct('hello', 'studio-worker', 'token', token, 'info', obj.info()));
            configureCallback(obj.Client, 'terminator', @(~, ~) obj.onData());
        end

        function delete(obj)
            if ~isempty(obj.Client)
                try
                    configureCallback(obj.Client, 'off');
                catch
                end
                obj.Client = [];
            end
        end

        function s = info(obj)
            s = struct('release', version('-release'), 'version', version, 'matlabroot', matlabroot, ...
                'pid', matlabProcessID, 'pwd', pwd, 'root', obj.Root, ...
                'desktop', usejava('desktop'), 'host', strtrim(getenv('HOSTNAME')));
        end

        function onData(obj)
            n = obj.Client.NumBytesAvailable;
            if n == 0
                return
            end
            obj.Buffer = [obj.Buffer, read(obj.Client, n, 'uint8')];
            while true
                k = find(obj.Buffer == 10, 1);
                if isempty(k)
                    break
                end
                line = native2unicode(obj.Buffer(1:k - 1), 'UTF-8');
                obj.Buffer = obj.Buffer(k + 1:end);
                if ~isempty(strtrim(line))
                    obj.handle(jsondecode(line));
                end
            end
        end

        function handle(obj, msg)
            reply = struct('id', msg.id, 'ok', true);
            try
                args = struct();
                if isfield(msg, 'args') && isstruct(msg.args)
                    args = msg.args;
                end
                result = obj.dispatch(msg.cmd, args);
                if isstruct(result) && isfield(result, 'failed') && result.failed
                    reply.ok = false;
                    reply.error = result.error;
                    reply.report = result.report;
                    reply.output = result.output;
                else
                    reply.result = result;
                end
            catch ME
                reply.ok = false;
                reply.error = ME.message;
                reply.report = getReport(ME, 'extended', 'hyperlinks', 'off');
            end
            try
                obj.send(reply);
            catch ME
                % a result jsonencode cannot express: report that instead
                obj.send(struct('id', msg.id, 'ok', false, 'error', ['Could not send the result: ' ME.message]));
            end
        end

        function send(obj, s)
            bytes = unicode2native([jsonencode(s, 'ConvertInfAndNaN', true) newline], 'UTF-8');
            write(obj.Client, bytes, 'uint8');
        end

        function result = dispatch(obj, cmd, args)
            % Run one command. Public so it can be tried from the Command Window.
            switch cmd
                case 'ping'
                    result = 'pong';
                case 'info'
                    result = obj.info();
                case 'rehash'
                    rehash;
                    result = 'ok';
                case 'eval'
                    result = obj.runCode(args.code, field(args, 'log', ''), '');
                case 'step.run'
                    result = obj.runCode(args.code, field(args, 'log', ''), field(args, 'config_dir', ''));
                case 'ws.list'
                    result = obj.workspaceList();
                case 'ws.inspect'
                    v = obj.baseValue(args.expr);
                    result = studio.describe(v, args.expr, true);
                    tail = regexp(char(args.expr), '[A-Za-z]\w*(?=[^A-Za-z]*$)', 'match', 'once');
                    result.views = studio.view(v, 'suggest', struct(), tail);
                case 'ws.clear'
                    names = field(args, 'names', {});
                    if isempty(names)
                        evalin('base', 'clearvars');
                    else
                        names = cellstr(names);
                        assert(all(cellfun(@isvarname, names)), 'Invalid variable name');
                        evalin('base', ['clear ' strjoin(names, ' ')]);
                    end
                    result = obj.workspaceList();
                case 'config.load'
                    addpath(args.dir);
                    clear('studio_config');
                    rehash;
                    cfg = feval('studio_config');   %#ok<FVAL> the generated copy of config.m, created at run time
                    applied = false;
                    if field(args, 'apply', false) && evalin('base', 'exist(''cfg'', ''var'') == 1')
                        assignin('base', 'cfg', cfg);
                        applied = true;
                    end
                    result = struct('values', studio.describe(cfg, 'cfg', false, 'flatten'), 'applied', applied);
                case 'view'
                    result = studio.view(obj.baseValue(args.expr), args.kind, field(args, 'opts', struct()), args.expr);
                case 'lint'
                    % the Code Analyzer on the (unsaved) text, and whether each
                    % candidate name exists anywhere (exist inside an anonymous
                    % function sees no variables of this method)
                    m = checkcode(args.path, '-id');
                    msgs = arrayfun(@(e) struct('line', e.line, 'col', e.column, 'id', e.id, ...
                        'message', e.message), m(:)', 'UniformOutput', false);
                    names = cellstr(field(args, 'names', {}));
                    names = names(~cellfun(@isempty, names));
                    known = cellfun(@(n) exist(n) > 1 || ~isempty(which(n)) || ~isempty(help(n)), names); %#ok<EXIST>
                    result = struct('messages', {msgs}, 'exists', {num2cell(known)});
                case 'edit'
                    if ~usejava('desktop')
                        error('studio:edit', 'This MATLAB has no desktop (it is the headless worker)');
                    end
                    opentoline(args.path, max(1, field(args, 'line', 1)));
                    result = 'ok';
                case 'build.standalone'
                    pkg = args.package;
                    assert(isvarname(pkg), 'Invalid package name');
                    rehash;
                    result = obj.runCode(sprintf('%s.build_standalone();', pkg), field(args, 'log', ''), '');
                otherwise
                    error('studio:worker', 'Unknown command %s', cmd);
            end
        end

        function v = baseValue(~, expr)
            % A workspace variable, field or element: x, x.f.g, x(3), x{2}
            expr = char(expr);
            ok = ~isempty(regexp(expr, '^[A-Za-z]\w*(\.[A-Za-z]\w*|\(\d+(,\d+)*\)|\{\d+(,\d+)*\})*$', 'once'));
            assert(ok, 'studio:expr', 'Not a variable reference: %s', expr);
            v = evalin('base', expr);
        end

        function result = runCode(obj, code, logFile, configDir)
            % Run CODE in the base workspace, capturing its output (diary).
            before = obj.snapshot();
            prevState = get(0, 'Diary');
            prevFile = get(0, 'DiaryFile');
            diary off;
            if ~isempty(logFile)
                diary(logFile);
            end
            restore = onCleanup(@() studio.Worker.restoreDiary(prevState, prevFile));
            t = tic;
            err = [];
            try
                evalin('base', code);
                if ~isempty(configDir)
                    addpath(configDir);
                    clear('studio_config');
                    rehash;
                    evalin('base', 'cfg = studio_config();');
                    fprintf('cfg rebuilt from config.m with the Studio''s parameter overrides\n');
                end
            catch ME
                err = ME;
                fprintf(2, '%s\n', getReport(ME, 'extended', 'hyperlinks', 'off'));
            end
            elapsed = toc(t);
            diary off;
            delete(restore);
            output = '';
            if ~isempty(logFile) && isfile(logFile)
                output = fileread(logFile);
            end
            result = struct('elapsed', elapsed, 'output', output, 'changed', {obj.changed(before)}, ...
                'failed', ~isempty(err), 'error', '', 'report', '');
            if ~isempty(err)
                result.error = err.message;
                result.report = getReport(err, 'extended', 'hyperlinks', 'off');
            end
        end

        function m = snapshot(~)
            s = evalin('base', 'whos');
            m = containers.Map('KeyType', 'char', 'ValueType', 'char');
            for k = 1:numel(s)
                m(s(k).name) = sprintf('%s|%s|%d', s(k).class, mat2str(s(k).size), s(k).bytes);
            end
        end

        function names = changed(obj, before)
            after = obj.snapshot();
            keys = after.keys();
            names = {};
            for k = 1:numel(keys)
                if ~before.isKey(keys{k}) || ~strcmp(before(keys{k}), after(keys{k}))
                    names{end + 1} = keys{k}; %#ok<AGROW>
                end
            end
        end

        function list = workspaceList(~)
            s = evalin('base', 'whos');
            list = cell(1, numel(s));
            for k = 1:numel(s)
                v = evalin('base', s(k).name);
                d = studio.describe(v, s(k).name, false);
                d.bytes = s(k).bytes;
                d.views = studio.view(v, 'suggest', struct(), s(k).name);
                list{k} = d;
            end
        end
    end
end

function v = field(s, name, default)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = default;
end
end
