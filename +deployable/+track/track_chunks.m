%-----%
function rows = track_chunks(ev, t_from, t_to, chunk_s, slice_dt, tcfg)
    %   This function runs the 2D tracker over a time window in chunks,
    %   so that no track can live longer than one chunk, and returns the
    %   histories as one list of observation rows. Short chunks keep the
    %   tracks on one rigid edge: over tens of seconds a track slides
    %   along its edge and would bias the initialisation.
    %
    %   Inputs:
    %       EV -> Struct, events with fields t, x, y, flow, accept
    %       T_FROM -> Scalar, start of the window [s]
    %       T_TO -> Scalar, end of the window [s]
    %       CHUNK_S -> Scalar, chunk length [s]
    %       SLICE_DT -> Scalar, slice length of the tracker [s]
    %       TCFG -> Struct, tracker parameters (cfg.track)
    %
    %   Outputs:
    %       ROWS -> [M, 6], observations [time, track_id, u, v, nx, ny]
    %              with track ids 1..K unique over the whole window

    edges = t_from : chunk_s : t_to;
    if edges(end) < t_to
        edges(end+1) = t_to;
    end

    % One block of rows per chunk, concatenated once at the end
    blocks  = cell(numel(edges) - 1, 1);
    next_id = 0;
    for c = 1:numel(edges) - 1
        a = ev.accept & ev.t >= edges(c) & ev.t < edges(c+1);
        [tracks, ~] = deployable.track.track_events(ev.t(a), ev.x(a), ev.y(a), ev.flow(a, :), slice_dt, tcfg);
        hist = cell(numel(tracks), 1);
        for k = 1:numel(tracks)
            h = tracks{k};
            hist{k} = [h(:, 1), repmat(k + next_id, size(h, 1), 1), h(:, 2:5)];
        end
        blocks{c} = vertcat(hist{:});
        next_id = next_id + numel(tracks);
    end
    rows = vertcat(blocks{:});
    if isempty(rows)
        rows = zeros(0, 6);
    end

    [~, ~, rows(:, 2)] = unique(rows(:, 2));
end
%-----%
