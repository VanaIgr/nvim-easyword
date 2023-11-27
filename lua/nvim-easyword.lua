local api = vim.api

-- code is taken from https://github.com/VanaIgr/leap-by-word.nvim.git
-- (fork from https://github.com/Sleepful/leap-by-word.nvim)

local function replace_keycodes(s)
    return api.nvim_replace_termcodes(s, true, false, true)
end

local esc = replace_keycodes("<esc>")
local function get_input()
    local ok, ch = pcall(vim.fn.getcharstr)
    if ok and ch ~= esc then return ch
    else return nil end
end

-- patterns and functions for testing if a character should be considered a target
local matches = {
    upper = [=[\v[[:upper:]]\C]=],
    lower = [=[\v[[:lower:]]\C]=],
    digit = [=[\v[[:digit:]]\C]=],
    word  = [=[\v[[:upper:][:lower:][:digit:]]\C]=],
}
local function test(char, match)
    if char == nil then return false -- vim.fn.match returns false for nil char, but not if pattern contains `[:lower:]`
    else return vim.fn.match(char, match) == 0 end
end

local function test_split_identifiers(chars, cur_i)
    local cur_char = chars[cur_i]

    local is_match = false

    if test(cur_char, matches.upper) then
        local prev_char = chars[cur_i - 1]
        if not test(prev_char, matches.upper) then is_match = true
        else
            local next_char = chars[cur_i + 1]
            is_match = test(next_char, matches.word) and not test(next_char, matches.upper)
        end
    elseif test(cur_char, matches.digit) then
        is_match = not test(chars[cur_i - 1], matches.digit)
    elseif test(cur_char, matches.lower) then
        is_match = not test(chars[cur_i - 1], matches.word) or test(chars[cur_i - 1], matches.digit)
    else
        local prev_char = chars[cur_i - 1]
        is_match = prev_char ~= cur_char -- matching only first character in ==, [[ and ]]
    end

    return is_match
end

local function get_targets(winid, test_func)
    local wininfo = vim.fn.getwininfo(winid)[1]
    local bufId = vim.api.nvim_win_get_buf(winid)
    local lnum = wininfo.topline
    local botline = wininfo.botline

    local targets = {}

    while lnum <= botline do
        local fold_end = vim.fn.foldclosedend(lnum) -- winId?
        if fold_end ~= -1 then
            lnum = fold_end + 1
        else
            local line = vim.api.nvim_buf_get_lines(bufId, lnum-1, lnum, true)[1]
            local chars = vim.fn.split(line, '\\zs\\ze')

            local col = 1
            for i, cur in ipairs(chars) do -- search beyond last column
                if test_func(chars, i) then
                    table.insert(targets, { char = cur, pos = { lnum, col } })
                end
                col = col + string.len(cur)
            end
            assert(string.len(line) == col - 1)

            lnum = lnum + 1
        end
    end
    return targets
end

local ns = vim.api.nvim_create_namespace('Easyword')

vim.api.nvim_set_hl(0, 'EasywordBackdrop', { link = 'Comment' })
vim.api.nvim_set_hl(0, 'EasywordUnique', { bg = 'white', fg = 'black', bold = true })
vim.api.nvim_set_hl(0, 'EasywordTypedChar', { sp='red', underline=true, bold = true })
vim.api.nvim_set_hl(0, 'EasywordRestChar', { bg = 'black', fg = 'grey', bold = true })
vim.api.nvim_set_hl(0, 'EasywordTypedLabel', { sp='red', underline=true, bold = true })
vim.api.nvim_set_hl(0, 'EasywordRestLabel', { bg = 'black', fg = 'white', bold = true })

local jumpLabels = {
    's', 'j', 'k', 'd', 'l', 'f', 'c', 'n', 'i', 'e', 'w', 'r', 'o', "'",
    'm', 'u', 'v', 'a', 'q', 'p', 'x', 'z', '/',
}

local function updList(table, update)
    for i, v in ipairs(update) do
        table[i] = v
    end
    return table
end

--genetate variable length labels that use at most 2 characters without aba, only aab
local function computeLabels(max)
    local list = updList({}, jumpLabels)

    local curI = 1
    while #list < max do
        local sl = list[curI]
        local sst = sl:sub(1, 1)
        local sen = sl:sub(#sl, #sl)
        if sst == sen then
            table.remove(list, curI)
            table.insert(list, sl..sst)
            for i = 1, #jumpLabels do
                if jumpLabels[i] ~= sst then
                    table.insert(list, sl..jumpLabels[i])
                end
            end
        else
            curI = curI + 1
        end
    end

    return list
end

local function sortLabels(winId, cursor_screen_row, targets)
    local function screen_rows_from_cur(t)
        local t_screen_row = vim.fn.screenpos(winId, t.pos[1], t.pos[2])["row"]
        return math.abs(cursor_screen_row - t_screen_row)
    end
    table.sort(targets, function(t1, t2)
        return screen_rows_from_cur(t1) < screen_rows_from_cur(t2)
    end)
end

local function jumpToWord()
    local winid = vim.api.nvim_get_current_win()
    local bufId = vim.api.nvim_win_get_buf(winid)
    local lastLine = vim.api.nvim_buf_line_count(bufId) - 1

    local wordStartTargets = get_targets(
        winid, function(chars, i)
            return test(chars[i], matches.word) and test_split_identifiers(chars, i)
        end
    )

    local wordStartTargetsByChar = {}
    for _, target in ipairs(wordStartTargets) do
        local inserted = false
        local match = '\\v[[='..target.char..'=]]\\c'
        for char, data in pairs(wordStartTargetsByChar) do
            if test(char, match) then
                inserted = true
                table.insert(data, target)
            end
        end
        if not inserted then wordStartTargetsByChar[target.char] = { target } end
    end

    local cursorPos = vim.fn.getpos('.')
    local cursorScreenRow = vim.fn.screenpos(winid, cursorPos[2], cursorPos[3])["row"]

    vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)

    vim.highlight.range(bufId, ns, 'EasywordBackdrop', { 0, 0 }, { lastLine, -1 }, { })
    for _, targets in pairs(wordStartTargetsByChar) do
        if #targets == 1 then
            local target = targets[1]
            vim.api.nvim_buf_set_extmark(0, ns, target.pos[1]-1, target.pos[2]-1, {
                virt_text = { { target.char, 'EasywordUnique' } },
                virt_text_pos = 'overlay',
                hl_mode = 'combine'
            })
        else
            sortLabels(winid, cursorScreenRow, targets)
            local labels = computeLabels(#targets)
            for i, target in ipairs(targets) do
                target.label = labels[i]
                vim.api.nvim_buf_set_extmark(0, ns, target.pos[1]-1, target.pos[2]-1, {
                    virt_text = {
                        { target.char, 'EasywordRestChar' },
                        { target.label, 'EasywordRestLabel' },
                    },
                    virt_text_pos = 'overlay',
                    hl_mode = 'combine'
                })
            end
        end
    end

    vim.cmd.redraw()
    local char = get_input()
    if char == nil then return end
    local inputMatch = '\\v[[='..char..'=]]\\c'

    local curTargets
    for char, targets in pairs(wordStartTargetsByChar) do
        if test(char, inputMatch) then
            curTargets = targets
            break
        end
    end
    if curTargets == nil then
        curTargets = get_targets(
            winid,
            function(chars, i)
                local t1 = test(chars[i], inputMatch)
                local t2 = test_split_identifiers(chars, i)
                return t1 and t2
            end
        )
        sortLabels(winid, cursorScreenRow, curTargets)
        local labels = computeLabels(#curTargets)
        for i, target in ipairs(curTargets) do
            target.label = labels[i]
        end
    end

    local i = 1
    while true do
        if #curTargets == 0 then
            vim.api.nvim_echo({{ 'no label', 'ErrorMsg' }}, true, {})
            break
        end
        if #curTargets == 1 then
            local label = curTargets[1]
            vim.fn.setpos('.', { 0, label.pos[1], label.pos[2], 0 })
            break
        end

        vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
        vim.highlight.range(bufId, ns, 'EasywordBackdrop', { 0, 0 }, { lastLine, -1 }, { })
        for _, target in pairs(curTargets) do
            local typedLabel = target.label:sub(1, i-1)
            local restLabel  = target.label:sub(i)
            vim.api.nvim_buf_set_extmark(0, ns, target.pos[1]-1, target.pos[2]-1, {
                virt_text = {
                    { target.char, 'EasywordTypedChar' },
                    { typedLabel, 'EasywordTypedLabel' },
                    { restLabel, 'EasywordRestLabel' },
                },
                virt_text_pos = 'overlay',
                hl_mode = 'combine'
            })
        end

        vim.cmd.redraw()
        char = get_input()
        if char == nil then break end

        local newTargets = {}

        for _, target in ipairs(curTargets) do
            if char == target.label:sub(i,i) then
                table.insert(newTargets, target)
            end
        end

        curTargets = newTargets
        i = i + 1
    end
end

local function jump()
    local ok, result = pcall(jumpToWord)
    if not ok then vim.api.nvim_echo({{'Error: '..vim.inspect(result), 'ErrorMsg'}}, true, {}) end
    vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
end

return { jump = jump }