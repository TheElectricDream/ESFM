function R = rodrigues_entries(axis_unit, theta)
% Rodrigues' formula: R(theta) = cos(theta) I + sin(theta)[a]_x
%                                + (1-cos(theta)) a*a'.
% Store each entry as a vector to project all observation poses together;
% this avoids a loop that constructs thousands of individual 3-by-3 matrices.
% Entries of R = cos I + sin [a]_x + (1 - cos) a a', one array per entry.
a1 = axis_unit(1);
a2 = axis_unit(2);
a3 = axis_unit(3);
c = cos(theta);
s = sin(theta);
v = 1 - c;
R.r11 = c + v*a1*a1;
R.r12 = v*a1*a2 - s*a3;
R.r13 = v*a1*a3 + s*a2;
R.r21 = v*a2*a1 + s*a3;
R.r22 = c + v*a2*a2;
R.r23 = v*a2*a3 - s*a1;
R.r31 = v*a3*a1 - s*a2;
R.r32 = v*a3*a2 + s*a1;
R.r33 = c + v*a3*a3;
end
