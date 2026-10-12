function build_standalone(out_dir)
    %   Compiles the deployable pipeline into a standalone application with
    %   MATLAB Compiler. The executable takes the recording, the output
    %   folder and optionally the time window:
    %       posefromevents <recording.hdf5> <output_dir> [start_s end_s]
    %   It runs on a machine with the MATLAB Runtime of this release (or a
    %   full MATLAB installation) through run_posefromevents.sh <runtime root>.
    %
    %   Inputs:
    %       OUT_DIR -> Char, build folder (default <repo>/build_<package>)
    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    if nargin < 1 || isempty(out_dir)
        out_dir = fullfile(root, 'build_deployable');
    end
    if ~isfolder(out_dir)
        mkdir(out_dir);
    end
    addpath(root);

    % MATLAB Compiler needs a top-level main function: a one-line launcher
    % written into the build folder, outside the package
    launcher = fullfile(out_dir, 'posefromevents.m');
    fid = fopen(launcher, 'w');
    assert(fid > 0, 'Cannot write %s', launcher);
    fprintf(fid, 'function posefromevents(varargin)\n    deployable.run_pipeline(varargin{:});\nend\n');
    fclose(fid);

    target = fullfile(out_dir, 'standalone');
    mcc('-m', launcher, '-d', target, '-a', here, '-R', '-nodisplay', '-v');
    fprintf('built %s\n', fullfile(target, 'posefromevents'));
end
