
figure('Color', 'w');

plot(rates, prof, 'o-');  % rates: the RATES passed to warm.rate_profile
hold on;

valid = isfinite(prof);
if any(valid)
    yline(min(prof(valid)) + 2, '--', 'Minimum + 2');
end

xline(rad2deg(bestRefined.w), '--', 'Refined rate');

xlabel('Prescribed angular rate [deg/s]');
ylabel('Profile cost');
title('Fixed-axis rate profile: centre and drift refitted');
grid on;