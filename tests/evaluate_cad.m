function S=evaluate_cad(model_file,cad_file,out_dir)
% Partial-reference comparison. CAD z>0.30 m is the top component; it is
% excluded from fitting, and shown separately. Docking cone has no CAD match.
% Report rigid metric AND span-normalized rigid fits; neither is a complete-surface test.
z=load(model_file,'model'); A=z.model.X*z.model.scale.m_per_unit;
C=readmatrix(cad_file,'NumHeaderLines',1)/1000;
shared=C(:,3)<=0.300001; B=C(shared,:);
if ~exist(out_dir,'dir'),mkdir(out_dir);end
S=struct('cad_units','mm converted to m','cad_shared_mask',shared, ...
    'excluded_top_z_m',0.30,'cone_in_cad',false);
S.metric=compare_clouds(A,B,'metric landmarks','shared CAD',struct('fix_scale',true));
% Unconstrained one-way similarity ICP can shrink panels onto the cube.
% Normalize by declared spans instead; preserve this choice in the artifact.
ratio=(max(C(:,1))-min(C(:,1)))/z.model.scale.known_width_m;
S.shape=compare_clouds(ratio*A,B,'span-normalized landmarks','shared CAD',struct('fix_scale',true));
S.shape.span_normalization=ratio;
S.cad_span_m=max(C(:,1))-min(C(:,1));
S.assumed_span_m=z.model.scale.known_width_m;
fprintf('CAD x span %.6f m; specified physical wingspan %.6f m.\n',S.cad_span_m,S.assumed_span_m);
for mode={'metric','shape'}
    v=S.(mode{1}); Aw=v.A_aligned;
    f=figure('Visible','off','Position',[0 0 1250 450],'Color','w');
    pairs=[1 2;1 3;2 3];
    for k=1:3
        subplot(1,3,k);i=pairs(k,1);j=pairs(k,2);
        scatter(B(:,i),B(:,j),2,[.75 .75 .75],'filled');hold on;
        scatter(C(~shared,i),C(~shared,j),2,[.95 .7 .7],'filled');
        scatter(Aw(:,i),Aw(:,j),8,[0 .3 .8],'filled');axis equal;grid on;
        labels={'CAD x [m]','CAD y [m]','CAD z [m]'};xlabel(labels{i});ylabel(labels{j});
    end
    legend('shared CAD','excluded CAD top','landmarks (includes unmatched cone)');
    sgtitle(sprintf('%s: one alignment, scale %.4f; partial CAD reference',mode{1},v.scale));
    exportgraphics(f,fullfile(out_dir,['cad_' mode{1} '.png']),'Resolution',130);close(f);
end
save(fullfile(out_dir,'cad_evaluation.mat'),'S');
end
