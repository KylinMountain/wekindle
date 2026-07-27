-- Pure-Lua QR Code generator (byte mode, ECC level M, versions 1-8).
-- No native dependencies — suitable for the standalone app and Kindle.
--
--   local matrix = QR.encode_to_matrix(text)   -- [row][col] = true (dark)
--   print(QR.to_terminal(matrix))              -- ANSI block rendering
--
-- Validated against the segno Python oracle (tools/smoke/qr_oracle.py).

local bit = require("bit")

local QR = {}

-- ---------------------------------------------------------------- GF(256)

local GF_EXP = {}
local GF_LOG = {}
do
    local x = 1
    for i = 0, 254 do
        GF_EXP[i] = x
        GF_LOG[x] = i
        x = bit.lshift(x, 1)
        if x >= 256 then
            x = bit.bxor(x, 0x11d)
        end
    end
    for i = 255, 511 do
        GF_EXP[i] = GF_EXP[i - 255]
    end
end

local function gf_mul(a, b)
    if a == 0 or b == 0 then
        return 0
    end
    return GF_EXP[GF_LOG[a] + GF_LOG[b]]
end

-- Generator polynomial for `degree` error-correction codewords.
local function rs_generator(degree)
    local poly = { 1 }
    for i = 0, degree - 1 do
        local next_poly = {}
        for j = 1, #poly + 1 do
            next_poly[j] = 0
        end
        for j = 1, #poly do
            next_poly[j] = bit.bxor(next_poly[j], poly[j])
            next_poly[j + 1] = bit.bxor(next_poly[j + 1], gf_mul(poly[j], GF_EXP[i]))
        end
        poly = next_poly
    end
    return poly
end

local function rs_encode(data, degree)
    local gen = rs_generator(degree)
    local result = {}
    for i = 1, #data + degree do
        result[i] = 0
    end
    for i = 1, #data do
        result[i] = data[i]
    end
    for i = 1, #data do
        local coef = result[i]
        if coef ~= 0 then
            for j = 1, #gen do
                result[i + j - 1] = bit.bxor(result[i + j - 1], gf_mul(gen[j], coef))
            end
        end
    end
    local ecc = {}
    for i = 1, degree do
        ecc[i] = result[#data + i]
    end
    return ecc
end

-- ------------------------------------------------- version table (ECC = M)
-- { total_codewords, ecc_per_block, { data_codewords_per_block... } }
local VERSIONS = {
    { 26, 10, { 16 } },
    { 44, 16, { 28 } },
    { 70, 26, { 44 } },
    { 100, 18, { 32, 32 } },
    { 134, 24, { 43, 43 } },
    { 172, 16, { 27, 27, 27, 27 } },
    { 196, 18, { 31, 31, 31, 31 } },
    { 242, 22, { 38, 38, 39, 39 } },
}

-- Alignment pattern centers, 1-based (standard tables are 0-based; +1).
local ALIGNMENT = {
    [2] = { 7, 19 },
    [3] = { 7, 23 },
    [4] = { 7, 27 },
    [5] = { 7, 31 },
    [6] = { 7, 35 },
    [7] = { 7, 23, 39 },
    [8] = { 7, 25, 43 },
}

local REMAINDER_BITS = { 0, 7, 7, 7, 7, 7, 0, 0 }

-- ------------------------------------------------------- data codewords

local function build_data_codewords(text, version)
    local total_cw, _ecc, block_sizes = unpack(VERSIONS[version])
    local data_cw = 0
    for _i, n in ipairs(block_sizes) do
        data_cw = data_cw + n
    end

    local bits = {}
    local function push(value, count)
        for i = count - 1, 0, -1 do
            bits[#bits + 1] = bit.band(bit.rshift(value, i), 1)
        end
    end

    push(4, 4)                  -- byte mode indicator
    push(#text, version <= 9 and 8 or 16)
    for i = 1, #text do
        push(text:byte(i), 8)
    end
    local capacity = data_cw * 8
    local terminator = math.min(4, capacity - #bits)
    push(0, terminator)
    while #bits % 8 ~= 0 do
        bits[#bits + 1] = 0
    end
    local pad = { 0xec, 0x11 }
    local pad_index = 1
    while #bits < capacity do
        push(pad[pad_index], 8)
        pad_index = 3 - pad_index
    end

    local codewords = {}
    for i = 1, #bits, 8 do
        local value = 0
        for j = 0, 7 do
            value = value * 2 + bits[i + j]
        end
        codewords[#codewords + 1] = value
    end
    return codewords
end

local function interleave_with_ecc(data_cw, version)
    local _total, ecc_len, block_sizes = unpack(VERSIONS[version])
    local blocks = {}
    local offset = 1
    for _i, size in ipairs(block_sizes) do
        local data = {}
        for i = 1, size do
            data[i] = data_cw[offset + i - 1]
        end
        offset = offset + size
        blocks[#blocks + 1] = { data = data, ecc = rs_encode(data, ecc_len) }
    end

    local out = {}
    local max_data = 0
    for _i, b in ipairs(blocks) do
        max_data = math.max(max_data, #b.data)
    end
    for i = 1, max_data do
        for _b, block in ipairs(blocks) do
            if block.data[i] ~= nil then
                out[#out + 1] = block.data[i]
            end
        end
    end
    for i = 1, ecc_len do
        for _b, block in ipairs(blocks) do
            out[#out + 1] = block.ecc[i]
        end
    end
    return out
end

-- ------------------------------------------------------------- matrix

local function new_matrix(size)
    local m = {}
    for r = 1, size do
        m[r] = {}
    end
    return m
end

local function set_fixed(m, r, c, dark)
    m[r][c] = dark and 1 or 0
end

local function place_finder(m, r0, c0)
    for dr = -1, 7 do
        for dc = -1, 7 do
            local r, c = r0 + dr, c0 + dc
            if r >= 1 and r <= #m and c >= 1 and c <= #m then
                local edge = dr == -1 or dr == 7 or dc == -1 or dc == 7
                local ring = dr == 0 or dr == 6 or dc == 0 or dc == 6
                local core = dr >= 2 and dr <= 4 and dc >= 2 and dc <= 4
                set_fixed(m, r, c, not edge and (ring or core))
            end
        end
    end
end

local function place_alignment(m, centers)
    for _i, r in ipairs(centers) do
        for _j, c in ipairs(centers) do
            -- skip the three finder corners (top-left, top-right, bottom-left)
            local corner = (r == centers[1] and c == centers[1])
                or (r == centers[1] and c == centers[#centers])
                or (r == centers[#centers] and c == centers[1])
            if not corner then
                for dr = -2, 2 do
                    for dc = -2, 2 do
                        local ring = math.max(math.abs(dr), math.abs(dc))
                        set_fixed(m, r + dr, c + dc, ring ~= 1)
                    end
                end
            end
        end
    end
end

local function place_timing(m)
    local size = #m
    for i = 9, size - 8 do
        local dark = (i % 2) == 1
        set_fixed(m, 7, i, dark)
        set_fixed(m, i, 7, dark)
    end
end

local MASKS = {
    function(r, c) return (r + c) % 2 == 0 end,
    function(r, c) return r % 2 == 0 end,
    function(r, c) return c % 3 == 0 end,
    function(r, c) return (r + c) % 3 == 0 end,
    function(r, c) return (math.floor(r / 2) + math.floor(c / 3)) % 2 == 0 end,
    function(r, c) return (r * c) % 2 + (r * c) % 3 == 0 end,
    function(r, c) return ((r * c) % 2 + (r * c) % 3) % 2 == 0 end,
    function(r, c) return ((r + c) % 2 + (r * c) % 3) % 2 == 0 end,
}

local FORMAT_ECL_M = 0  -- level M format prefix bits = 00

local function format_bits(mask)
    local data = FORMAT_ECL_M * 8 + mask  -- 5 bits
    local value = data
    for _i = 1, 10 do
        value = bit.lshift(value, 1)
        if value >= 0x400 then
            value = bit.bxor(value, 0x537)
        end
    end
    local bch = bit.band(value, 0x3ff)
    return bit.bxor(bit.lshift(data, 10) + bch, 0x5412)
end

local function place_format(m, mask)
    local size = #m
    local bits = format_bits(mask)
    local function fbit(i)
        return bit.band(bit.rshift(bits, 14 - i), 1) == 1
    end
    -- copy 1: around the top-left finder
    for i = 0, 5 do set_fixed(m, 9, i + 1, fbit(i)) end
    set_fixed(m, 9, 8, fbit(6))
    set_fixed(m, 9, 9, fbit(7))
    set_fixed(m, 8, 9, fbit(8))
    for i = 9, 14 do set_fixed(m, 15 - i, 9, fbit(i)) end
    -- copy 2: integer bit j (LSB-indexed) at (8, size-1-j) for j=0..7,
    -- and at (size-15+j, 8) for j=8..14. fbit(k) returns integer bit (14-k).
    -- Reference: ISO/IEC 18004 §7.9.1.
    for i = 0, 7 do set_fixed(m, 9, size - i, fbit(14 - i)) end
    for i = 8, 14 do set_fixed(m, size - 14 + i, 9, fbit(14 - i)) end
end

local function place_data(m, codewords, version)
    local size = #m
    local bits = {}
    for _i, cw in ipairs(codewords) do
        for i = 7, 0, -1 do
            bits[#bits + 1] = bit.band(bit.rshift(cw, i), 1)
        end
    end
    for _i = 1, REMAINDER_BITS[version] do
        bits[#bits + 1] = 0
    end

    local index = 0
    local upward = true
    local col = size
    while col >= 1 do
        if col == 7 then
            col = col - 1  -- skip the vertical timing column (1-based col 7)
        end
        for row_step = 0, size - 1 do
            local r = upward and (size - row_step) or (1 + row_step)
            for dc = 0, 1 do
                local c = col - dc
                if m[r][c] == nil then
                    index = index + 1
                    m[r][c] = (bits[index] or 0) + 10  -- 10/11 = unfinalized data
                end
            end
        end
        upward = not upward
        col = col - 2
    end
end

-- --------------------------------------------------------- penalties

local function penalty(m)
    local size = #m
    local score = 0

    -- rule 1: runs of >= 5 identical modules in rows/columns
    for r = 1, size do
        local run_color, run_len = m[r][1], 1
        for c = 2, size do
            if m[r][c] == run_color then
                run_len = run_len + 1
            else
                if run_len >= 5 then
                    score = score + 3 + (run_len - 5)
                end
                run_color, run_len = m[r][c], 1
            end
        end
        if run_len >= 5 then
            score = score + 3 + (run_len - 5)
        end
    end
    for c = 1, size do
        local run_color, run_len = m[1][c], 1
        for r = 2, size do
            if m[r][c] == run_color then
                run_len = run_len + 1
            else
                if run_len >= 5 then
                    score = score + 3 + (run_len - 5)
                end
                run_color, run_len = m[r][c], 1
            end
        end
        if run_len >= 5 then
            score = score + 3 + (run_len - 5)
        end
    end

    -- rule 2: 2x2 blocks
    for r = 1, size - 1 do
        for c = 1, size - 1 do
            local v = m[r][c]
            if m[r][c + 1] == v and m[r + 1][c] == v and m[r + 1][c + 1] == v then
                score = score + 3
            end
        end
    end

    -- rule 3: finder-like patterns in rows/columns
    local p1 = { 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0 }
    local p2 = { 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1 }
    local function matches(line, pos, pat)
        for i = 0, 10 do
            if line[pos + i] ~= pat[i + 1] then
                return false
            end
        end
        return true
    end
    for r = 1, size do
        for c = 1, size - 10 do
            if matches(m[r], c, p1) or matches(m[r], c, p2) then
                score = score + 40
            end
        end
    end
    for c = 1, size do
        local column = {}
        for r = 1, size do
            column[r] = m[r][c]
        end
        for r = 1, size - 10 do
            if matches(column, r, p1) or matches(column, r, p2) then
                score = score + 40
            end
        end
    end

    -- rule 4: dark ratio
    local dark = 0
    for r = 1, size do
        for c = 1, size do
            if m[r][c] == 1 then
                dark = dark + 1
            end
        end
    end
    local total = size * size
    score = score + math.floor(math.abs(dark * 20 - total * 10) / total) * 10

    return score
end

-- ---------------------------------------------------------------- API

function QR.encode_to_matrix(text, force_mask)
    assert(type(text) == "string" and #text > 0, "QR: text required")
    local version
    for v = 1, #VERSIONS do
        local capacity = 0
        for _i, n in ipairs(VERSIONS[v][3]) do
            capacity = capacity + n
        end
        -- byte mode: 4 mode bits + 8 count bits + data; count field fits v<=9
        if 4 + 8 + #text * 8 <= capacity * 8 then
            version = v
            break
        end
    end
    assert(version, "QR: text too long for supported versions (max 152 bytes)")

    local data_cw = build_data_codewords(text, version)
    local codewords = interleave_with_ecc(data_cw, version)

    local size = 17 + version * 4
    local best, best_score
    local first_mask = force_mask or 0
    local last_mask = force_mask or 7
    for mask = first_mask, last_mask do
        local m = new_matrix(size)
        place_finder(m, 1, 1)
        place_finder(m, 1, size - 6)
        place_finder(m, size - 6, 1)
        place_timing(m)
        if ALIGNMENT[version] then
            place_alignment(m, ALIGNMENT[version])
        end
        set_fixed(m, size - 7, 9, true)  -- dark module
        place_format(m, mask)
        place_data(m, codewords, version)

        -- finalize: apply mask to data modules only
        local mask_fn = MASKS[mask + 1]
        for r = 1, size do
            for c = 1, size do
                local v = m[r][c]
                if v ~= nil and v >= 10 then
                    local dark = (v - 10) == 1
                    if mask_fn(r - 1, c - 1) then
                        dark = not dark
                    end
                    m[r][c] = dark and 1 or 0
                end
            end
        end

        local score = penalty(m)
        if not best_score or score < best_score then
            best, best_score = m, score
        end
    end
    return best
end

-- Render with ANSI upper-half-block characters (2 module rows per line),
-- including the 4-module quiet zone.
function QR.to_terminal(matrix)
    local size = #matrix
    local function dark(r, c)
        if r < 1 or r > size or c < 1 or c > size then
            return false
        end
        return matrix[r][c] == 1
    end
    local lines = {}
    local quiet = 4
    local total = size + quiet * 2
    for row = 1, total, 2 do
        local chars = {}
        for col = 1, total do
            local up = dark(row - quiet, col - quiet)
            local down = dark(row + 1 - quiet, col - quiet)
            if up and down then
                chars[#chars + 1] = "█"
            elseif up then
                chars[#chars + 1] = "▀"
            elseif down then
                chars[#chars + 1] = "▄"
            else
                chars[#chars + 1] = " "
            end
        end
        lines[#lines + 1] = table.concat(chars)
    end
    return table.concat(lines, "\n")
end

return QR
