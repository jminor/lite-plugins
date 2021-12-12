-- mod-version:2 -- lite-xl 2.0
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local StatusView = require "core.statusview"
local TreeView = require "plugins.treeview"

local scan_rate = config.project_scan_rate or 5
local cached_color_for_item = {}


-- Override TreeView's get_item_text, but first
-- stash the old one (using [] in case it is not there at all)
local old_get_item_text = TreeView["get_item_text"]
function TreeView:get_item_text(item, active, hovered)
  local text, font, color = old_get_item_text(self, item, active, hovered)
  color = cached_color_for_item[item.abs_filename] or color
  return text, font, color
end


local git = {
  branch = nil,
  inserts = 0,
  deletes = 0,
}


config.gitstatus = {
  recurse_submodules = true
}
style.gitstatus_addition = {common.color "#587c0c"}
style.gitstatus_modification = {common.color "#0c7d9d"}
style.gitstatus_deletion = {common.color "#94151b"}


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
      cached_color_for_item = {}
      
      folder = core.project_dir
      for line in string.gmatch(files, "[^\n]+") do
        local submodule = line:match("^Entering '(.+)'$")
        if submodule then
          folder = core.project_dir .. PATHSEP .. submodule
        else
          local status, path = line:match("%s*(%S+)%s+(.+)")
          if path then
            local abs_path = folder .. PATHSEP .. path
            -- Color this file, and each parent folder,
            -- so you can see at a glance which folders
            -- have modified files in them.
            local color = style.gitstatus_modification
            if status == "??" then color = style.gitstatus_addition end
            if status == "D" then color = style.gitstatus_deletion end
            while abs_path do
              cached_color_for_item[abs_path] = color
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

