function pred = predict(map, tc, cam, cfg)
    %   This function predicts, from the current trajectory, where every
    %   active landmark projects at the slice centre TC and how fast its
    %   projection is moving in the image.
    %
    %   Inputs:
    %       MAP -> Struct, current reconstruction state
    %       TC -> Scalar, slice centre time [s]
    %       CAM -> Struct, camera model
    %       CFG -> Struct, full configuration
    %
    %   Outputs:
    %       PRED -> Struct with fields:
    %              ids     [L, 1], landmark ID of each prediction row
    %              uv      [L, 2], projected position at TC [px]
    %              Y       [L, 3], landmark in the camera frame at TC
    %              flow    [L, 2], predicted image velocity [px/s]
    %              inside  [L, 1], logical, in front of the camera and
    %                      inside the image (plus a margin)
    %
    %   Row k of every field refers to landmark pred.ids(k), NOT landmark k.
    
    pred.ids = find(map.alive);
    X = map.X(pred.ids, :);
    
    % Where each landmark projects at the slice centre
    [R, T] = traj.pose(map.traj, tc);
    [pred.uv, pred.Y] = geom.project(R, T, X, cam);
    
    % Image velocity by central difference of the projection at tc +/- h
    h = cfg.prog.flow_half_step_s;
    [Rp, Tp] = traj.pose(map.traj, tc + h);
    [Rm, Tm] = traj.pose(map.traj, tc - h);
    pred.flow = (geom.project(Rp, Tp, X, cam) - geom.project(Rm, Tm, X, cam)) / (2 * h);
    
    % Visible: in front of the camera and inside the image plus a margin
    m  = cfg.prog.image_margin_px;
    sz = cfg.data.image_size;
    pred.inside = pred.Y(:, 3) > cfg.adjust.min_depth & ...
        pred.uv(:, 1) > -m & pred.uv(:, 1) < sz(1) + m & ...
        pred.uv(:, 2) > -m & pred.uv(:, 2) < sz(2) + m;

end