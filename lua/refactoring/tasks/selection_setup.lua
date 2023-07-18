local Region = require("refactoring.region")

---@param region RefactorRegion
---@param region_node TSNode
---@param out table
---@return TSNode[]
local function collect_region_nodes(region, region_node, out)
    for child in region_node:iter_children() do
        local child_region = Region:from_node(child)
        if region:contains(child_region) then
            table.insert(out, child)
        elseif region:partially_contains(child_region) then
            collect_region_nodes(region, child, out)
        end
    end
    return out
end

---@param refactor Refactor
local function selection_setup(refactor)
    local mode = vim.api.nvim_get_mode().mode
    if mode == "v" or mode == "V" or mode == "vs" or mode == "Vs" then
        vim.cmd("norm! ")
    end

    local region = Region:from_current_selection({
        bufnr = refactor.bufnr,
        include_end_of_line = refactor.ts.include_end_of_line,
    })
    local region_node = region:to_ts_node(refactor.ts:get_root())

    --- @type TSNode[]
    local region_nodes = {}
    if region:contains(Region:from_node(region_node)) then
        --- TODO (TheLeoP): modify 123 and 106 to only use region_nodes (and delete region_node)
        --- or let them still use region_node (?)
        --- Also, use this on 106 to better get the sexpr of the selected text (?)
        table.insert(region_nodes, region_node)
    else
        collect_region_nodes(region, region_node, region_nodes)
    end

    local scope = refactor.ts:get_scope(region_node)

    refactor.region = region
    refactor.region_node = region_node
    refactor.region_nodes = region_nodes
    refactor.scope = scope

    if refactor.scope == nil then
        return false, "Scope is nil"
    end

    return true, refactor
end

return selection_setup
