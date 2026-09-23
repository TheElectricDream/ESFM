%% Inspect trajectory evaluation and demonstrate spline corrections
% Run after creating trajectory, inserting bestRefined, and defining
% slice_times. Requires your +traj functions and geom.rodrigues.
% No optimization is performed. The input trajectory is left unchanged.
% Blue = zero-spline warm motion. Black dots = supplied trajectory.
% Orange = ARTIFICIAL single-coefficient correction, for explanation only.
% Uses gold's rotation struct fields r11, r12, ..., r33.

% Change these amplitudes and rerun to explore what the coefficients do.
demo_angle_coefficient_deg = 5;
demo_translation_coefficient = [0.02 -0.01 0.015]; % model units, not metres

assert(exist('trajectory','var')==1 && exist('slice_times','var')==1, ...
    'Create trajectory and slice_times before running this script.');
ti = struct;
ti.original = trajectory;
ti.zero = trajectory;
ti.zero.k = zeros(trajectory.K,1);
ti.zero.m = zeros(trajectory.K,3);
ti.ts = slice_times(:);
assert(~isempty(ti.ts) && all(isfinite(ti.ts)), 'Invalid slice_times.');
assert(all(ti.ts>=trajectory.t0), 'slice_times precede trajectory.t0.');
assert(trajectory.h>0 && trajectory.K==trajectory.n_seg+3, ...
    'Unexpected spline dimensions or spacing.');
ti.endTime = max(ti.ts);
assert(ti.endTime>trajectory.t0, 'Need a nonzero displayed time interval.');
assert(ti.endTime < trajectory.t0+trajectory.n_seg*trajectory.h, ...
    'Display times exceed the allocated interior spline segments.');

% Evaluate smoothly through the warm window, including the actual samples.
ti.t = unique([linspace(trajectory.t0,ti.endTime,401)';ti.ts]);
ti.elapsed = ti.t-trajectory.t0;
ti.baseAngle = trajectory.omega*ti.elapsed;
ti.baseT = [trajectory.c 1] + ti.elapsed*trajectory.V;
ti.zeroAngle = traj.angle(ti.zero,ti.t);
[ti.zeroR,ti.zeroT] = traj.pose(ti.zero,ti.t);
ti.inputAngle = traj.angle(trajectory,ti.ts);
[ti.inputR,ti.inputT] = traj.pose(trajectory,ti.ts);

%% Make a demonstration COPY with one nonzero angular/translation row
% Coefficient j has nominal location t0 + (j-2)*h in the gold convention.
ti.midTime = (trajectory.t0+ti.endTime)/2;
ti.j = min(trajectory.K,max(1,round((ti.midTime-trajectory.t0)/trajectory.h)+2));
ti.demo = ti.zero;
ti.demo.k(ti.j) = deg2rad(demo_angle_coefficient_deg);
ti.demo.m(ti.j,:) = demo_translation_coefficient;
ti.angleCorrection = traj.spline_eval(ti.demo,ti.t,ti.demo.k);
ti.translationCorrection = traj.spline_eval(ti.demo,ti.t,ti.demo.m);
ti.demoAngle = traj.angle(ti.demo,ti.t);
[ti.demoR,ti.demoT] = traj.pose(ti.demo,ti.t);

% Evaluate the weight of that coefficient: set its value to one.
ti.impulse = zeros(trajectory.K,1);
ti.impulse(ti.j) = 1;
ti.weight = traj.spline_eval(ti.demo,ti.t,ti.impulse);
ti.coefficientTime = trajectory.t0+(ti.j-2)*trajectory.h;

%% Verify the wiring of your trajectory functions
[ti.idx,ti.val] = traj.spline_basis(trajectory,ti.t);
ti.angleZeroError = max(abs(ti.zeroAngle-ti.baseAngle));
ti.translationZeroError = max(abs(ti.zeroT(:)-ti.baseT(:)));
ti.sumWeightError = max(abs(sum(ti.val,2)-1));
ti.angleAssemblyError = max(abs(ti.demoAngle-ti.baseAngle-ti.angleCorrection));
ti.translationAssembly = ti.demoT-ti.baseT-ti.translationCorrection;
ti.translationAssemblyError = max(abs(ti.translationAssembly(:)));
ti.singleAngleError = max(abs(ti.angleCorrection-ti.weight*ti.demo.k(ti.j)));
ti.singleTranslation = ti.translationCorrection-ti.weight*ti.demo.m(ti.j,:);
ti.singleTranslationError = max(abs(ti.singleTranslation(:)));

% Check pose's rotation result against the expected angle/axis combination.
ti.expectedR = geom.rodrigues(trajectory.a,ti.demoAngle);
ti.rotationAssemblyError = 0;
ti.fields = {'r11','r12','r13','r21','r22','r23','r31','r32','r33'};
for ti_k = 1:numel(ti.fields)
    ti.f = ti.fields{ti_k};
    ti.actualEntry = ti.demoR.(ti.f);
    ti.expectedEntry = ti.expectedR.(ti.f);
    ti.rotationAssemblyError = max(ti.rotationAssemblyError, ...
        max(abs(ti.actualEntry(:)-ti.expectedEntry(:))));
end
ti.errors = [ti.angleZeroError;ti.translationZeroError;ti.sumWeightError; ...
    ti.angleAssemblyError;ti.translationAssemblyError;ti.singleAngleError; ...
    ti.singleTranslationError;ti.rotationAssemblyError];
ti.checkNames = {'Zero angular correction';'Zero translation correction'; ...
    'Weights sum to one';'Angle = baseline + correction'; ...
    'Translation = baseline + correction';'Single angular coefficient'; ...
    'Single translation coefficient';'Pose rotation uses corrected angle'};
% Tolerance relative to the scale of the evaluated quantities.
ti.tolerance = 1e-10*max([1;abs(ti.baseAngle(:));abs(ti.baseT(:)); ...
    abs(ti.demoAngle(:));abs(ti.demoT(:))]);
ti.checks = table(ti.checkNames,ti.errors,ti.errors<=ti.tolerance, ...
    'VariableNames',{'Check','MaximumError','Pass'});
disp(ti.checks);
assert(all(isfinite(ti.errors)) && all(ti.errors<=ti.tolerance), ...
    'A trajectory evaluation check failed. Inspect ti.checks.');
fprintf('Demonstration coefficient row: %d; nominal time: %.6f s\n', ...
    ti.j,ti.coefficientTime);
fprintf('Artificial angle coefficient %.3f deg; translation [%.4f %.4f %.4f] model units.\n', ...
    demo_angle_coefficient_deg,demo_translation_coefficient);
fprintf('A single cubic B-spline coefficient peaks at weight 2/3, not 1.\n');
fprintf('Correction support is within two spacings of its nominal time (interior evaluation).\n');
if any(trajectory.k(:)~=0) || any(trajectory.m(:)~=0)
    fprintf('Input trajectory already has corrections: black points need not lie on blue curves.\n');
else
    fprintf('Input spline arrays are zero: black points should lie on blue curves.\n');
end

%% Plot baseline, supplied trajectory, and the illustrative corrected copy
ti.fig = figure('Color','w','Name','What trajectory evaluation does', ...
    'Position',[60 60 1350 830]);
tiledlayout(2,3,'TileSpacing','compact','Padding','compact');
ti.blue = [0.1 0.35 0.8]; ti.orange = [0.9 0.35 0.05];
nexttile; hold on;
plot(ti.elapsed,rad2deg(ti.baseAngle),'-','Color',ti.blue,'LineWidth',1.5, ...
    'DisplayName','Baseline');
plot(ti.ts-trajectory.t0,rad2deg(ti.inputAngle),'k.','DisplayName','Your trajectory');
plot(ti.elapsed,rad2deg(ti.demoAngle),'--','Color',ti.orange,'LineWidth',1.5, ...
    'DisplayName','Artificial correction');
xlabel('Time since t0 [s]'); ylabel('Angle [deg]'); grid on;
title('Rotation angle about the fixed axis'); legend('Location','best');
for ti_k = 1:3
    nexttile; hold on;
    plot(ti.elapsed,ti.baseT(:,ti_k),'-','Color',ti.blue,'LineWidth',1.5);
    plot(ti.ts-trajectory.t0,ti.inputT(:,ti_k),'k.');
    plot(ti.elapsed,ti.demoT(:,ti_k),'--','Color',ti.orange,'LineWidth',1.5);
    xlabel('Time since t0 [s]'); ylabel('Translation [model units]'); grid on;
    ti.names = {'x','y','z'};
    title(['Translation ' ti.names{ti_k} ': baseline plus spline correction']);
end
nexttile; hold on;
plot(ti.elapsed,ti.weight,'k-','LineWidth',1.5,'DisplayName','Evaluated weight');
plot(ti.coefficientTime-trajectory.t0,1,'ro','MarkerSize',7, ...
    'DisplayName','Coefficient value = 1');
yline(2/3,':','2/3 peak','HandleVisibility','off');
xline(ti.coefficientTime-trajectory.t0,'k:','HandleVisibility','off');
ylim([-0.05 1.1]); grid on; xlabel('Time since t0 [s]'); ylabel('Weight');
title(sprintf('Coefficient %d produces a smooth bump',ti.j));
legend('Location','best');

%% Show what the evaluated pose does to one synthetic object-frame point
% Choose an offset perpendicular to the spin axis so rotation is visible.
ti.a = trajectory.a(:)/norm(trajectory.a);
[~,ti.refID] = min(abs(ti.a));
ti.ref = zeros(3,1); ti.ref(ti.refID) = 1;
ti.side = cross(ti.a,ti.ref); ti.side = ti.side/norm(ti.side);
ti.point = (0.08*ti.side + 0.03*ti.a)';
ti.pathZero = ti_apply_point(ti.zeroR,ti.zeroT,ti.point);
ti.pathDemo = ti_apply_point(ti.demoR,ti.demoT,ti.point);
nexttile; hold on;
plot3(ti.pathZero(:,1),ti.pathZero(:,2),ti.pathZero(:,3), ...
    '-','Color',ti.blue,'LineWidth',1.5,'DisplayName','Baseline');
plot3(ti.pathDemo(:,1),ti.pathDemo(:,2),ti.pathDemo(:,3), ...
    '--','Color',ti.orange,'LineWidth',1.5,'DisplayName','Artificial correction');
plot3(ti.pathZero(1,1),ti.pathZero(1,2),ti.pathZero(1,3),'ko', ...
    'DisplayName','Baseline start');
axis equal; grid on; view(35,25);
xlabel('Camera x'); ylabel('Camera y'); zlabel('Camera z');
title({'One synthetic point transformed by R*X + T','These curves are motion paths, not point clouds'});
legend('Location','best');
sgtitle('Trajectory evaluation only: orange curves are an artificial demonstration, not a fitted improvement');
assert(isequaln(trajectory,ti.original),'The input trajectory was unexpectedly changed.');
fprintf('PASS: your input trajectory is unchanged. Inspect outputs in ti.\n');

function Y = ti_apply_point(R,T,X)
    Y = [R.r11(:)*X(1)+R.r12(:)*X(2)+R.r13(:)*X(3)+T(:,1), ...
         R.r21(:)*X(1)+R.r22(:)*X(2)+R.r23(:)*X(3)+T(:,2), ...
         R.r31(:)*X(1)+R.r32(:)*X(2)+R.r33(:)*X(3)+T(:,3)];
end
