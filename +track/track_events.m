function [tracks, slice_times] = track_events(t, x, y, flow, slice_dt, tcfg)

    %   This function takes in a continuous stream of events and
    %   discretizes it into chunks. Active tracks for features are used to
    %   predict where events should be based on their current velocity. At
    %   the predicted location, unclaimed events are claimed and their
    %   states are updated using a fixed-gain Alpha-=Beta filter. Unclaimed
    %   events are then used to seed new tracks.
    %
    %   Inputs:
    %       T -> [N, 1], timestamps for accepted events
    %       X -> [N, 1], x-location of accepted events [px]
    %       Y -> [N, 1], y-location of accepted events [px]
    %       FLOW -> [N, 2], normal optical flow of accepted events [px/s]
    %       SLICE_DT -> Scaler, duration of time slices [s]
    %       TCFG -> Struct, contains tracking related parameters
    %
    %   Outputs:
    %       TRACKS -> {1, K}, Cell Array where each cell holds the history
    %       matrix of a track which has survived the minimum length
    %       threshold -- Each matrix is [M, 5] and contains [time, x, y,
    %       normal_x, normal_y]
    %
    %   Novelty: As far as I have found in literature, coupling normal flow
    %   to align events within short time slices and attaching an
    %   edge-normal direction to each tracked observation is novel and
    %   allows me to place normal constraints. This is not specific to
    %   event cameras, but combining event-level motion with normal tracks
    %   IS novel.

    % First we have to prepare the incoming events by sorting them
    % according to their timestamps
    [sortedT, sortIdx]  = sort(t);
    sortedX             = x(sortIdx);
    sortedY             = y(sortIdx);
    sortedFlow          = flow(sortIdx, :);

    % Working on a single event alone is obviously ideal, but I'm not quite
    % there yet. But I also do not want to work on event frames. So, we
    % will define 'chunks' of time and we will look at the events within a
    % given chunk
    edges       = sortedT(1) : slice_dt : sortedT(end) + slice_dt;
    slice_times = edges(1:end-1).';
    slice_times = slice_times + slice_dt / 2;
    bounds      = [track.find_slice_starts(sortedT, edges), numel(sortedT)+1];

    % We also need to define some empty storage arrays up front -- 'live'
    % and 'done', which will contain any tracks currently following edges
    % and any tracks that are done (respectively)
    live = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {},...
        't', {}, 'hist', {}, 'miss', {});
    done = struct('x', {}, 'y', {}, 'vx', {}, 'vy', {},...
        't', {}, 'hist', {}, 'miss', {});

    % Now we need to start our loop and step through one time-slice at a
    % time
    for k = 1:numel(edges) - 1
        
        % Grab the lower and upper bounds of the current chunk, and then
        % grab the middle time for the slice (tc)
        lo = bounds(k);
        hi = bounds(k+1) - 1;
        tc = slice_times(k);

        % Grabbing chunks of data as above results in blur along fast
        % moving edges, which is bad for reconstruction

        % This is where the flow calculation comes into play, as we can use
        % the flow to estimate where each event SHOULD be based on it's
        % velocity -- first we extract the events from the sorted arrays
        eX = sortedX(lo:hi);
        eY = sortedY(lo:hi);
        eF = sortedFlow(lo:hi, :);
        eT = sortedT(lo:hi);

        % Then we MOVE the events to where they SHOULD be at the middle
        % time step 'tc'
        eX_warped = eX - eF(:, 1) .* (eT - tc);
        eY_warped = eY - eF(:, 2) .* (eT - tc);
        used      = false(numel(eX), 1);

        % Now we want to predict where a track will go next based on it's
        % current speed -- for all currently active tracks, we check how
        % much time has passed since they were last updated. Basically, if
        % we assume that a track is moving at it's last known velocity, we
        % want to predict where it should be NOW (px, py)
        if ~isempty(live)
            
            dTp = tc - [live.t]';  % Calculate last update time
            pX  = [live.x]' + [live.vx]' .* dTp;
            pY  = [live.y]' + [live.vy]' .* dTp;

            % Using where we think the track should be, we draw a circle
            % around that location and we extract all new events in that
            % range
            nbs = rangesearch([eX_warped, eY_warped], [pX, pY],...
                tcfg.gate_px);

            % Next, we loop over all the live tracks and check if we have
            % sufficient unclaimed events within the circle -- if we do,
            % then we calculate the 'center of mass' of those events and
            % consider that to be the new 'measurement' for the track
            for i = 1:numel(live)
                
                % Here, 'nb' contains the candidate events in [eX, eY]
                % within 'gate_px' of [pX, pY]
                nb = nbs{i};
                nb = nb(~used(nb));
                
                if numel(nb) >= tcfg.min_events
                    
                    % Mark the events as claimed
                    used(nb) = true;

                    % Calculate the average position for the claimed events
                    zX = mean(eX_warped(nb));
                    zY = mean(eY_warped(nb));

                    % Use an Alpha-Beta tracker to calculate the next live
                    % measurement -- This COULD be a Kalman Filter here,
                    % but for now this is easier. It assumes that the
                    % system can be modelled a simple two-state model
                    live(i).vx = live(i).vx +...
                        tcfg.gain_velocity * (zX - pX(i))/dTp(i);
                    live(i).vy = live(i).vy +...
                        tcfg.gain_velocity * (zY - pY(i))/dTp(i);
                    live(i).x = pX(i) + tcfg.gain_position*(zX - pX(i));
                    live(i).y = pY(i) + tcfg.gain_position*(zY - pY(i));

                    % Log the time stamp of this chunk (the middle time)
                    live(i).t = tc;
                    
                    % Normalize the edge direction vector so that it has a
                    % length of '1'
                    normVec = mean(eF(nb, :), 1);
                    normVec = normVec / max(norm(normVec), 1e-9);

                    % Save the updated state to the tracks history
                    live(i).hist(end + 1, :) = [tc, live(i).x, ...
                        live(i).y, normVec];
                    live(i).miss = 0;

                else

                    % If a track failed to find enough events to meet the
                    % minimum we set, then we increment the miss tracker
                    live(i).miss = live(i).miss + 1;

                end

            end

            % If a track has missed more then our 'max_miss' parameter,
            % we consider it to be a 'dead' track and we remove it
            retire  = [live.miss] > tcfg.max_miss;

            % Then, we update the 'done' array and the 'live' arrays
            done    = [done, live(retire)]; %#ok<AGROW>
            live    = live(~retire);

        end

        % Once all of the currently live tracks have claimed events,
        % there will be some remaining unclaimed (in fact, on startup
        % there would be no live tracks so the code jumps right to
        % here) -- we want to use these to seed new tracks
        unclaimed = find(~used);
            
        if ~isempty(unclaimed)
            
            % All this code is doing is dividing the 'frame' into a
            % grid cell using a hasing trick (y * 10000 + x)
            key = floor(eY_warped(unclaimed) / tcfg.seed_cell_px)...
                * 10000 + floor(eX_warped(unclaimed) / tcfg.seed_cell_px);
            [~, ~, inv] = unique(key);

            % Then, we use 'accumarray' to count the number of
            % unclaimed events in each grid cell
            countUnclaimed = accumarray(inv, 1);

            % If a grid cell has enough remaining events clumped
            % together, we can infer that there might be a new edge
            % which can be added to the live pool
            for c = find(countUnclaimed >= tcfg.min_events)'

                % Extract the unclaimed event in the current grid cell
                currentUnclaimedEvents = unclaimed(inv == c);

                % Calculate the edge normal and normalize it to '1'
                normVec = mean(eF(currentUnclaimedEvents, :), 1);
                normVec = normVec / max(norm(normVec), 1e-9);

                % Update the 'live' track structure
                live(end+1) = struct(...
                    'x', mean(eX_warped(currentUnclaimedEvents)), ...
                    'y', mean(eY_warped(currentUnclaimedEvents)), ...
                    'vx', mean(eF(currentUnclaimedEvents, 1)), ...
                    'vy', mean(eF(currentUnclaimedEvents, 2)), ...
                    't', tc, ...
                    'hist', [tc, mean(eX_warped(currentUnclaimedEvents)), ...
                    mean(eY_warped(currentUnclaimedEvents)), normVec], ...
                    'miss', 0); %#ok<AGROW>

            end

        end
              
    end  % END of the TIME-SLICE LOOP

    % After going through all the time-slices, we have some cleanup to do;
    % first we move all remaining 'live' tracks to 'done'
    done = [done, live]; 

    % Next, we find the length for all tracks by summing up their hist
    % entries
    trackLengths = arrayfun(@(tr) size(tr.hist, 1), done);

    % We only want to keep tracks which are long enough, so we use
    % 'min_length' to filter out short tracks
    validTracks = done(trackLengths >= tcfg.min_length);

    % Lastly, extract only the history matrices and return those as
    % functions outputs
    tracks = {validTracks.hist};

end