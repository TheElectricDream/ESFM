function Rs = select_entries(R, idx)
Rs = structfun(@(e) e(idx), R, 'UniformOutput', false);
end
