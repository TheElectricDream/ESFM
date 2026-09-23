function test_reference_adjustment()
% Compare the extracted gold adjuster with identical inputs to the stream one.
root=fileparts(fileparts(mfilename('fullpath')));addpath(root);
source=fileread(fullfile(root,'main_gold.m'));
i=regexp(source,'(?m)^function ','once');
dirname=tempname;mkdir(dirname);cleanup=onCleanup(@() cleanup_dir(dirname));
f=fopen(fullfile(dirname,'gold_handles.m'),'w');
fprintf(f,'function H=gold_handles()\nH=struct(''adjust'',@adjust_trajectory);\nend\n');
fwrite(f,source(i:end));fclose(f);addpath(dirname);
G=gold_handles();H=run_event_spacecraft_stream('handles');c=H.defaults();c.build.exact_reference=true;
cam=H.stream_calibration(fullfile(root,c.camera.calibration_xml),c.camera);[A,~]=H.original_parameters(c,cam);
b=load(fullfile(root,'output_golden/warm_start.mat'));
cols=H.free_columns(b.traj,true,[],[],false);ids=(1:size(b.X,1))';
[tg,Xg]=G.adjust(b.traj,b.X,b.O,cols,ids,20,A);
[ts,Xs]=H.adjust_trajectory(b.traj,b.X,b.O,cols,ids,20,A);
assert(isequal(tg,ts)&&isequal(Xg,Xs),'Reference adjustment diverged on identical warm-start input.');
fprintf('PASS: reference-mode joint adjustment is bit-identical to main_gold.\n');
end
function cleanup_dir(d)
rmpath(d);rmdir(d,'s');
end
