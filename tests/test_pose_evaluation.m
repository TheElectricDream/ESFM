function test_pose_evaluation()
% Nonuniform timestamps, duplicate log rows, and a constant known alignment.
d=tempname;mkdir(d);cleanup=onCleanup(@() rmdir(d,'s'));
t=cumsum(.1+.025*sin((1:100)'));n=numel(t);yaw=.1*t;
base=1e9;h=fullfile(d,'events.h5');h5create(h,'/timestamp',[1 1]);h5write(h,'/timestamp',base);
G=table(base+t*1e6,zeros(n,1),zeros(n,1),zeros(n,1), ...
    1000*(1+.02*t),2000*ones(n,1),yaw, ...
    'VariableNames',{'system_time_us','red_x','red_y','red_angle','black_x','black_y','black_angle'});
writetable(G,fullfile(d,'truth.csv'));
model.scale=struct('m_per_unit',2,'known_width_m',1.27);save(fullfile(d,'frozen_model.mat'),'model');
P=zeros(n,15);
for k=1:n
    a=yaw(k);R=[cos(a) -sin(a) 0;sin(a) cos(a) 0;0 0 1];
    P(k,:)=[t(k),1,1,(1+.02*t(k))/2,1,0,R(:)'];
end
names={'time_s','status','measured','tx_model','ty_model','tz_model', ...
    'R11','R21','R31','R12','R22','R32','R13','R23','R33'};
writetable(array2table([P;P(20,:)],'VariableNames',names),fullfile(d,'poses.csv'));
alignment=struct('x',[zeros(12,1);log(2)],'fit_interval',[-2 -1],'scale_fitted',false);
o=struct('plot_dir','','alignment',alignment,'fit_interval',[-2 -1]);
S=evaluate_pose_gt(d,fullfile(d,'truth.csv'),h,o);
assert(numel(S.time_s)>=98 && numel(S.time_s)<=100,'Duplicate timestamps retained.');
assert(max(S.pos_err_m)<1e-8 && max(S.rot_err_deg)<1e-6);
assert(max(abs(S.rate_est_deg_s-rad2deg(.1)))<1e-9,'Angular rate must be per second.');
assert(isequal(S.alignment,alignment),'Reused alignment metadata changed.');
fprintf('PASS: GT evaluator handles irregular seconds, duplicate poses and frozen alignment.\n');
end
