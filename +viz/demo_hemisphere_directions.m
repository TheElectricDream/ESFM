%% Visual explanation of hemisphere_directions
% Standalone demo: no event data, toolbox, or project functions required.
% Run the entire script. Use the sliders to change pole and watch the
% hemisphere follow it. Drag within a 3-D panel to change the viewing angle.
% Requires MATLAB R2019b or newer (tiledlayout).
%
% pole is a DIRECTION FROM THE ORIGIN, not the centre of the sphere.
% The sphere always remains centred at [0 0 0].
% We use the corrected, least-aligned-reference construction for t1.
% It remains valid when pole = [1 0 0], unlike the original cross with x.

n = 80;                  % Number of directions in ONE hemisphere
pole = [1 2 3];           % Change this or use the sliders below
selected_index = 25;     % One sample highlighted in every panel

validateattributes(n,{'numeric'},{'scalar','integer','>=',2});
validateattributes(pole,{'numeric'},{'vector','numel',3,'real','finite'});
assert(norm(pole)>0,'pole must be nonzero.');
pole = double(pole(:))/norm(double(pole(:)));
selected_index = min(n,max(1,round(selected_index)));

% These are exactly the original hemisphere sampling equations.
i = (0:n-1)' + 0.5;
z = 1 - i/n;
phi = pi*(1+sqrt(5))*i;
d = [sqrt(1-z.^2).*cos(phi), sqrt(1-z.^2).*sin(phi), z];

hd.fig = figure('Name','What does pole do?', 'Color','w', ...
    'Position',[70 70 1250 850]);
hd.n = n; hd.d = d; hd.selected = selected_index;
hd.panel = uipanel(hd.fig,'Units','normalized', ...
    'Position',[0 0.18 1 0.82],'BorderType','none');
hd.layout = tiledlayout(hd.panel,2,2,'TileSpacing','compact','Padding','compact');
for k = 1:4
    hd.ax(k) = nexttile(hd.layout);
end

% Azimuth turns pole around the camera z-axis; elevation tilts it upward.
hd.az = uicontrol(hd.fig,'Style','slider','Units','normalized', ...
    'Position',[0.14 0.125 0.30 0.025],'Min',-180,'Max',180, ...
    'Value',atan2d(pole(2),pole(1)), ...
    'Callback',@(src,evt) hd_refresh(ancestor(src,'figure')));
uicontrol(hd.fig,'Style','text','Units','normalized', ...
    'Position',[0.01 0.118 0.12 0.035],'String','Pole azimuth', ...
    'BackgroundColor','w');
hd.el = uicontrol(hd.fig,'Style','slider','Units','normalized', ...
    'Position',[0.64 0.125 0.30 0.025],'Min',-90,'Max',90, ...
    'Value',asind(pole(3)), ...
    'Callback',@(src,evt) hd_refresh(ancestor(src,'figure')));
uicontrol(hd.fig,'Style','text','Units','normalized', ...
    'Position',[0.49 0.118 0.14 0.035],'String','Pole elevation', ...
    'BackgroundColor','w');
hd.info = uicontrol(hd.fig,'Style','text','Units','normalized', ...
    'Position',[0.02 0.01 0.96 0.095],'BackgroundColor','w', ...
    'HorizontalAlignment','left','FontSize',11);
guidata(hd.fig,hd);
hd_refresh(hd.fig);
rotate3d(hd.fig,'on');

fprintf('\nHEMISPHERE DEMO\n');
fprintf('Move the pole sliders; the sphere stays centred at the origin.\n');
fprintf('Point colours encode original height z; magenta marks sample %d.\n',selected_index);
fprintf('The numeric checks update under the plots.\n');
fprintf('Try azimuth = 0 and elevation = 0 for the positive x direction.\n');

%% Local plotting functions
function hd_refresh(fig)
    s = guidata(fig);
    az = get(s.az,'Value'); el = get(s.el,'Value');
    pole = [cosd(el)*cosd(az); cosd(el)*sind(az); sind(el)];
    pole = pole/norm(pole);

    % A perpendicular coordinate system, using the corrected construction.
    [~,idx] = min(abs(pole));
    reference = zeros(3,1); reference(idx) = 1;
    t1 = cross(pole,reference); t1 = t1/norm(t1);
    t2 = cross(pole,t1);
    B = [t1 t2 pole];

    % SAME mapping as the function being explained.
    dirs = s.d(:,1)*t1' + s.d(:,2)*t2' + s.d(:,3)*pole';
    j = s.selected;
    theta = linspace(0,2*pi,150)';
    equator = cos(theta)*t1' + sin(theta)*t2';
    red = [0.85 0.15 0.10]; green = [0.1 0.6 0.25]; blue = [0.1 0.3 0.85];

    % Panel 1: directions before pole is used.
    ax = s.ax(1); hd_prepare(ax);
    plot3(ax,cos(theta),sin(theta),zeros(size(theta)),'k--');
    scatter3(ax,s.d(:,1),s.d(:,2),s.d(:,3),28,s.d(:,3),'filled');
    hd_arrow(ax,[0;0;0],[0;0;1],blue,'original +z');
    plot3(ax,s.d(j,1),s.d(j,2),s.d(j,3),'mo','MarkerSize',11,'LineWidth',2);
    plot3(ax,[0 s.d(j,1)],[0 s.d(j,2)],[0 s.d(j,3)],'m-','LineWidth',1.5);
    title(ax,{'1. Original directions d','All have positive z; pole is not used yet'});

    % Panel 2: all sample vectors after the coordinate-system rotation.
    ax = s.ax(2); hd_prepare(ax);
    plot3(ax,equator(:,1),equator(:,2),equator(:,3),'k--','LineWidth',1.4);
    scatter3(ax,dirs(:,1),dirs(:,2),dirs(:,3),28,s.d(:,3),'filled');
    hd_arrow(ax,[0;0;0],pole,blue,'pole');
    hd_arrow(ax,[0;0;0],t1,red,'t1');
    hd_arrow(ax,[0;0;0],t2,green,'t2');
    plot3(ax,dirs(j,1),dirs(j,2),dirs(j,3),'mo','MarkerSize',11,'LineWidth',2);
    plot3(ax,[0 dirs(j,1)],[0 dirs(j,2)],[0 dirs(j,3)],'m-','LineWidth',1.5);
    title(ax,{'2. Rotated directions dirs','Dashed equator is perpendicular to pole'});

    % Panel 3: the vector sum for the single highlighted sample.
    ax = s.ax(3); hd_prepare(ax);
    a = s.d(j,1)*t1; b = s.d(j,2)*t2; c = s.d(j,3)*pole;
    hd_arrow(ax,[0;0;0],a,red,'d_x t1');
    hd_arrow(ax,a,b,green,'d_y t2');
    hd_arrow(ax,a+b,c,blue,'d_z pole');
    hd_arrow(ax,[0;0;0],dirs(j,:)',[0.7 0 0.7],'result');
    plot3(ax,dirs(j,1),dirs(j,2),dirs(j,3),'mo','MarkerSize',11,'LineWidth',2);
    title(ax,{sprintf('3. Sample %d: add three vector components',j), ...
        sprintf('d = [%.3f, %.3f, %.3f]',s.d(j,:))});

    % Panel 4: the separate operation performed by sweep_axes.
    ax = s.ax(4); hd_prepare(ax);
    hp = scatter3(ax,dirs(:,1),dirs(:,2),dirs(:,3),20,blue,'filled');
    hn = scatter3(ax,-dirs(:,1),-dirs(:,2),-dirs(:,3),20,[0.9 0.45 0.05],'filled');
    plot3(ax,equator(:,1),equator(:,2),equator(:,3),'k--');
    hd_arrow(ax,[0;0;0],pole,blue,'pole');
    title(ax,{sprintf('4. sweep_axes adds opposites: %d directions',2*s.n), ...
        '[dirs; -dirs] samples both hemispheres'});
    legend(ax,[hp hn],{'dirs','-dirs'},'Location','southoutside','Orientation','horizontal');

    % Direct numerical checks of the mathematical claims.
    lengthError = max(abs(vecnorm(dirs,2,2)-1));
    heightError = max(abs(dirs*pole-s.d(:,3)));
    basisError = norm(B'*B-eye(3),'fro');
    minForward = min(dirs*pole);
    % A rotation must preserve every pairwise dot product as well.
    gramError = max(max(abs(dirs*dirs'-s.d*s.d')));
    assert(lengthError<1e-10 && heightError<1e-10 && basisError<1e-10 && ...
        gramError<1e-10 && minForward>0 && abs(det(B)-1)<1e-10, ...
        'A hemisphere geometry check failed.');
    set(s.info,'String',sprintf([ ...
        'pole = [%.3f, %.3f, %.3f]   |   azimuth %.1f deg; elevation %.1f deg\n' ...
        'PASS: max unit-length error %.2g; max |dirs*pole - original z| %.2g; minimum dirs*pole %.4f > 0\n' ...
        'PASS: perpendicular unit basis; distances/angles preserved. The origin never moves.'], ...
        pole(1),pole(2),pole(3),az,el,lengthError,heightError,minForward));
    % Inspect the current geometry from the command window with guidata(gcf).
    s.pole = pole; s.t1 = t1; s.t2 = t2; s.dirs = dirs;
    guidata(fig,s);
    drawnow;
end

function hd_prepare(ax)
    % Request both angles explicitly. The single-output form of view
    % can return a view transformation matrix, not an [azimuth elevation]
    % pair, which cannot be passed to view(ax,angles) on slider redraws.
    [previousAzimuth, previousElevation] = view(ax);
    wasDrawn = ~isempty(get(ax,'Children'));
    cla(ax); hold(ax,'on');
    [sx,sy,sz] = sphere(24);
    surf(ax,sx,sy,sz,'FaceColor',[0.65 0.7 0.75],'FaceAlpha',0.045, ...
        'EdgeColor',[0.75 0.78 0.8],'EdgeAlpha',0.15);
    plot3(ax,0,0,0,'k.','MarkerSize',15);
    axis(ax,'equal');
    xlim(ax,[-1.35 1.35]); ylim(ax,[-1.35 1.35]); zlim(ax,[-1.35 1.35]);
    grid(ax,'on'); xlabel(ax,'x'); ylabel(ax,'y'); zlabel(ax,'z');
    colormap(ax,parula(128)); caxis(ax,[0 1]);
    if wasDrawn
        view(ax,previousAzimuth,previousElevation);
    else
        view(ax,35,25);
    end
end

function hd_arrow(ax,start,vec,color,label)
    quiver3(ax,start(1),start(2),start(3),vec(1),vec(2),vec(3), ...
        0,'Color',color,'LineWidth',2,'MaxHeadSize',0.3);
    tip = start+vec;
    text(ax,tip(1)+0.03,tip(2)+0.03,tip(3)+0.03,label, ...
        'Color',color,'FontWeight','bold','Interpreter','none');
end