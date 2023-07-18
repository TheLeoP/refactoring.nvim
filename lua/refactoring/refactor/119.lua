local Region = require("refactoring.region")
local utils = require("refactoring.utils")
local get_input = require("refactoring.get_input")
local Query = require("refactoring.query")
local Pipeline = require("refactoring.pipeline")
local selection_setup = require("refactoring.tasks.selection_setup")
local refactor_setup = require("refactoring.tasks.refactor_setup")
local post_refactor = require("refactoring.tasks.post_refactor")
local ensure_code_gen = require("refactoring.tasks.ensure_code_gen")
local indent = require("refactoring.indent")
local lsp_utils = require("refactoring.lsp_utils")

local M = {}

---@param refactor Refactor
---@param region RefactorRegion
---@return string
local function get_func_call_prefix(refactor, region)
    local indent_amount = indent.buf_indent_amount(
        region:get_start_point(),
        refactor,
        false,
        refactor.bufnr
    )
    return indent.indent(indent_amount, refactor.bufnr)
end

---@param extract_node_text string
---@param refactor Refactor
---@param var_name string
---@param region RefactorRegion
---@return string
local function get_new_var_text(extract_node_text, refactor, var_name, region)
    local statement =
        refactor.config:get_extract_var_statement(refactor.filetype)
    local base_text = refactor.code.constant({
        name = var_name,
        value = extract_node_text,
        statement = statement,
    })

    if
        refactor.ts:is_indent_scope(refactor.scope)
        and refactor.ts:allows_indenting_task()
    then
        local indent_whitespace = get_func_call_prefix(refactor, region)
        return table.concat({ indent_whitespace, base_text }, "")
    end

    return base_text
end

---@param var_name string
---@param refactor Refactor
---@return string
local function get_var_name(var_name, refactor)
    if refactor.ts.require_special_var_format then
        return refactor.code.special_var(
            var_name,
            { region_node_type = refactor.region_node:type() }
        )
    else
        return var_name
    end
end

---@param refactor Refactor
---@return boolean, Refactor|string
local function extract_var_setup(refactor)
    local extract_nodes = refactor.region_nodes

    if extract_nodes == nil then
        return false, "Region nodes is nil. Something went wrong"
    end

    local extract_nodes_text = table.concat(
        vim.tbl_map(
        ---@param node TSNode
        ---@return string
            function(node)
                return vim.treesitter.get_node_text(node, refactor.bufnr)
            end,
            extract_nodes
        ),
        ""
    )

    local i = 0
    local sexpr = table.concat(
        vim.tbl_map(
        ---@param node TSNode
        ---@return string
            function(node)
                local text = node:sexpr() .. "@capture" .. i
                i = i + 1
                return text
            end,
            extract_nodes
        ),
        " "
    )
    sexpr = "(" .. sexpr .. ")"

    --- @type TSNode[][]
    local occurrences = {}
    local query = vim.treesitter.query.parse(refactor.lang, sexpr)
    for _, match in query:iter_matches(refactor.scope, refactor.bufnr, 0, -1) do
        --- @type string[]
        local texts = {}
        --- @type TSNode[]
        local nodes = {}
        for _, node in ipairs(match) do
            table.insert(texts, vim.treesitter.get_node_text(node, refactor.bufnr))
            table.insert(nodes, node)
        end
        local match_text = table.concat(texts, "")
        if match_text == extract_nodes_text then
            table.insert(occurrences, nodes)
        end
    end


    table.sort(occurrences,
        function(a, b)
            local start_row_a, start_col_a, _, _ = a[1]:range()
            local start_row_b, start_col_b, _, _ = b[1]:range()
            return start_row_a <= start_row_b and start_col_a < start_col_b
        end)

    local var_name = get_input("119: What is the var name > ")
    if not var_name or var_name == "" then
        return false, "Error: Must provide new var name"
    end

    refactor.text_edits = {}
    for _, occurrence in pairs(occurrences) do
        local first = occurrence[1]
        local last = occurrence[#occurrence]
        local start_row, start_col, _, _ = first:range()
        local _, _, end_row, end_col = last:range()

        table.insert(
            refactor.text_edits,
            lsp_utils.replace_text(
                Region:from_values(refactor.bufnr,
                    start_row + 1,
                    start_col + 1,
                    end_row + 1,
                    end_col
                ),
                get_var_name(var_name, refactor)
            )
        )
    end

    --- @type TSNode[]
    local block_scopes = {}
    --- @type table<integer, true>
    local already_seen = {}
    for _, occurrence in pairs(occurrences) do
        local block_scope =
            refactor.ts.get_container(occurrence[1], refactor.ts.block_scope)
        -- TODO: Add test for block_scope being nil
        if block_scope == nil then
            return false, "block_scope is nil! Something went wrong"
        end
        if already_seen[block_scope:id()] == nil then
            already_seen[block_scope:id()] = true
            table.insert(block_scopes, block_scope)
        end
    end
    utils.sort_in_appearance_order(block_scopes)

    -- TODO: Add test for block_scope being nil
    if #block_scopes < 1 then
        return false, "block_scope is nil! Something went wrong"
    end

    local unfiltered_statements = refactor.ts:get_statements(block_scopes[1])

    -- TODO: Add test for unfiltered_statements being nil
    if #unfiltered_statements < 1 then
        return false, "unfiltered_statements is nil! Something went wrong"
    end

    local statements = vim.tbl_filter(
    ---@param node TSNode
    ---@return TSNode[]
        function(node)
            for _, scope in pairs(block_scopes) do
                if node:parent():id() == scope:id() then
                    return true
                end
            end
            return false
        end,
        unfiltered_statements
    )
    utils.sort_in_appearance_order(statements)

    -- TODO: Add test for statements being nil
    if #statements < 1 then
        return false, "statements is nil! Something went wrong"
    end

    ---@type TSNode|nil
    local contained = nil
    local top_occurrence = occurrences[1]
    for _, statement in pairs(statements) do
        if utils.node_contains(statement, top_occurrence[1]) then
            contained = statement
        end
    end

    if not contained then
        return false,
            "Extract var unable to determine its containing statement within the block scope, please post issue with exact highlight + code!  Thanks"
    end

    local region = utils.region_one_line_up_from_node(contained)
    table.insert(
        refactor.text_edits,
        lsp_utils.insert_text(
            region,
            get_new_var_text(extract_nodes_text, refactor, var_name, region)
        )
    )
    return true, refactor
end

---@param refactor Refactor
local function ensure_code_gen_119(refactor)
    local list = { "constant" }

    return ensure_code_gen(refactor, list)
end

---@param bufnr integer
---@param config Config
function M.extract_var(bufnr, config)
    Pipeline:from_task(refactor_setup(bufnr, config))
        :add_task(ensure_code_gen_119)
        :add_task(selection_setup)
        :add_task(extract_var_setup)
        :after(post_refactor.post_refactor)
        :run(nil, vim.notify)
end

return M
