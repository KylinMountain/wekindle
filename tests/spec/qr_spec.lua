-- Golden tests for the pure-Lua QR encoder: full matrix byte-equality
-- against the pyqrcode oracle (tests/fixtures/qr_matrices.lua).

local QR = require("qr")
local fixtures = dofile("tests/fixtures/qr_matrices.lua")

local failures, checks = 0, 0

for _i, fixture in ipairs(fixtures) do
    checks = checks + 1
    local m = QR.encode_to_matrix(fixture.text)
    local expected = fixture.matrix
    local label = fixture.text:sub(1, 30)
    if #m ~= #expected then
        failures = failures + 1
        print(string.format("FAIL %s: size %d, want %d", label, #m, #expected))
    else
        local diff = 0
        for r = 1, #m do
            local row = {}
            for c = 1, #m do
                row[c] = m[r][c] == 1 and "1" or "0"
            end
            local got = table.concat(row)
            if got ~= expected[r] then
                for c = 1, #m do
                    if got:sub(c, c) ~= expected[r]:sub(c, c) then
                        diff = diff + 1
                    end
                end
            end
        end
        if diff > 0 then
            failures = failures + 1
            print(string.format("FAIL %s: %d module diffs", label, diff))
        end
    end
end

-- terminal renderer smoke: quiet zone + correct line count
do
    checks = checks + 1
    local m = QR.encode_to_matrix("HELLO")
    local rendered = QR.to_terminal(m)
    local lines = 0
    for _ in rendered:gmatch("[^\n]+") do
        lines = lines + 1
    end
    -- (21 + 8) module rows, 2 rows per line -> 15 lines (odd row count rounds up)
    if lines ~= 15 then
        failures = failures + 1
        print(string.format("FAIL terminal render lines: got %d, want 15", lines))
    end
end

print(string.format("qr_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then
    os.exit(1)
end
