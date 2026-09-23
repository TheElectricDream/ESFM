t_lo = 100; t_hi = 100.5;                       % any 0.5 s slice
w = ev.t >= t_lo & ev.t < t_hi;
a = w & ev.accept;  r = w & ~ev.accept;

figure; hold on; axis ij equal; xlim([0 640]); ylim([0 480]);
scatter(ev.x(r), ev.y(r), 2, [0.8 0.8 0.8], '.');
scatter(ev.x(a), ev.y(a), 3, ev.p(a), '.');       % colour = polarity
title(sprintf('accepted (colour) vs rejected (grey), %.1f-%.1f s', t_lo, t_hi));

i = find(a); i = i(1:20:end);                    % thin out for legibility
figure; quiver(ev.x(i), ev.y(i), ev.flow(i,1), ev.flow(i,2), 0.5);
axis ij equal; title('normal flow');

figure; histogram(hypot(ev.flow(ev.accept,1), ev.flow(ev.accept,2)), 0:1:60);
xlabel('|normal flow| [px/s]');

t_ref = (t_lo + t_hi) / 2;
xw = ev.x(a) - ev.flow(a,1) .* (ev.t(a) - t_ref);
yw = ev.y(a) - ev.flow(a,2) .* (ev.t(a) - t_ref);
figure;
subplot(1,2,1); histogram2(ev.x(a), ev.y(a), 0:2:640, 0:2:480, 'DisplayStyle','tile'); axis ij equal; title('raw accumulation');
subplot(1,2,2); histogram2(xw, yw, 0:2:640, 0:2:480, 'DisplayStyle','tile'); axis ij equal; title('flow-compensated');

figure; plot(accumarray(floor(ev.t - ev.t(1)) + 1, ev.accept) ./ accumarray(floor(ev.t - ev.t(1)) + 1, 1));
xlabel('s since T0'); ylabel('accept fraction');