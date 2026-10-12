%-----%
function [tracks, slice_times] = track_events(t, x, y, flow, slice_dt, tcfg)
    %   This function turns a stream of accepted events into 2D feature
    %   tracks. Events are grouped into short time slices and warped to
    %   the slice centre with their normal flow, so every slice shows
    %   sharp edges. Each live track predicts where its edge fragment is,
    %   claims the warped events inside a small disc that also move the
    %   way the track moves, and updates a Kalman filter on position and
    %   velocity. The claimed events give two measurements: their centroid
    %   (position) and their mean normal flow (velocity across the edge).
    %   Unclaimed events seed new tracks; a track lost for a short while
    %   can be resumed by a seed that appears where it was heading.
    %
    %   Inputs:
    %       T -> [N, 1], timestamps of accepted events [s]
    %       X -> [N, 1], x-location of accepted events [px]
    %       Y -> [N, 1], y-location of accepted events [px]
    %       FLOW -> [N, 2], normal flow of accepted events [px/s]
    %       SLICE_DT -> Scalar, duration of a time slice [s]
    %       TCFG -> Struct, tracker parameters (cfg.track)
    %
    %   Outputs:
    %       TRACKS -> {1, K} cell, history of every track longer than
    %              tcfg.min_length; each history is [M, 5] with rows
    %              [time, x, y, normal_x, normal_y]
    %       SLICE_TIMES -> [F, 1], centre time of every slice [s]
    %
    %   Replaces the alpha-beta tracker of the same name (kept in
    %   _removed_2026-10-10). The two ingredients that matter, found by
    %   ablation against motion capture: the direction gate, and the normal
    %   flow of the claimed events used as a velocity measurement.

    % Sort the events in time and define the slices
    [t, order] = sort(t);
    x    = x(order);
    y    = y(order);
    flow = flow(order, :);

    edges       = t(1) : slice_dt : t(end) + slice_dt;
    slice_times = edges(1:end-1).' + slice_dt / 2;
    bounds      = [track.find_slice_starts(t, edges), numel(t) + 1];

    % Kalman model: constant velocity over one slice, with an acceleration
    % noise of tcfg.q_acc
    F = [1 0 slice_dt 0; 0 1 0 slice_dt; 0 0 1 0; 0 0 0 1];
    q = tcfg.q_acc^2;
    d = slice_dt;
    Q = q * [d^4/4 0 d^3/2 0; 0 d^4/4 0 d^3/2; d^3/2 0 d^2 0; 0 d^3/2 0 d^2];

    blank   = struct('p', [], 'v', [], 'P', [], 'n', [], 't', [], 'hist', [], 'miss', 0);
    live    = blank([]);
    done    = blank([]);
    dormant = blank([]);

    for k = 1:numel(edges) - 1
        lo = bounds(k);
        hi = bounds(k+1) - 1;
        tc = slice_times(k);
        if hi < lo
            continue;
        end

        % Events of this slice, warped to the slice centre
        eX = x(lo:hi);
        eY = y(lo:hi);
        eF = flow(lo:hi, :);
        eT = t(lo:hi);
        W  = [eX - eF(:,1) .* (eT - tc), eY - eF(:,2) .* (eT - tc)];
        D  = geom.unit_rows(eF);
        used = false(numel(eX), 1);

        % Predict and update the live tracks, longest first
        if ~isempty(live)
            ages = arrayfun(@(s) size(s.hist, 1), live);
            [~, order] = sort(ages, 'descend');

            pred = zeros(numel(live), 2);
            for i = 1:numel(live)
                st = F * [live(i).p(:); live(i).v(:)];
                live(i).p = st(1:2)';
                live(i).v = st(3:4)';
                live(i).P = F * live(i).P * F' + Q;
                live(i).t = tc;
                pred(i, :) = st(1:2)';
            end

            nbs = rangesearch(W, pred, tcfg.disc_px);
            for i = order
                nb = nbs{i}(:);
                nb = nb(~used(nb));
                if numel(nb) < tcfg.min_events
                    live(i).miss = live(i).miss + 1;
                    continue;
                end

                % Own events: inside the disc and moving the track's way
                n   = live(i).n;
                own = D(nb, :) * n' > tcfg.cos_edge;
                if nnz(own) < tcfg.min_events
                    live(i).miss = live(i).miss + 1;
                    continue;
                end
                io     = nb(own);
                n_meas = geom.unit_rows(mean(D(io, :), 1));
                pe     = W(io, :) - pred(i, :);

                % Measurements: the centroid offset (both directions) and
                % the normal flow as the velocity across the edge
                zv    = mean(eF(io, :) * n_meas');
                sig_v = max(tcfg.sigma_v_floor, tcfg.sigma_v_rel * abs(zv));
                H  = [1 0 0 0; 0 1 0 0; 0 0 n_meas];
                R  = diag([tcfg.sigma_n^2, tcfg.sigma_n^2, sig_v^2]);
                zz = [mean(pe, 1)'; zv - live(i).v * n_meas'];

                Pp = live(i).P;
                S  = H * Pp * H' + R;
                K  = Pp * H' / S;
                st = [pred(i, :)'; live(i).v(:)] + K * zz;
                Pp = (eye(4) - K * H) * Pp;
                Pp = (Pp + Pp') / 2;

                used(io)  = true;
                live(i).p = st(1:2)';
                live(i).v = st(3:4)';
                live(i).P = Pp;
                live(i).n = n_meas;
                live(i).t = tc;
                live(i).hist(end+1, :) = [tc, st(1:2)', n_meas];
                live(i).miss = 0;
            end

            % Retire tracks unseen for too long; long ones stay dormant for
            % a while so a compatible seed can resume them
            retire = [live.miss] > tcfg.max_miss;
            if any(retire)
                r    = live(retire);
                long = arrayfun(@(s) size(s.hist, 1), r) >= tcfg.min_length;
                done    = [done, r(~long)];    %#ok<AGROW>
                dormant = [dormant, r(long)];  %#ok<AGROW>
                live    = live(~retire);
            end
            if ~isempty(dormant)
                expired = [dormant.t] < tc - tcfg.dormant_s - tcfg.max_miss * slice_dt;
                done    = [done, dormant(expired)]; %#ok<AGROW>
                dormant = dormant(~expired);
            end
        end

        % Seed new tracks from the unclaimed events, one per grid cell
        % whose events share one flow direction
        un = find(~used);
        if ~isempty(un)
            key = floor(W(un, 2) / tcfg.seed_cell_px) * 10000 + floor(W(un, 1) / tcfg.seed_cell_px);
            [~, ~, inv] = unique(key);
            cnt = accumarray(inv, 1);
            for c = find(cnt >= tcfg.min_events)'
                ids  = un(inv == c);
                mdir = mean(D(ids, :), 1);
                coh  = norm(mdir);
                if coh < tcfg.min_coherence
                    continue;
                end
                n  = mdir / coh;
                tg = [-n(2), n(1)];
                p0 = mean(W(ids, :), 1);
                v0 = mean(eF(ids, :), 1);
                Rnt  = [n; tg];
                Ppos = Rnt' * diag([tcfg.sigma_n^2, tcfg.seed_sigma_t^2]) * Rnt;
                P0   = blkdiag(Ppos, tcfg.seed_sigma_v^2 * eye(2));

                % Resume a dormant track that predicts here with the same
                % edge, otherwise start a new one
                resumed = false;
                if ~isempty(dormant)
                    dp  = reshape([dormant.p], 2, [])';
                    dv  = reshape([dormant.v], 2, [])';
                    dn  = reshape([dormant.n], 2, [])';
                    dtd = tc - [dormant.t]';
                    pp  = dp + dv .* dtd;
                    ok  = vecnorm(pp - p0, 2, 2) < tcfg.dormant_gate_px & dn * n' > tcfg.dormant_cos;
                    if any(ok)
                        j = find(ok);
                        [~, jj] = min(vecnorm(pp(j, :) - p0, 2, 2));
                        j = j(jj);
                        s = dormant(j);
                        dormant(j) = [];
                        s.p = p0; s.v = v0; s.P = P0; s.n = n; s.t = tc; s.miss = 0;
                        s.hist(end+1, :) = [tc, p0, n];
                        live(end+1) = s; %#ok<AGROW>
                        resumed = true;
                    end
                end
                if ~resumed
                    s = blank;
                    s.p = p0; s.v = v0; s.P = P0; s.n = n; s.t = tc; s.miss = 0;
                    s.hist = [tc, p0, n];
                    live(end+1) = s; %#ok<AGROW>
                end
                used(ids) = true;
            end
        end
    end

    % Every track that lasted long enough, whatever state it ended in
    done   = [done, dormant, live];
    lens   = arrayfun(@(s) size(s.hist, 1), done);
    done   = done(lens >= tcfg.min_length);
    tracks = {done.hist};
end
%-----%
