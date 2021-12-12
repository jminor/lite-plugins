-- mod-version:2 -- lite-xl 2.0
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local StatusView = require "core.statusview"
local TreeView = require "plugins.treeview"

local scan_rate = config.project_scan_rate or 5
local cached_status_for_item = {}


style.gitstatus_addition = {common.color "#587c0c"}
style.gitstatus_modification = {common.color "#0c7d9d"}
style.gitstatus_deletion = {common.color "#94151b"}
style.gitstatus_unusual = {common.color "#f4851b"}


local function replace_alpha(color, alpha)
  local r, g, b = table.unpack(color)
  return { r, g, b, alpha }
end


-- Override TreeView's draw_item, but first
-- stash the old one (using [] in case it is not there at all)
local old_draw_item = TreeView["draw_item"]
function TreeView:draw_item(item, active, hovered, x, y, w, h)
  old_draw_item(self, item, active, hovered, x, y, w, h)
  
  -- is there a status for this item?
  local status = cached_status_for_item[item.abs_filename]
  if status ~= nil then
    -- what color should it be?
    local color = style.gitstatus_unusual
    if status == "M" then
      color = style.gitstatus_modification
    elseif status == "A" or status == "C" then
      color = style.gitstatus_addition
    elseif status == "D" then
      color = style.gitstatus_deletion
    end
    
    -- draw a background rectangle, in case it overlaps with the label
    -- and then the status text, centered, over that.
    local bg_color = hovered and style.line_highlight or style.background2
    local font = style.font
    local text_width = font:get_width(status)
    local tw = math.max(text_width, h)
    x = w - tw
    renderer.draw_rect(x, y, tw, h, replace_alpha(bg_color, 200))
    common.draw_text(font, color, status, nil, x + (tw - text_width)/2, y, 0, h)
  end
end


local git = {
  branch = nil,
  inserts = 0,
  deletes = 0,
}


config.gitstatus = {
  recurse_submodules = true
}


local function exec(cmd)
  local proc = process.start(cmd)
  -- Don't use proc:wait() here - that will freeze the app.
  -- Instead, rely on the fact that this is only called within
  -- a coroutine, and yield for a fraction of a second, allowing
  -- other stuff to happen while we wait for the process to complete.
  while proc:running() do
    coroutine.yield(0.1)
  end
  return proc:read_stdout() or ""
end


core.add_thread(function()
  while true do
    if system.get_file_info(".git") then
      -- get branch name
      git.branch = exec({"git", "rev-parse", "--abbrev-ref", "HEAD"}):match("[^\n]*")

      local inserts = 0
      local deletes = 0

      -- get diff stats
      local diff = exec({"git", "diff", "--numstat"})
      if config.gitstatus.recurse_submodules and system.get_file_info(".gitmodules") then
        local diff2 = exec({"git", "submodule", "foreach", "git diff --numstat"})
        diff = diff .. diff2
      end

      local folder = core.project_dir
      for line in string.gmatch(diff, "[^\n]+") do
        local submodule = line:match("^Entering '(.+)'$")
        if submodule then
          folder = core.project_dir .. PATHSEP .. submodule
        else
          local ins, dels, path = line:match("(%d+)%s+(%d+)%s+(.+)")
          if path then
            inserts = inserts + (tonumber(ins) or 0)
            deletes = deletes + (tonumber(dels) or 0)
          end
        end
      end

      git.inserts = inserts
      git.deletes = deletes

      -- get per-file status
      local files = exec({"git", "status", "--porcelain"})
      if config.gitstatus.recurse_submodules and system.get_file_info(".gitmodules") then
        local files2 = exec({"git", "submodule", "foreach", "git status --porcelain"})
        files = files .. files2
      end
      
      -- forget the old state
      cached_status_for_item = {}
      
      folder = core.project_dir
      for line in string.gmatch(files, "[^\n]+") do
        local submodule = line:match("^Entering '(.+)'$")
        if submodule then
          folder = core.project_dir .. PATHSEP .. submodule
        else
          local status, path = line:match("%s*(%S+)%s+(.+)")
          if path then
            local abs_path = folder .. PATHSEP .. path
            -- Note the status of this file, and each parent folder,
            -- so you can see at a glance which folders
            -- have modified files in them.
            while abs_path do
              cached_status_for_item[abs_path] = status or cached_status_for_item[abs_path]
              abs_path = common.dirname(abs_path)
            end
          end
        end
      end

    else
      git.branch = nil
    end

    coroutine.yield(scan_rate)
  end
end)


local get_items = StatusView.get_items

function StatusView:get_items()
  if not git.branch then
    return get_items(self)
  end
  local left, right = get_items(self)

  local t = {
    style.dim, self.separator,
    (git.inserts ~= 0 or git.deletes ~= 0) and style.accent or style.text,
    git.branch,
    style.dim, "  ",
    git.inserts ~= 0 and style.accent or style.text, "+", git.inserts,
    style.dim, " / ",
    git.deletes ~= 0 and style.accent or style.text, "-", git.deletes,
  }
  for _, item in ipairs(t) do
    table.insert(right, item)
  end

  return left, right
end

