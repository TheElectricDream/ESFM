function make_cloud_figures(run_dir, out_png)
% Fixed-viewpoint, equal-axis views of a frozen map next to the reference cloud
% and the CAD model, all in metres and all in the same aligned frame.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root); addpath(fullfile(root,'tests'));
if nargin < 2, out_png = fullfile(run_dir,'fig_cloud_comparison.png'); end
M = load(fullfile(run_dir,'frozen_model.mat'));
Xs = M.model.X * M.model.scale.m_per_unit;
G = load(fullfile(root,'output_golden','result.mat'));
Xg = G.result.X;
[~,~,V] = svd(Xg-mean(Xg,1),0);
Xg = Xg * (1.27/diff(prctile((Xg-mean(Xg,1))*V(:,1),[1 99])));
cad = readmatrix(['/run/media/alexandercrain/Secondary_Drive/Dataset Release 1/' ...
    'point_cloud_target_cad.txt'],'NumHeaderLines',1)/1000;

o = struct('fix_scale',true,'trim',0.7);
Sg = compare_clouds(Xs, Xg,  'candidate','reference', o);   % candidate -> reference frame
Sc = compare_clouds(Xg, cad(cad(:,3)<=.300001,:), 'reference','cad', o);         % reference -> cad frame
A = Sg.A_aligned;                                            % candidate in reference frame
% carry both into the CAD frame for a common view
toCad = @(X) (Sc.s*(Sc.R*X') + Sc.t)';
A = toCad(A); B = toCad(Xg); C = cad;

f = figure('Visible','off','Position',[0 0 1500 1000],'Color','w');
views = {[0 90],'top (panel plane)'; [0 0],'front'; [90 0],'side'};
sets = {A,'streaming reconstruction',[0.85 0.2 0.1]; B,'reference cloud',[0.1 0.3 0.8]};
lim = [min([A;B;C])-0.05; max([A;B;C])+0.05];
for r = 1:3
    for c = 1:3
        ax = subplot(3,3,(r-1)*3+c); hold(ax,'on'); grid(ax,'on');
        if c <= 2
            X = sets{c,1};
            scatter3(ax,X(:,1),X(:,2),X(:,3),9,sets{c,3},'filled');
            ttl = sets{c,2};
        else
            scatter3(ax,C(:,1),C(:,2),C(:,3),1,[0.45 0.45 0.45],'filled');
            ttl = 'CAD (has a top part absent here; no docking cone)';
        end
        view(ax,views{r,1}); axis(ax,'equal');
        xlim(ax,lim(:,1)); ylim(ax,lim(:,2)); zlim(ax,lim(:,3));
        if r == 1, title(ax,ttl,'FontSize',9); end
        ylabel(ax,views{r,2},'FontSize',8);
    end
end
sgtitle(sprintf(['Frozen map vs reference vs CAD, common frame, equal axes [m]. ' ...
    'candidate->reference median %.1f mm, ->CAD median %.1f mm'], ...
    1e3*Sg.median_a_to_b, 1e3*Sc.median_a_to_b),'FontSize',10);
exportgraphics(f, out_png, 'Resolution', 130); close(f);
fprintf('wrote %s\n', out_png);
end
