-- tests/manual/test_file_info_centering.lua
-- Standalone test for file_info centering logic

local function calculate_pos(params)
    local win_pos = params.win_pos
    local win_width = params.win_width
    local win_height = params.win_height
    local float_width = params.float_width
    local float_height = params.float_height
    local screen_lines = params.screen_lines
    local screen_cols = params.screen_cols

    -- 1. Truncate width if larger than screen_cols - 2 (to fit border)
    if float_width > screen_cols - 2 then
        float_width = screen_cols - 2
    end

    -- 2. Initial centering calculation
    local row = math.floor(win_pos[1] + (win_height - float_height) / 2)
    local col = math.floor(win_pos[2] + (win_width - float_width) / 2)

    -- 3. Clipping logic
    -- To keep the border (1 cell) within boundaries (0 to screen_lines - 1):
    -- row - 1 >= 0 => row >= 1
    -- row + height + 1 <= screen_lines => row <= screen_lines - height - 1
    row = math.max(1, math.min(row, screen_lines - float_height - 1))
    col = math.max(1, math.min(col, screen_cols - float_width - 1))

    return { row = row, col = col, width = float_width, height = float_height }
end

local function assert_eq(actual, expected, name)
    if actual == expected then
        -- print(string.format("  [PASS] %s: %s", name, actual))
    else
        print(string.format("  [FAIL] %s: expected %s, got %s", name, expected, actual))
        return false
    end
    return true
end

local function run_test(test)
    print(string.format("Running test: %s", test.name))
    local result = calculate_pos(test.params)
    local success = true
    success = assert_eq(result.row, test.expected.row, "row") and success
    success = assert_eq(result.col, test.expected.col, "col") and success
    if test.expected.width then
        success = assert_eq(result.width, test.expected.width, "width") and success
    end
    if success then
        print("  [ALL PASSED]")
    end
    return success
end

local test_cases = {
    {
        name = "Centered in large screen",
        params = {
            win_pos = {0, 0}, win_width = 80, win_height = 24,
            float_width = 40, float_height = 10,
            screen_lines = 40, screen_cols = 100
        },
        expected = { row = 7, col = 20 } -- (24-10)/2 = 7, (80-40)/2 = 20
    },
    {
        name = "Near top-left edge (clipped to 1,1)",
        params = {
            win_pos = {0, 0}, win_width = 20, win_height = 10,
            float_width = 40, float_height = 20,
            screen_lines = 40, screen_cols = 100
        },
        expected = { row = 1, col = 1 }
    },
    {
        name = "Near bottom-right edge (clipped)",
        params = {
            win_pos = {20, 60}, win_width = 40, win_height = 20,
            float_width = 30, float_height = 10,
            screen_lines = 40, screen_cols = 100
        },
        -- Initial: row = 20 + (20-10)/2 = 25. col = 60 + (40-30)/2 = 65.
        -- Max: row = 40 - 10 - 1 = 29. col = 100 - 30 - 1 = 69.
        -- Both within max.
        expected = { row = 25, col = 65 }
    },
    {
        name = "Near bottom-right edge (clipped by screen)",
        params = {
            win_pos = {30, 70}, win_width = 40, win_height = 20,
            float_width = 30, float_height = 10,
            screen_lines = 40, screen_cols = 100
        },
        -- Initial: row = 30 + (20-10)/2 = 35. col = 70 + (40-30)/2 = 75.
        -- Max: row = 40 - 10 - 1 = 29. col = 100 - 30 - 1 = 69.
        expected = { row = 29, col = 69 }
    },
    {
        name = "Exceeding screen width (truncated)",
        params = {
            win_pos = {0, 0}, win_width = 100, win_height = 40,
            float_width = 120, float_height = 10,
            screen_lines = 40, screen_cols = 100
        },
        -- Truncate width to 100-2 = 98.
        -- Initial: row = 0 + (40-10)/2 = 15. col = 0 + (100-98)/2 = 1.
        -- Max: row = 40 - 10 - 1 = 29. col = 100 - 98 - 1 = 1.
        expected = { row = 15, col = 1, width = 98 }
    }
}

local all_success = true
for _, test in ipairs(test_cases) do
    if not run_test(test) then
        all_success = false
    end
end

if all_success then
    print("\nAll tests passed successfully!")
    os.exit(0)
else
    print("\nSome tests failed.")
    os.exit(1)
end
