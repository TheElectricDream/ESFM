function rr = cauchy(r, scale)
    %   The purpose of this function is simply to set up the actual cost
    %   function that we will be using -- the cost function has the form
    %   described in this paper by Google:
    %
    %   Paper: https://ieeexplore.ieee.org/document/8954089/
    %
    %   Inputs:
    %       R -> [M, 1], raw residuals [px]
    %       SCALE -> Scalar, residual size beyond which errors are discounted [px]
    %
    %   Outputs:
    %       RR -> [M, 1], transformed residuals; sum(RR.^2) is the Cauchy loss
    
    rr = sign(r) .* scale .* sqrt(log1p((r / scale).^2));
end