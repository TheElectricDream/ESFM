function dirs = hemisphere_directions(n, pole)
    %   This function is used to generate 'directions' over the upper half
    %   of a unit sphere and then rotate that hemisphere so its center
    %   points along 'pole'
    %
    %   Inputs:
    %       N -> Scalar, number of directions
    %       POLE -> [1, 3], axis the hemisphere is centred on 
    %
    %   Outputs:
    %       DIRS -> [N, 3], unit directions
    
    % The first step is to create evenly spaced samplign indices, where 'b'
    % is the number of samples (or 'directions')
    i = (0:n-1)' + 0.5;

    % For each sample, we assign a height value -- all heights should fall
    % between '0' and '1', meaning they fall in the upper part of a
    % theoretical hemisphere
    z = 1 - i/n;

    % We also need to assign a unique angle for each sample -- a value of
    % '5' was chosen here for no particular reason
    phi = pi * (1 + sqrt(5)) * i;

    % Now we can convert the height and angles into a unit vector on a unit
    % sphere
    d = [sqrt(1-z.^2).*cos(phi), sqrt(1-z.^2).*sin(phi), z];

    % Now we move the axis that the sphere should be centered on -- we have
    % to normalize it first though to make it a unit column vector
    pole = pole(:) / norm(pole);

    % We want to avoid a parallel reference axis for any valid nonzero
    % poles, and we start by choosing the coordinate axis that is least
    % aligned with the pole
    [~, idx]        = min(abs(pole));

    reference       = zeros(3, 1);
    reference(idx)  = 1;

    % Now we construct the perpendicular unit axes
    t1 = cross(pole, reference);
    t1 = t1 / norm(t1);
    t2 = cross(pole, t1);

    % Move the 'd' directions to the coordinate system we just created
    dirs = d(:, 1).*t1' + d(:, 2).*t2' + d(:, 3).*pole';

end