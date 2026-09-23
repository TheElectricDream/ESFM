function [map, info] = step(map, slice, tc, cfg, cam)
    %   This function processes one slice of events and updates the map.
    %   It is the unit of the progressive (eventually real-time) stage:
    %   it only uses the current slice and the state in MAP, never future
    %   data or global slice indices.
    %
    %   Stages:
    %       1. Warp events to tc                                    (Part 3)
    %       2. Predict, associate, flag ambiguity                   (Parts 3-4)
    %       3. Correct the recent motion, re-associate, commit      (Part 5)
    %       4. Track and seed 2D candidates                         (Part 6)
    %       5. Promote mature candidates to landmarks               (Part 7)
    %
    %   Inputs:
    %       MAP -> Struct from prog.create_map, current state
    %       SLICE -> Struct with fields t, x, y [E, 1] and flow [E, 2],
    %              the accepted events of this slice
    %       TC -> Scalar, slice centre time [s]
    %       CFG -> Struct, full configuration
    %       CAM -> Struct, camera model
    %
    %   Outputs:
    %       MAP -> Struct, updated state
    %       INFO -> Struct, per-slice diagnostics:
    %              explained         fraction of events claimed (NaN if
    %                                the slice is empty)
    %              matched           number of landmarks that claimed
    %              corrected         logical, the motion correction ran
    %              correction_steps  accepted LM steps in the correction
    %              n_new             number of landmarks promoted

    info = struct('explained', NaN, 'matched', 0, 'corrected', false, ...
                  'correction_steps', 0, 'n_new', 0);

    % 1. Warp events to tc -- independent of the motion, so done once
    [warped, direction] = prog.warp_events(slice, tc);

    % 2-3. Associate; if enough unambiguous claims, correct the recent
    % motion and associate again with the corrected motion
    for pass = 1:2
        pred      = prog.predict(map, tc, cam, cfg);
        nrm_k     = map.nrm(pred.ids, :);
        ambiguous = prog.find_ambiguous(pred, nrm_k, cfg);
        claims    = prog.associate(pred, warped, direction, slice, nrm_k, ...
                                   map.nobs(pred.ids), ambiguous, cfg);

        % Store the latest normal of every landmark that claimed --
        % equivalent to gold's in-loop update, since each landmark claims
        % at most once per pass and gates on its previous normal
        map.nrm(claims.rows(:, 2), :) = claims.rows(:, 5:6);

        if pass == 1 && map.knots_free && ...
                nnz(claims.mature) >= cfg.prog.min_mature_claims
            [map.traj, corr] = prog.correct_motion(map, claims.rows, tc, cam, cfg);
            info.corrected        = true;
            info.correction_steps = corr.accepted_steps;
        else
            break;
        end
    end

    % Commit the claims of the last pass
    map = prog.commit_observations(map, claims.rows);

    % Diagnostics
    if ~isempty(claims.ratio)
        map.ratio(end+1) = median(claims.ratio);
    end
    info.explained = mean(claims.used);
    info.matched   = nnz(claims.found);

    % 4. Track 2D candidates on the events no landmark claimed
    available = ~claims.used;
    [map.cand, taken] = prog.update_candidates(map.cand, warped, slice, available, tc, cfg);

    % 5. Promote mature candidates to landmarks
    [map, promo] = prog.promote_candidates(map, tc, cam, cfg);
    info.n_new   = promo.promoted;
    info.promo   = promo;

    % 6. Seed new candidates on the events nobody used
    map.cand    = prog.seed_candidates(map.cand, warped, slice, available & ~taken, tc, cfg);
    info.n_cand = numel(map.cand);
end