local wezterm = require 'wezterm'
local act = wezterm.action
local mux = wezterm.mux
local config = wezterm.config_builder()

local function safe_plugin_require(url)
  local ok, plugin = pcall(wezterm.plugin.require, url)
  if ok then
    return plugin
  end
  wezterm.log_warn('Plugin load failed: ' .. url .. ' :: ' .. tostring(plugin))
  return nil
end

local workspace_switcher = safe_plugin_require 'https://github.com/MLFlexer/smart_workspace_switcher.wezterm'
local quick_domains = safe_plugin_require 'https://github.com/DavidRR-F/quick_domains.wezterm'

local distro = 'Ubuntu'
local home_label = os.getenv 'USER' or os.getenv 'USERNAME' or 'home'
local linux_home = '/home/' .. home_label
local wsl_domain_name = 'WSL:' .. distro
local wsl_domains = wezterm.default_wsl_domains()

-- Run an agent command directly in WSL. No multiplexer wrapping: WezTerm owns
-- the panes, and Claude Code's Agents View owns agent fan-out.
local function shell_quote(s)
  return "'" .. (s:gsub("'", "'\\''")) .. "'"
end

-- Build a login-shell argv that execs one agent command in place.
local function agent_cmd(_name_prefix, cmd_args)
  local quoted = {}
  for _, a in ipairs(cmd_args) do
    table.insert(quoted, shell_quote(a))
  end
  local sh = 'exec ' .. table.concat(quoted, ' ')
  return { 'bash', '-lc', sh }
end

-- Default interactive shell.
local function login_shell()
  return { 'bash', '-l' }
end

for _, dom in ipairs(wsl_domains) do
  if dom.name == wsl_domain_name then
    dom.default_prog = login_shell()
    dom.default_cwd = linux_home
  end
end

config.wsl_domains = wsl_domains
config.default_domain = wsl_domain_name

-- The mux-attach fallback. `gui-startup` below sets cwd correctly, but it only
-- fires when the GUI starts a NEW mux server. If wezterm-mux-server.exe is
-- already running (it persists across GUI restarts), the GUI ATTACHES to it, the
-- handler never runs, and new windows inherit the mux server's own process cwd —
-- the Windows profile directory, i.e. /mnt/c/Users/<you>. That is how 78 sessions in one week
-- launched on the Windows mount despite every per-domain setting being correct.
-- A top-level default_cwd is consulted on that path too, so set both.
config.default_cwd = linux_home

wezterm.on('gui-startup', function(cmd)
  local spawn = {
    domain = { DomainName = wsl_domain_name },
    cwd = linux_home,
  }

  if cmd and cmd.args and #cmd.args > 0 then
    spawn.args = cmd.args
  end

  mux.spawn_window(spawn)
end)

config.launch_menu = {
  {
    label = 'WSL Ubuntu',
    domain = { DomainName = wsl_domain_name },
  },
  {
    label = 'Pi',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi', { 'pi' }),
  },
  {
    label = 'Pi (resume session)',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi-resume', { 'pi', '--resume' }),
  },
  {
    label = 'Pi (continue last)',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi-continue', { 'pi', '--continue' }),
  },
  {
    label = 'Pi (plan preset)',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi-plan', { 'pi', '--preset', 'plan' }),
  },
  {
    label = 'Pi (implement preset)',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi-impl', { 'pi', '--preset', 'implement' }),
  },
  {
    label = 'Pi (quick preset)',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi-quick', { 'pi', '--preset', 'quick' }),
  },
  {
    label = 'Pi (review loop)',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('pi-review', { 'pi', '/review-max' }),
  },
  {
    label = 'Claude Code',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('claude', { 'claude' }),
  },
  {
    label = 'Codex',
    domain = { DomainName = wsl_domain_name },
    args = agent_cmd('codex', { 'codex', '--no-alt-screen' }),
  },
  {
    label = 'Monitoring (htop)',
    domain = { DomainName = wsl_domain_name },
    args = { 'bash', '-lc', 'exec htop' },
  },
  {
    label = 'SSH helpers',
    domain = { DomainName = wsl_domain_name },
    args = { 'bash', '-lc', 'command -v pishosts >/dev/null && pishosts; printf "\nRun: pissh <alias>[:/remote/path]\n\n"; exec bash -l' },
  },
  {
    label = 'PowerShell',
    domain = { DomainName = 'local' },
    args = { 'powershell.exe', '-NoLogo' },
  },
  {
    label = 'Command Prompt',
    domain = { DomainName = 'local' },
    args = { 'cmd.exe' },
  },
}

-- Fallback: if anything accidentally spawns in the local Windows domain,
-- run WSL anyway so new tabs/windows don't drop you into a Windows shell.
config.default_prog = {
  'wsl.exe', '-d', distro, '--cd', linux_home, '--exec', 'bash', '-l',
}

-- Claude Code 2.1.247+ mishandles Kitty alternate-key reports in WezTerm.
-- Remove this workaround after https://github.com/anthropics/claude-code/issues/90067 is fixed.
config.enable_kitty_keyboard = false

local builtin_schemes = wezterm.get_builtin_color_schemes()

local function copy_table(value)
  if type(value) ~= 'table' then
    return value
  end

  local out = {}
  for k, v in pairs(value) do
    out[k] = copy_table(v)
  end
  return out
end

local custom_schemes = {}
local PRIMARY_SCHEME = 'Neon HC'

if builtin_schemes['IC_Green_PPL'] then
  local scheme = copy_table(builtin_schemes['IC_Green_PPL'])
  scheme.background = '#030805'
  scheme.foreground = '#b7ffbf'
  scheme.cursor_bg = '#7dff8a'
  scheme.cursor_border = '#7dff8a'
  scheme.cursor_fg = '#030805'
  scheme.selection_bg = '#12331a'
  scheme.selection_fg = '#d9ffe0'
  if scheme.brights then
    scheme.brights[1] = '#6c8f75'
  end
  custom_schemes['Matrix Dark HC'] = scheme
end

if builtin_schemes['Blue Matrix'] then
  local scheme = copy_table(builtin_schemes['Blue Matrix'])
  scheme.background = '#02060b'
  scheme.foreground = '#d9f6ff'
  scheme.cursor_bg = '#8be9fd'
  scheme.cursor_border = '#8be9fd'
  scheme.cursor_fg = '#02060b'
  scheme.selection_bg = '#123247'
  scheme.selection_fg = '#eefbff'
  scheme.split = '#1f4f68'
  scheme.scrollbar_thumb = '#17435a'

  if scheme.ansi then
    scheme.ansi[1] = '#081018'
    scheme.ansi[2] = '#ff7aa2'
    scheme.ansi[3] = '#39d2c0'
    scheme.ansi[4] = '#ffd166'
    scheme.ansi[5] = '#48b8ff'
    scheme.ansi[6] = '#b48ef7'
    scheme.ansi[7] = '#7fe7ff'
    scheme.ansi[8] = '#d9f6ff'
  end

  if scheme.brights then
    scheme.brights[1] = '#84a7bb'
    scheme.brights[2] = '#ff9abc'
    scheme.brights[3] = '#77f2df'
    scheme.brights[4] = '#ffe08a'
    scheme.brights[5] = '#7dd3ff'
    scheme.brights[6] = '#ceb0ff'
    scheme.brights[7] = '#b5f2ff'
    scheme.brights[8] = '#f3fdff'
  end

  custom_schemes['Blue Matrix HC'] = scheme
end

if builtin_schemes['Neon'] then
  local scheme = copy_table(builtin_schemes['Neon'])
  scheme.background = '#07030b'
  scheme.foreground = '#f1eaff'
  scheme.cursor_bg = '#62f7ff'
  scheme.cursor_border = '#62f7ff'
  scheme.cursor_fg = '#07030b'
  scheme.selection_bg = '#24153a'
  scheme.selection_fg = '#fff3ff'
  scheme.split = '#2c425e'
  scheme.scrollbar_thumb = '#25364d'

  if scheme.ansi then
    scheme.ansi[1] = '#120c1b'
    scheme.ansi[2] = '#ff5ea8'
    scheme.ansi[3] = '#52f7c9'
    scheme.ansi[4] = '#ffd76a'
    scheme.ansi[5] = '#59b7ff'
    scheme.ansi[6] = '#d58cff'
    scheme.ansi[7] = '#62f7ff'
    scheme.ansi[8] = '#f1eaff'
  end

  if scheme.brights then
    scheme.brights[1] = '#8c7ea6'
    scheme.brights[2] = '#ff98cb'
    scheme.brights[3] = '#8affdd'
    scheme.brights[4] = '#ffe698'
    scheme.brights[5] = '#8fd0ff'
    scheme.brights[6] = '#ebb4ff'
    scheme.brights[7] = '#a8fbff'
    scheme.brights[8] = '#fff7ff'
  end

  custom_schemes[PRIMARY_SCHEME] = scheme
end

config.color_schemes = custom_schemes
config.color_scheme = PRIMARY_SCHEME

local theme_chrome = {
  tab_inactive_bg = '#10091a',
  tab_inactive_fg = '#cfc0eb',
  tab_active_bg = '#2a1647',
  tab_active_fg = '#fff7ff',
  tab_unseen_bg = '#112a26',
  tab_unseen_fg = '#62f7ff',
  tab_hover_bg = '#1b0f2d',
  status_fg = '#d4c8ef',
  status_sep = '#675287',
  status_domain = '#59b7ff',
  status_state = '#52f7c9',
  status_zoom = '#ff6ac1',
  status_workspace = '#ffd76a',
  status_agent_working = '#52f7c9',
  status_agent_waiting = '#ffd76a',
  status_agent_idle = '#59b7ff',
  status_agent_error = '#ff6a8b',
  status_agent_inactive = '#8c7ea6',
}

local function pane_cwd(pane)
  if not pane then
    return nil
  end

  local ok, cwd = pcall(function()
    return pane:get_current_working_dir()
  end)
  if ok and cwd then
    return cwd
  end

  return pane.current_working_dir
end

local function pane_mux_domain_name(pane)
  if not pane then
    return ''
  end

  local ok, name = pcall(function()
    return pane:get_domain_name()
  end)
  if ok and name and name ~= '' then
    return name
  end

  return pane.domain_name or ''
end

local function pane_cwd_path(pane)
  local cwd = pane_cwd(pane)
  if not cwd then
    return nil
  end

  local value = nil
  if type(cwd) == 'userdata' or type(cwd) == 'table' then
    local file_path = cwd.file_path
    if file_path and file_path ~= '' then
      value = tostring(file_path)
    elseif cwd.path and cwd.path ~= '' then
      value = tostring(cwd.path)
    end
  end

  if not value or value == '' then
    value = tostring(cwd)
  end

  value = value:gsub('\\', '/')
  value = value:gsub('^file://[^/]*', '')
  value = value:gsub('%%20', ' ')
  value = value:gsub('/+$', '')
  if value == '' then
    return nil
  end

  local domain_name = pane_mux_domain_name(pane)
  if domain_name:find('^WSL:') then
    local unc_path = value:match('^//wsl%.localhost/[^/]+(/.*)$') or value:match('^//wsl%$/[^/]+(/.*)$')
    if unc_path and unc_path ~= '' then
      return unc_path
    end

    local drive, rest = value:match('^/([A-Za-z]):(/.*)$')
    if not drive then
      drive, rest = value:match('^([A-Za-z]):(/.*)$')
    end
    if drive and rest then
      return '/mnt/' .. drive:lower() .. rest
    end

    if value:find('^/home/') or value:find('^/mnt/') then
      return value
    end

    return nil
  end

  if value:match('^/[A-Za-z]:/') or value:match('^[A-Za-z]:/') then
    return nil
  end

  return value
end

local function split_current_pane(direction)
  return wezterm.action_callback(function(window, pane)
    local command = {
      domain = 'CurrentPaneDomain',
    }
    local cwd = pane_cwd_path(pane)
    if cwd then
      command.cwd = cwd
    end

    window:perform_action(act.SplitPane {
      direction = direction,
      size = { Percent = 50 },
      command = command,
    }, pane)
  end)
end

local function spawn_tab_current_pane_domain()
  return wezterm.action_callback(function(window, pane)
    local spawn = {
      domain = { DomainName = pane.domain_name or wsl_domain_name },
    }
    local cwd = pane_cwd_path(pane)
    if cwd then
      spawn.cwd = cwd
    end

    window:perform_action(act.SpawnCommandInNewTab(spawn), pane)
  end)
end

local function pane_nav(direction)
  return act.ActivatePaneDirection(direction)
end

local function pane_resize(direction, amount)
  return act.AdjustPaneSize { direction, amount }
end

local function pane_select_swap_mode()
  return act.PaneSelect {
    mode = 'SwapWithActiveKeepFocus',
  }
end

local function pane_select_activate_mode()
  return act.PaneSelect {
    mode = 'Activate',
  }
end

local function paste_clipboard_image_or_text()
  return wezterm.action_callback(function(window, pane)
    local helper = (os.getenv 'USERPROFILE' or 'C:\\Users\\user') .. '\\bin\\wezterm-clip2path.ps1'
    local path_style = (pane and pane.domain_name == 'local') and 'windows' or 'wsl'
    local success, stdout, stderr = wezterm.run_child_process {
      'powershell.exe',
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      helper,
      '-PathStyle',
      path_style,
    }

    if success and stdout then
      local text = stdout:gsub('[\r\n]+$', '')
      if text ~= '' then
        pane:send_text(text)
        return
      end
    end

    if stderr and stderr ~= '' then
      wezterm.log_warn('wezterm-clip2path failed: ' .. stderr)
    end

    window:perform_action(act.PasteFrom 'Clipboard', pane)
  end)
end

config.front_end = 'OpenGL'
config.max_fps = 60
config.animation_fps = 1
config.font = wezterm.font('JetBrainsMono NFM')
config.font_size = 11.2
config.line_height = 0.98
config.cell_width = 0.98
config.window_padding = { left = 8, right = 8, top = 6, bottom = 4 }
-- 64GB profile: tuned per the wezterm agent-swarm skill for sustained heavy
-- pi/claude/codex output across many panes. Memory footprint estimate: 3-8 GB.
config.scrollback_lines = 200000
config.mux_output_parser_buffer_size = 2 * 1024 * 1024
config.mux_output_parser_coalesce_delay_ms = 2
config.ratelimit_mux_line_prefetches_per_second = 500
config.shape_cache_size = 8192
config.line_state_cache_size = 8192
config.line_quad_cache_size = 8192
config.line_to_ele_shape_cache_size = 8192
config.glyph_cache_image_cache_size = 1024
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true
config.enable_scroll_bar = false
config.tab_max_width = 32
config.show_new_tab_button_in_tab_bar = false
config.switch_to_last_active_tab_when_closing_tab = true
config.hide_mouse_cursor_when_typing = true
config.status_update_interval = 3000
-- F24 via Caps Lock remap proved flaky on Windows/WezTerm on this machine,
-- so use a reliable real chord for the leader control plane instead.
config.leader = { key = 'Space', mods = 'CTRL', timeout_milliseconds = 900 }

local workspace_switch_action = workspace_switcher and workspace_switcher.switch_workspace() or act.Nop
local workspace_switch_prev_action = workspace_switcher and workspace_switcher.switch_to_prev_workspace() or act.Nop
local domain_attach_action = act.Nop
local domain_vsplit_action = act.Nop
local domain_hsplit_action = act.Nop

config.keys = {
  -- Preserve Claude Code multiline input while Kitty keyboard mode is disabled.
  { key = 'Enter', mods = 'SHIFT', action = act.SendString '\x0a' },
  -- Preserve word deletion muscle memory without relying on modifier reporting.
  { key = 'phys:Backspace', mods = 'SHIFT', action = act.SendString '\x17' },
  { key = 'phys:Delete', mods = 'SHIFT', action = act.SendString '\x1bd' },
  { key = 'v', mods = 'CTRL', action = act.PasteFrom 'Clipboard' },
  { key = 'v', mods = 'CTRL|ALT', action = paste_clipboard_image_or_text() },

  -- Workspace + domain control plane
  { key = 's', mods = 'LEADER', action = workspace_switch_action },
  { key = 'S', mods = 'LEADER', action = workspace_switch_prev_action },
  { key = 'd', mods = 'LEADER', action = domain_attach_action },
  { key = 'v', mods = 'LEADER', action = domain_vsplit_action },
  { key = 'h', mods = 'LEADER', action = domain_hsplit_action },

  -- Pane strategy: WezTerm owns the panes; Claude Code's Agents View owns agent fan-out.
  { key = 'Enter', mods = 'LEADER', action = spawn_tab_current_pane_domain() },
  { key = '\\', mods = 'LEADER', action = split_current_pane 'Right' },
  { key = '-', mods = 'LEADER', action = split_current_pane 'Down' },
  -- Direct pane splits with friendlier Windows-style chords.
  { key = '\\', mods = 'ALT|SHIFT', action = split_current_pane 'Right' },
  { key = '-', mods = 'ALT|SHIFT', action = split_current_pane 'Down' },
  -- Keep the stock WezTerm split bindings too.
  { key = '"', mods = 'CTRL|SHIFT|ALT', action = split_current_pane 'Down' },
  { key = '%', mods = 'CTRL|SHIFT|ALT', action = split_current_pane 'Right' },
  { key = 'z', mods = 'LEADER', action = act.TogglePaneZoomState },
  { key = 'x', mods = 'LEADER', action = act.CloseCurrentPane { confirm = true } },
  { key = 'q', mods = 'LEADER', action = pane_select_activate_mode() },
  { key = 'w', mods = 'LEADER', action = pane_select_swap_mode() },
  { key = 'o', mods = 'LEADER', action = pane_nav 'Next' },
  { key = 'LeftArrow', mods = 'LEADER', action = pane_nav 'Left' },
  { key = 'RightArrow', mods = 'LEADER', action = pane_nav 'Right' },
  { key = 'UpArrow', mods = 'LEADER', action = pane_nav 'Up' },
  { key = 'DownArrow', mods = 'LEADER', action = pane_nav 'Down' },
  { key = 'LeftArrow', mods = 'LEADER|SHIFT', action = pane_resize('Left', 5) },
  { key = 'RightArrow', mods = 'LEADER|SHIFT', action = pane_resize('Right', 5) },
  { key = 'UpArrow', mods = 'LEADER|SHIFT', action = pane_resize('Up', 3) },
  { key = 'DownArrow', mods = 'LEADER|SHIFT', action = pane_resize('Down', 3) },

  {
    key = 't',
    mods = 'CTRL|SHIFT',
    action = act.SpawnCommandInNewTab {
      domain = { DomainName = wsl_domain_name },
      cwd = linux_home,
      args = login_shell(),
    },
  },
  {
    key = 'l',
    mods = 'CTRL|SHIFT',
    action = act.ShowLauncherArgs {
      title = 'Launch / Switch',
      flags = 'FUZZY|LAUNCH_MENU_ITEMS|DOMAINS|TABS|COMMANDS',
    },
  },
  { key = 'p', mods = 'CTRL|SHIFT', action = act.ActivateCommandPalette },
  { key = 'f', mods = 'CTRL|SHIFT', action = act.Search 'CurrentSelectionOrEmptyString' },
  { key = 'UpArrow', mods = 'SHIFT', action = act.ScrollToPrompt(-1) },
  { key = 'DownArrow', mods = 'SHIFT', action = act.ScrollToPrompt(1) },
  {
    key = 'u',
    mods = 'CTRL|SHIFT',
    action = act.QuickSelectArgs {
      patterns = {
        'https?://\\S+',
      },
      label = 'copy url',
    },
  },
  {
    key = 'u',
    mods = 'CTRL|ALT',
    action = act.SpawnCommandInNewTab {
      domain = { DomainName = wsl_domain_name },
      cwd = linux_home,
      args = login_shell(),
    },
  },
  -- Ctrl+Alt+V smart-pastes clipboard content; keep Ctrl+V as normal text paste.
  {
    key = 'p',
    mods = 'CTRL|ALT',
    action = act.SpawnCommandInNewTab {
      domain = { DomainName = 'local' },
      args = { 'powershell.exe', '-NoLogo' },
    },
  },
  {
    key = 'c',
    mods = 'CTRL|ALT',
    action = act.SpawnCommandInNewTab {
      domain = { DomainName = 'local' },
      args = { 'cmd.exe' },
    },
  },
}

if quick_domains then
  quick_domains.apply_to_config(config, {
    keys = {
      attach = { key = 'd', mods = 'LEADER', tbl = '' },
      vsplit = { key = 'v', mods = 'LEADER', tbl = '' },
      hsplit = { key = 'h', mods = 'LEADER', tbl = '' },
    },
    auto = {
      ssh_ignore = false,
      exec_ignore = {
        ssh = true,
        docker = true,
        kubernetes = true,
      },
    },
  })
end

-- Windows Terminal-style right click: copy selection if there is one, otherwise paste.
-- In apps that capture mouse reporting (like Pi), hold Shift while right-clicking
-- if you need WezTerm to handle the click instead of passing it through.
config.mouse_bindings = {
  {
    event = { Down = { streak = 1, button = 'Right' } },
    mods = 'NONE',
    action = wezterm.action_callback(function(window, pane)
      local has_selection = window:get_selection_text_for_pane(pane) ~= ''
      if has_selection then
        window:perform_action(act.CopyTo('ClipboardAndPrimarySelection'), pane)
        window:perform_action(act.ClearSelection, pane)
      else
        window:perform_action(act.PasteFrom('Clipboard'), pane)
      end
    end),
  },
  {
    event = { Down = { streak = 3, button = 'Left' } },
    mods = 'NONE',
    action = act.SelectTextAtMouseCursor 'SemanticZone',
  },
}

local function basename(path)
  if not path or path == '' then
    return ''
  end
  return (string.gsub(path, '(.*[/\\])(.*)', '%2'))
end

local function workspace_label(name)
  if not name or name == '' or name == 'default' or name == '~' then
    return ''
  end

  local normalized = name:gsub('\\', '/')
  normalized = normalized:gsub('/+$', '')
  local base = basename(normalized)
  if base == '' then
    return name
  end
  return base
end

local function run_wsl_bash(command)
  local ok, stdout, stderr = wezterm.run_child_process({ 'wsl.exe', '-d', distro, 'bash', '-lc', command })
  if not ok then
    wezterm.log_error('WSL command failed: ' .. command .. ' :: ' .. tostring(stderr))
    return ''
  end
  return stdout or ''
end

if workspace_switcher then
  workspace_switcher.get_choices = function(opts)
    opts = opts or { extra_args = '' }
    local choices = {}
    choices, opts.workspace_ids = workspace_switcher.choices.get_workspace_elements(choices)

    local query_cmd = 'zoxide query -l'
    if opts.extra_args and opts.extra_args ~= '' then
      query_cmd = query_cmd .. ' ' .. opts.extra_args
    end

    local stdout = run_wsl_bash(query_cmd)
    for _, path in ipairs(wezterm.split_by_newlines(stdout)) do
      local label = path:gsub('^/home/' .. home_label, '~')
      if not opts.workspace_ids[label] then
        table.insert(choices, {
          id = path,
          label = label,
        })
      end
    end

    return choices
  end
end

local agent_profiles = {
  { id = 'pi', label = 'Pi', args = agent_cmd('pi', { 'pi' }) },
  { id = 'pi-resume', label = 'Pi · resume…', args = agent_cmd('pi-resume', { 'pi', '--resume' }) },
  { id = 'pi-continue', label = 'Pi · continue', args = agent_cmd('pi-continue', { 'pi', '--continue' }) },
  { id = 'pi-plan', label = 'Pi · plan', args = agent_cmd('pi-plan', { 'pi', '--preset', 'plan' }) },
  { id = 'pi-implement', label = 'Pi · implement', args = agent_cmd('pi-impl', { 'pi', '--preset', 'implement' }) },
  { id = 'pi-quick', label = 'Pi · quick', args = agent_cmd('pi-quick', { 'pi', '--preset', 'quick' }) },
  { id = 'pi-review', label = 'Pi · review', args = agent_cmd('pi-review', { 'pi', '/review-max' }) },
  { id = 'claude', label = 'Claude Code', args = agent_cmd('claude', { 'claude' }) },
  { id = 'codex', label = 'Codex', args = agent_cmd('codex', { 'codex', '--no-alt-screen' }) },
}

local function shorten_home(path)
  if not path or path == '' then
    return ''
  end
  return path:gsub('^' .. linux_home, '~')
end

local function cwd_uri_to_path(cwd)
  if not cwd then
    return nil
  end

  local value = tostring(cwd)
  value = value:gsub('^file://[^/]*', '')
  value = value:gsub('%%20', ' ')
  value = value:gsub('/+$', '')
  if value == '' then
    return nil
  end
  return value
end

local function current_project_path(pane)
  local cwd = cwd_uri_to_path(pane_cwd(pane))
  if cwd and cwd:find('^/home/') then
    return cwd
  end
  return linux_home
end

local function notify_window(window, title, message)
  if not window then
    return
  end
  pcall(function()
    window:toast_notification(title, message, nil, 3000)
  end)
end

local function find_agent_profile(id)
  for _, profile in ipairs(agent_profiles) do
    if profile.id == id then
      return profile
    end
  end
  return nil
end

local function preferred_agent_domain(pane)
  local domain_name = pane and pane.domain_name or nil
  if not domain_name or domain_name == '' or domain_name == 'local' then
    return wsl_domain_name
  end
  return domain_name
end

local function spawn_agent_tab(window, pane, project_path, profile)
  if not window or not profile then
    return
  end

  local cwd = project_path or current_project_path(pane)
  if not cwd or cwd == '' then
    cwd = linux_home
  end

  window:perform_action(act.SpawnCommandInNewTab {
    domain = { DomainName = preferred_agent_domain(pane) },
    cwd = cwd,
    args = profile.args,
  }, pane)
end

local function project_choices()
  local stdout = run_wsl_bash([[root="$HOME/SITES"
if [ ! -d "$root" ]; then
  exit 0
fi
{
  if command -v zoxide >/dev/null 2>&1; then
    zoxide query -l 2>/dev/null | while IFS= read -r path; do
      case "$path" in
        "$root"/*)
          rel="${path#"$root"/}"
          top="${rel%%/*}"
          if [ -n "$top" ]; then
            printf '%s/%s\n' "$root" "$top"
          fi
          ;;
      esac
    done
  fi
  find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
} | awk '!seen[$0]++'
]])

  local choices = {}
  for _, path in ipairs(wezterm.split_by_newlines(stdout)) do
    if path ~= '' then
      local label = string.format('%s  ·  %s', basename(path), shorten_home(path))
      table.insert(choices, { id = path, label = label })
    end
  end
  return choices
end

local function show_agent_selector(project_path)
  local title = 'Agent → ' .. shorten_home(project_path)
  local choices = {}
  for _, profile in ipairs(agent_profiles) do
    table.insert(choices, { id = profile.id, label = profile.label })
  end

  return act.InputSelector {
    title = title,
    choices = choices,
    fuzzy = true,
    action = wezterm.action_callback(function(window, pane, id, _label)
      if not id then
        return
      end
      local profile = find_agent_profile(id)
      if not profile then
        return
      end
      spawn_agent_tab(window, pane, project_path, profile)
    end),
  }
end

local function agent_here_picker()
  return wezterm.action_callback(function(window, pane)
    local project_path = current_project_path(pane)
    window:perform_action(show_agent_selector(project_path), pane)
  end)
end

local function project_agent_picker()
  return wezterm.action_callback(function(window, pane)
    local choices = project_choices()
    if #choices == 0 then
      notify_window(window, 'WezTerm', 'No ~/SITES projects found')
      return
    end

    window:perform_action(act.InputSelector {
      title = 'Project → Agent',
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(inner_window, inner_pane, id, _label)
        if not id then
          return
        end
        local target_pane = inner_pane or pane
        inner_window:perform_action(show_agent_selector(id), target_pane)
      end),
    }, pane)
  end)
end

table.insert(config.keys, { key = 'a', mods = 'LEADER', action = agent_here_picker() })
table.insert(config.keys, { key = 'p', mods = 'LEADER', action = project_agent_picker() })
-- Direct fallbacks for when you want agent launchers without thinking about leader.
table.insert(config.keys, { key = 'a', mods = 'CTRL|SHIFT', action = agent_here_picker() })
table.insert(config.keys, { key = 'a', mods = 'CTRL|ALT', action = project_agent_picker() })

-- Pi session recovery shortcuts.
-- <leader>r = spawn `pi --resume` in current project (pick a saved session).
-- <leader>c = spawn `pi --continue` in current project (last session).
local function spawn_in_current_project(name_prefix, cmd_args)
  return wezterm.action_callback(function(window, pane)
    window:perform_action(act.SpawnCommandInNewTab {
      domain = { DomainName = preferred_agent_domain(pane) },
      cwd = current_project_path(pane),
      args = agent_cmd(name_prefix, cmd_args),
    }, pane)
  end)
end

table.insert(config.keys, {
  key = 'r', mods = 'LEADER',
  action = spawn_in_current_project('pi-resume', { 'pi', '--resume' }),
})
table.insert(config.keys, {
  key = 'c', mods = 'LEADER',
  action = spawn_in_current_project('pi-continue', { 'pi', '--continue' }),
})
local function pane_cwd_name(pane)
  if not pane or not pane.current_working_dir then
    return ''
  end

  local cwd = tostring(pane.current_working_dir)
  cwd = cwd:gsub('^file://[^/]*', '')
  cwd = cwd:gsub('/+$', '')
  return basename(cwd)
end

local function pane_process_name(pane)
  if not pane then
    return ''
  end
  return basename(pane.foreground_process_name or '')
end

local function pane_domain_name(pane)
  if not pane then
    return ''
  end

  local ok, name = pcall(function()
    return pane:get_domain_name()
  end)

  if not ok or not name or name == '' then
    return ''
  end

  if name == 'local' then
    return 'WIN'
  end

  return name
end

local noisy_processes = {
  ['bash'] = true,
  ['zsh'] = true,
  ['pi'] = true,
  ['node'] = true,
  ['wslhost.exe'] = true,
}

local process_icons = {
  ['bash'] = '',
  ['zsh'] = '',
  ['fish'] = '󰈺',
  ['pwsh.exe'] = '',
  ['powershell.exe'] = '',
  ['cmd.exe'] = '',
  ['git'] = '',
  ['lazygit'] = '',
  ['nvim'] = '',
  ['vim'] = '',
  ['node'] = '󰎙',
  ['python'] = '',
  ['docker'] = '',
  ['kubectl'] = '󱃾',
  ['gh'] = '',
  ['ssh'] = '',
  ['lua'] = '',
}

local subscript_digits = {
  [2] = '₂',
  [3] = '₃',
  [4] = '₄',
  [5] = '₅',
  [6] = '₆',
  [7] = '₇',
  [8] = '₈',
  [9] = '₉',
}

local agent_status_icons = {
  working = '●',
  waiting = '◔',
  idle = '○',
  error = '✕',
}

local agent_detection_patterns = {
  pi = { 'π', ' pi ', 'pi%-', 'pi ', '/pi$', 'pi%.js', 'pi%-coding%-agent' },
  claude = { 'claude', 'claude%-code', '@anthropic%-ai/claude%-code' },
  codex = { 'codex' },
  aider = { 'aider' },
  gemini = { 'gemini' },
  opencode = { 'opencode' },
}

local agent_state_by_pane = {}

local function matches_any_pattern(text, patterns)
  if not text or text == '' or not patterns then
    return false
  end

  local haystack = text:lower()
  for _, pattern in ipairs(patterns) do
    local ok, found = pcall(function()
      return haystack:find(pattern:lower())
    end)
    if ok and found then
      return true
    end
    if not ok and haystack:find(pattern:lower(), 1, true) then
      return true
    end
  end

  return false
end

local function pane_id_of(pane)
  if not pane then
    return nil
  end
  if pane.pane_id then
    return pane.pane_id
  end
  local ok, value = pcall(function()
    return pane:pane_id()
  end)
  return ok and value or nil
end

-- Forward declaration: clean_pane_title is defined further below but called by
-- mux_pane_title's closure. Without this, the reference resolved to a nil global
-- and silently broke the right-status agent-state tracker.
local clean_pane_title

local function mux_pane_title(pane)
  if not pane then
    return ''
  end

  local ok, value = pcall(function()
    return pane:get_title()
  end)
  if ok and value and value ~= '' then
    return clean_pane_title(value)
  end

  return clean_pane_title(pane.title)
end

local function mux_process_name(pane)
  if not pane then
    return ''
  end

  local ok, value = pcall(function()
    return pane:get_foreground_process_name()
  end)
  if ok and value and value ~= '' then
    return basename(value)
  end

  return basename(pane.foreground_process_name or '')
end

local function mux_pane_progress(pane)
  if not pane then
    return nil
  end

  local ok, value = pcall(function()
    return pane:get_progress()
  end)
  if ok then
    return value
  end

  return nil
end

clean_pane_title = function(title)
  if not title or title == '' then
    return ''
  end

  title = title:gsub('^%s+', ''):gsub('%s+$', '')

  if title:find('wslhost%.exe', 1, false) then
    return 'wsl'
  end

  return title
end

local function split_title_parts(title, sep)
  local parts = {}
  local pattern = '(.-)' .. sep
  for part in (title .. sep):gmatch(pattern) do
    local trimmed = part:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed ~= '' then
      table.insert(parts, trimmed)
    end
  end
  return parts
end

local function compact_repo_name(name, max_len)
  max_len = max_len or 14
  if not name or name == '' then
    return ''
  end
  if #name <= max_len then
    return name
  end

  local pieces = {}
  for piece in name:gmatch('[^-]+') do
    table.insert(pieces, piece)
  end

  if #pieces <= 1 then
    return name:sub(1, max_len)
  end

  local out = {}
  for i, piece in ipairs(pieces) do
    if i == 1 then
      table.insert(out, piece)
    else
      table.insert(out, piece:sub(1, 1))
    end
  end

  local compact = table.concat(out, '-')
  if #compact <= max_len then
    return compact
  end

  return name:sub(1, max_len)
end

local function compact_lane_name(name)
  local aliases = {
    review = 'rev',
    verify = 'vfy',
    brainstorm = 'brain',
    compound = 'cmp',
    changelog = 'chg',
    browser = 'web',
    resolve = 'fix',
    commit = 'git',
    debug = 'dbg',
  }
  return aliases[name] or name
end

local function process_icon(proc)
  if not proc or proc == '' then
    return ''
  end
  return process_icons[string.lower(proc)] or ''
end

local function pane_count_badge(count)
  if not count or count < 2 then
    return ''
  end
  return subscript_digits[count] or 'ₓ'
end

local function tab_layout_badge(tab)
  local pane = tab and tab.active_pane or nil
  local fallback_zoom = pane and pane.is_zoomed and '' or ''

  local ok, mux_tab = pcall(function()
    return wezterm.mux.get_tab(tab.tab_id)
  end)
  if not ok or not mux_tab then
    return fallback_zoom
  end

  local panes_ok, panes = pcall(function()
    return mux_tab:panes_with_info()
  end)
  if not panes_ok or not panes then
    return fallback_zoom
  end

  local count = #panes
  local zoomed = false
  for _, pane_info in ipairs(panes) do
    if pane_info.is_zoomed then
      zoomed = true
      break
    end
  end

  local badge = ''
  if zoomed then
    badge = ''
  end
  badge = badge .. pane_count_badge(count)
  return badge
end

local function parse_pi_title(title)
  title = clean_pane_title(title)
  if title == '' then
    return nil
  end

  local parsed = {
    icon = '',
    repo = '',
    lane = '',
    model = '',
    state = '',
    raw = title,
  }

  local modern_icon, modern_rest = title:match('^(%S+)%s+π%s+(.+)$')
  if modern_rest then
    parsed.icon = modern_icon
    local parts = split_title_parts(modern_rest, ' · ')
    parsed.repo = parts[1] or ''
    parsed.lane = parts[2] or ''
    parsed.model = parts[3] or ''
    parsed.state = parts[4] or ''
    return parsed
  end

  local legacy = split_title_parts(title, ' %- ')
  if #legacy >= 2 and (legacy[1] == 'π' or legacy[1] == 'pi') then
    parsed.repo = legacy[#legacy] or ''
    parsed.lane = #legacy > 2 and legacy[2] or ''
    return parsed
  end

  return nil
end

local function detect_agent_type(title, proc)
  if parse_pi_title(title) then
    return 'pi'
  end

  local proc_base = basename(proc or ''):lower()
  if proc_base == 'pi' then
    return 'pi'
  end

  local haystacks = {
    clean_pane_title(title):lower(),
    proc_base,
    (proc or ''):lower(),
  }

  for agent_type, patterns in pairs(agent_detection_patterns) do
    for _, haystack in ipairs(haystacks) do
      if matches_any_pattern(haystack, patterns) then
        return agent_type
      end
    end
  end

  return nil
end

local function progress_to_agent_status(progress)
  if progress == nil or progress == 'None' then
    return nil
  end
  if progress == 'Indeterminate' then
    return 'working'
  end
  if type(progress) == 'table' then
    if progress.Error ~= nil then
      return 'error'
    end
    if progress.Percentage ~= nil then
      return progress.Percentage >= 100 and 'idle' or 'working'
    end
  end
  return nil
end

local function infer_agent_status(title, proc, progress)
  local progress_status = progress_to_agent_status(progress)
  if progress_status then
    return progress_status
  end

  local agent_type = detect_agent_type(title, proc)
  if not agent_type then
    return nil
  end

  local parsed = parse_pi_title(title)
  if parsed and parsed.state ~= '' then
    return 'working'
  end

  return 'idle'
end

local function update_window_agent_states(window)
  local ok, mux_window = pcall(function()
    return window:mux_window()
  end)
  if not ok or not mux_window then
    return
  end

  local tabs_ok, tabs = pcall(function()
    return mux_window:tabs()
  end)
  if not tabs_ok or not tabs then
    return
  end

  local seen = {}
  for _, mux_tab in ipairs(tabs) do
    local panes_ok, panes = pcall(function()
      return mux_tab:panes_with_info()
    end)
    if panes_ok and panes then
      for _, pane_info in ipairs(panes) do
        local pane_id = pane_id_of(pane_info.pane)
        if pane_id then
          seen[pane_id] = true
          local title = mux_pane_title(pane_info.pane)
          local proc = mux_process_name(pane_info.pane)
          local status = infer_agent_status(title, proc, mux_pane_progress(pane_info.pane))
          local agent_type = detect_agent_type(title, proc)

          if status and agent_type then
            agent_state_by_pane[pane_id] = {
              agent_type = agent_type,
              status = status,
            }
          else
            agent_state_by_pane[pane_id] = nil
          end
        end
      end
    end
  end

  for pane_id, _ in pairs(agent_state_by_pane) do
    if not seen[pane_id] then
      agent_state_by_pane[pane_id] = nil
    end
  end
end

local function count_agent_statuses()
  local counts = { waiting = 0, working = 0, idle = 0, error = 0 }
  for _, state in pairs(agent_state_by_pane) do
    if counts[state.status] ~= nil then
      counts[state.status] = counts[state.status] + 1
    end
  end
  return counts
end

local function tab_agent_badge(tab)
  local best_status = nil
  local priority = { error = 4, waiting = 3, working = 2, idle = 1 }

  for _, pane_info in ipairs(tab.panes or {}) do
    local title = clean_pane_title(pane_info.title or '')
    local proc = pane_info.foreground_process_name or ''
    local status = infer_agent_status(title, proc, pane_info.progress)
    if status and (not best_status or priority[status] > priority[best_status]) then
      best_status = status
    end
  end

  if not best_status then
    return nil
  end

  local color_key = 'status_agent_' .. best_status
  return {
    text = agent_status_icons[best_status] or '○',
    color = theme_chrome[color_key] or theme_chrome.status_agent_inactive,
  }
end

local function build_compact_pi_tab_title(parsed, max_width)
  max_width = max_width or 32
  local repo = compact_repo_name(parsed.repo, max_width >= 28 and 16 or 12)
  local lane = compact_lane_name(parsed.lane)
  local state = parsed.state
  local model = parsed.model
  local icon = parsed.icon ~= '' and parsed.icon or '󰚩'

  local candidates = {
    icon .. ' ' .. repo,
    icon .. ' ' .. repo .. (lane ~= '' and ' · ' .. lane or ''),
    icon .. ' ' .. repo .. (lane ~= '' and ' · ' .. lane or '') .. (state ~= '' and ' · ' .. state or ''),
    icon .. ' ' .. repo .. (lane ~= '' and ' · ' .. lane or '') .. (model ~= '' and ' · ' .. model or '') .. (state ~= '' and ' · ' .. state or ''),
  }

  for i = #candidates, 1, -1 do
    if #candidates[i] <= max_width - 2 then
      return candidates[i]
    end
  end

  return icon .. ' ' .. repo
end

local function full_window_title(tab)
  local pane = tab.active_pane
  local pane_title = clean_pane_title(pane.title)
  local parsed = parse_pi_title(pane_title)
  if parsed then
    local parts = { parsed.repo }
    if parsed.lane ~= '' then table.insert(parts, parsed.lane) end
    if parsed.model ~= '' then table.insert(parts, parsed.model) end
    if parsed.state ~= '' then table.insert(parts, parsed.state) end
    return (parsed.icon ~= '' and (parsed.icon .. ' ') or '') .. 'π ' .. table.concat(parts, ' · ')
  end
  return pane_title
end

local function tab_title(tab, max_width)
  local pane = tab.active_pane
  local cwd = pane_cwd_name(pane)
  local proc = pane_process_name(pane)
  local pane_title = clean_pane_title(pane.title)
  local parsed = parse_pi_title(pane_title)
  local title = ''

  if parsed then
    title = build_compact_pi_tab_title(parsed, max_width)
  elseif pane_title ~= '' and pane_title ~= home_label then
    title = pane_title
  elseif cwd ~= '' and cwd ~= home_label then
    title = cwd
  elseif cwd ~= '' then
    title = cwd
  elseif proc ~= '' and not noisy_processes[proc] then
    title = proc
  else
    title = 'shell'
  end

  if not parsed then
    local icon = process_icon(proc)
    if icon ~= '' then
      title = icon .. ' ' .. title
    end
  end

  return title
end

wezterm.on('format-tab-title', function(tab, tabs, panes, cfg, hover, max_width)
  local chrome = theme_chrome
  local bg = chrome.tab_inactive_bg
  local fg = chrome.tab_inactive_fg

  if tab.is_active then
    bg = chrome.tab_active_bg
    fg = chrome.tab_active_fg
  elseif tab.active_pane and tab.active_pane.has_unseen_output then
    bg = chrome.tab_unseen_bg
    fg = chrome.tab_unseen_fg
  elseif hover then
    bg = chrome.tab_hover_bg
  end

  local layout_badge = tab_layout_badge(tab)
  local title = tab_title(tab, max_width)
  local label = layout_badge ~= '' and (layout_badge .. ' ' .. title) or title
  label = wezterm.truncate_right(label, math.max(8, max_width - 4))

  local agent_badge = tab_agent_badge(tab)
  local formatted = {
    { Background = { Color = bg } },
  }

  if agent_badge then
    table.insert(formatted, { Foreground = { Color = agent_badge.color } })
    table.insert(formatted, { Text = ' ' .. agent_badge.text .. ' ' })
    table.insert(formatted, { Foreground = { Color = fg } })
    table.insert(formatted, { Text = label .. ' ' })
  else
    table.insert(formatted, { Foreground = { Color = fg } })
    table.insert(formatted, { Text = ' ' .. label .. ' ' })
  end

  return formatted
end)

wezterm.on('update-right-status', function(window, pane)
  update_window_agent_states(window)

  local parts = {}
  local counts = count_agent_statuses()
  if counts.error > 0 then
    table.insert(parts, { text = agent_status_icons.error .. ' ' .. counts.error, color = 'status_agent_error' })
  end
  if counts.waiting > 0 then
    table.insert(parts, { text = agent_status_icons.waiting .. ' ' .. counts.waiting, color = 'status_agent_waiting' })
  end
  if counts.working > 0 then
    table.insert(parts, { text = agent_status_icons.working .. ' ' .. counts.working, color = 'status_agent_working' })
  end

  local domain = pane_domain_name(pane)
  if domain ~= '' then
    table.insert(parts, { text = domain, color = 'status_domain' })
  end

  local parsed = parse_pi_title(clean_pane_title(pane.title))
  if parsed and parsed.lane ~= '' then
    table.insert(parts, { text = parsed.lane, color = 'status_zoom' })
  end
  if parsed and parsed.model ~= '' then
    table.insert(parts, { text = parsed.model, color = 'status_workspace' })
  end
  if parsed and parsed.state ~= '' then
    table.insert(parts, { text = parsed.state, color = 'status_state' })
  end

  if pane and pane.is_zoomed then
    table.insert(parts, { text = 'zoom', color = 'status_zoom' })
  end

  local workspace = window:active_workspace()
  local workspace_name = workspace_label(workspace)
  if workspace_name ~= '' then
    table.insert(parts, { text = workspace_name, color = 'status_workspace' })
  end

  if #parts == 0 then
    window:set_right_status('')
    return
  end

  local chrome = theme_chrome
  local chunks = {}
  for i, part in ipairs(parts) do
    if i > 1 then
      table.insert(chunks, { Foreground = { Color = chrome.status_sep } })
      table.insert(chunks, { Text = ' 󰇙 ' })
    end
    table.insert(chunks, { Foreground = { Color = chrome[part.color] or chrome.status_fg } })
    table.insert(chunks, { Text = part.text })
  end

  window:set_right_status(wezterm.format(chunks))
end)

wezterm.on('format-window-title', function(tab, pane, tabs, panes, cfg)
  local zoomed = tab.active_pane.is_zoomed and '[Z] ' or ''
  local tab_index = #tabs > 1 and string.format('[%d/%d] ', tab.tab_index + 1, #tabs) or ''
  return zoomed .. tab_index .. full_window_title(tab)
end)

return config
