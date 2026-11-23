-- Node.js configuration for Neovim
-- This ensures Neovim uses the SYSTEM Node.js, not project-specific versions
-- This prevents issues when working with old projects that use Node < 18

local M = {}

-- Run `<node> --version` without going through a shell (avoids fish/zsh noise)
local function node_version(node_path)
  local ok, out = pcall(function()
    return vim.fn.system({ node_path, "--version" })
  end)

  if not ok or vim.v.shell_error ~= 0 then
    return nil, out
  end

  local version = out
    :gsub("\r", "")
    :gsub("\n", "")
    :gsub("\27%[[%d;?]*%a", "") -- ANSI escape sequences
    :gsub("^v", "")
    :match("(%d+%.%d+%.%d+)")

  return version, out
end

-- Build an install hint that matches the current OS / package manager
local function install_hint()
  if vim.fn.has("mac") == 1 then
    return "  brew install node"
  end

  local managers = {
    { bin = "pacman", cmd = "  sudo pacman -S nodejs npm" },
    { bin = "apt", cmd = "  sudo apt install nodejs npm" },
    { bin = "dnf", cmd = "  sudo dnf install nodejs npm" },
    { bin = "zypper", cmd = "  sudo zypper install nodejs npm" },
    { bin = "apk", cmd = "  sudo apk add nodejs npm" },
    { bin = "xbps-install", cmd = "  sudo xbps-install nodejs npm" },
  }

  for _, m in ipairs(managers) do
    if vim.fn.executable(m.bin) == 1 then
      return m.cmd
    end
  end

  return "  Download it from https://nodejs.org (v22 LTS or newer)"
end

-- Expand glob patterns and pick the newest version (numeric-aware)
local function first_existing(patterns)
  for _, path in ipairs(patterns) do
    if path:match("%*") then
      local expanded = vim.fn.glob(path, false, true)
      if #expanded > 0 then
        table.sort(expanded, function(a, b)
          local av = { a:match("v(%d+)%.(%d+)%.(%d+)") }
          local bv = { b:match("v(%d+)%.(%d+)%.(%d+)") }
          if #av == 3 and #bv == 3 then
            for i = 1, 3 do
              local an, bn = tonumber(av[i]), tonumber(bv[i])
              if an ~= bn then
                return an > bn
              end
            end
          end
          return a > b
        end)
        for _, candidate in ipairs(expanded) do
          if vim.fn.executable(candidate) == 1 then
            return candidate
          end
        end
      end
    elseif vim.fn.executable(path) == 1 then
      return path
    end
  end

  return nil
end

-- Function to get system Node.js path (avoiding project-specific versions)
local function get_system_node()
  local data_home = vim.env.XDG_DATA_HOME or vim.fn.expand("~/.local/share")

  -- Priority order for system Node.js (avoiding project overrides)
  local system_paths = {
    "/opt/homebrew/bin/node", -- Homebrew on Apple Silicon
    "/usr/local/bin/node", -- Homebrew on Intel Mac or standard install
    vim.fn.expand("~/.volta/bin/node"), -- Volta's global Node
    data_home .. "/fnm/aliases/default/bin/node", -- fnm default alias
    data_home .. "/fnm/node-versions/*/installation/bin/node", -- fnm versions
    vim.fn.expand("~/.nvm/versions/node/*/bin/node"), -- NVM default version
    vim.fn.expand("~/.nix-profile/bin/node"), -- Nix
    "/usr/bin/node", -- System default
  }

  local found = first_existing(system_paths)
  if found then
    return found
  end

  -- Fallback to whatever is in PATH (but warn if it might be project-specific)
  return vim.fn.exepath("node")
end

-- Function to setup Node.js for Neovim
local function setup_nodejs()
  -- Get system Node.js, avoiding project-specific versions
  local node_path = get_system_node()

  if node_path ~= "" then
    local version, version_output = node_version(node_path)
    if version then
      local major_version = tonumber(version:match("^(%d+)"))

      if major_version and major_version >= 18 then
        -- Set the Node.js host program
        vim.g.node_host_prog = node_path

        -- Set npm path (prefer the npm that ships with the chosen node)
        local npm_path = node_path:gsub("node$", "npm")
        if vim.fn.executable(npm_path) ~= 1 then
          npm_path = vim.fn.exepath("npm")
        end
        if npm_path ~= "" then
          vim.g.npm_host_prog = npm_path
        end

        if vim.g.debug_nodejs or vim.env.DEBUG_NODEJS then
          print("✓ Node.js for Neovim: " .. node_path .. " (v" .. version .. ")")

          -- Detect which manager is being used
          if node_path:match("%.volta/") then
            print("  Using Volta-managed Node.js")
          elseif node_path:match("/fnm/") then
            print("  Using fnm-managed Node.js")
          elseif node_path:match("%.nvm/") then
            print("  Using NVM-managed Node.js")
          elseif node_path:match("%.nix%-profile/") then
            print("  Using Nix-managed Node.js")
          elseif node_path:match("/homebrew/") then
            print("  Using Homebrew-managed Node.js")
          else
            print("  Using system Node.js")
          end
        end

        return true, version
      else
        -- Provide specific upgrade instructions based on the detected manager
        local upgrade_msg = "⚠️  Node.js version "
          .. version
          .. " is too old. Neovim requires v18+ (v22+ recommended).\n\n"

        if node_path:match("/homebrew/") then
          upgrade_msg = upgrade_msg .. "To upgrade with Homebrew:\n  brew upgrade node"
        elseif node_path:match("%.volta/") then
          upgrade_msg = upgrade_msg .. "To upgrade with Volta:\n  volta install node@latest"
        elseif node_path:match("/fnm/") then
          upgrade_msg = upgrade_msg .. "To upgrade with fnm:\n  fnm install --lts\n  fnm default lts-latest"
        elseif node_path:match("%.nvm/") then
          upgrade_msg = upgrade_msg .. "To upgrade with NVM:\n  nvm install --lts\n  nvm alias default lts/*"
        elseif node_path:match("%.nix%-profile/") then
          upgrade_msg = upgrade_msg .. "To upgrade with Nix:\n  nix profile upgrade nixpkgs#nodejs"
        else
          upgrade_msg = upgrade_msg .. "Please upgrade Node.js to v18 or higher using your package manager."
        end

        upgrade_msg = upgrade_msg .. "\n\nNote: Neovim uses the SYSTEM Node.js, not project-specific versions."

        vim.notify(upgrade_msg, vim.log.levels.WARN)
        vim.g.node_host_prog = node_path
        return true, version
      end
    else
      -- Handle case where version parsing failed
      vim.notify(
        "⚠️  Could not parse Node.js version from: "
          .. tostring(version_output)
          .. "\nPlease ensure Node.js is properly installed.",
        vim.log.levels.ERROR
      )
      return false, nil
    end
  end

  vim.notify(
    "⚠️  Node.js not found! Some plugins may not work correctly.\nInstall Node.js with:\n"
      .. install_hint()
      .. "\n\nHint: run :NodeRefresh after installing.",
    vim.log.levels.ERROR
  )
  return false, nil
end

-- Function to check if we're using a recent Node.js version
local function check_node_version()
  if not vim.g.node_host_prog then
    return
  end

  local version = node_version(vim.g.node_host_prog)
  if not version then
    return
  end

  local major_version = tonumber(version:match("^(%d+)"))

  if major_version then
    if major_version >= 18 and major_version < 22 then
      if vim.g.debug_nodejs then
        vim.notify(
          "ℹ️  Node.js v" .. version .. " works but v22+ is recommended for optimal performance.",
          vim.log.levels.INFO
        )
      end
    elseif major_version < 18 then
      vim.notify(
        "⚠️  Node.js version " .. version .. " is too old. Neovim requires v18+ (v22+ recommended).",
        vim.log.levels.WARN
      )
    end
  end
end

-- Main setup function
function M.setup(opts)
  opts = opts or {}

  -- Setup Node.js
  local success, version = setup_nodejs()

  if success and not opts.silent then
    check_node_version()
  end

  return success
end

-- Function to get current Node.js info
function M.info()
  if not vim.g.node_host_prog then
    print("Node.js: Not configured")
    return
  end

  local version = node_version(vim.g.node_host_prog)
  if not version then
    print("Node.js: Error getting version")
    return
  end

  print("Node.js for Neovim: " .. vim.g.node_host_prog .. " (v" .. version .. ")")

  -- Detect source
  if vim.g.node_host_prog:match("%.volta/") then
    print("Source: Volta-managed")
  elseif vim.g.node_host_prog:match("/fnm/") then
    print("Source: fnm-managed")
  elseif vim.g.node_host_prog:match("%.nvm/") then
    print("Source: NVM-managed")
  elseif vim.g.node_host_prog:match("%.nix%-profile/") then
    print("Source: Nix-managed")
  elseif vim.g.node_host_prog:match("/homebrew/") then
    print("Source: Homebrew-managed")
  else
    print("Source: System")
  end

  if vim.g.npm_host_prog then
    print("npm: " .. vim.g.npm_host_prog)
  end

  if vim.g.debug_nodejs then
    print("\nPATH: " .. (vim.env.PATH or "not set"))
  end
end

-- Command to manually refresh Node.js configuration
vim.api.nvim_create_user_command("NodeRefresh", function()
  M.setup({ silent = false })
  M.info()
end, { desc = "Refresh Node.js configuration" })

-- Command to show Node.js info
vim.api.nvim_create_user_command("NodeInfo", function()
  M.info()
end, { desc = "Show Node.js configuration info" })

-- Command to debug Node.js PATH issues
vim.api.nvim_create_user_command("NodeDebug", function()
  vim.g.debug_nodejs = true
  print("=== Node.js Debug Mode Enabled ===")
  M.setup({ silent = false })
  M.info()
  print("=== End Debug Info ===")
  vim.g.debug_nodejs = false
end, { desc = "Debug Node.js configuration and PATH" })

return M
