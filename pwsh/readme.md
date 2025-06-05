# 🚀 Auto-Installing PowerShell Profile

A comprehensive, cross-platform PowerShell profile that automatically installs and configures everything you need for a modern terminal experience.

## ✨ Features

### 🔧 Auto-Installation
- **Homebrew** (macOS) - Installs automatically if missing
- **All dependencies** - Installs on first run, no manual setup needed
- **Cross-platform** - Works on macOS, Windows, and Linux

### 📦 What Gets Installed

#### PowerShell Modules
- **Terminal-Icons** - Beautiful file/folder icons in your terminal
- **PSReadLine** - Enhanced command line editing with predictions
- **posh-git** - Git integration for your prompt

#### Command Line Tools (via Homebrew on macOS)
- **oh-my-posh** - Beautiful, customizable prompt themes
- **neofetch** - System info display on startup
- **git** - Version control
- **fzf** - Fuzzy finder for files and directories
- **ripgrep** - Fast grep alternative
- **jq** - JSON processor
- **tree** - Directory structure viewer
- **htop** - Interactive process viewer
- Plus more useful tools!

### 🎨 Terminal Enhancements
- **Oh-My-Posh** prompt with blue-owl theme (falls back to default if not found)
- **Syntax highlighting** and **auto-suggestions**
- **Git status** in your prompt
- **Icons** for files and folders
- **Smart tab completion**
- **History search** with arrow keys

## 📥 Installation

### Quick Install (macOS/Linux)
```bash
# 1. Install PowerShell if you haven't already
brew install --cask powershell

# 2. Create the profile directory
mkdir -p ~/.config/powershell

# 3. Download the profile to the correct location
curl -o ~/.config/powershell/Microsoft.PowerShell_profile.ps1 [URL_TO_PROFILE]

# 4. Start PowerShell - everything installs automatically!
pwsh
```

### Windows
```powershell
# 1. Install PowerShell 7+ from Microsoft Store or:
winget install Microsoft.PowerShell

# 2. Save the profile to:
# $HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1

# 3. Start PowerShell - everything installs automatically!
pwsh
```

## 🎯 Usage

### First Run
When you first start PowerShell with this profile:
1. It will detect your OS (macOS/Windows/Linux)
2. Install Homebrew if needed (macOS)
3. Install all PowerShell modules
4. Install all command-line tools
5. Configure git with nano as the default editor
6. Set up your prompt theme
7. Display system info with neofetch

### Daily Use

#### Git Shortcuts
```powershell
gs        # git status
ga .      # git add .
gc "msg"  # git commit -m "msg"
gp        # git push
gl        # git log (last 10 commits)
gd        # git diff
gb        # git branch
gco main  # git checkout main
gcb feat  # git checkout -b feat

# Advanced
git-undo     # Undo last commit (keep changes)
git-unstage  # Remove from staging
git-discard  # Discard changes (careful!)
git-aliases  # Show all git shortcuts
```

#### Navigation
```powershell
..        # Go up one directory
...       # Go up two directories
....      # Go up three directories
mkcd dir  # Create and enter directory
ll        # List files (alias for Get-ChildItem)
```

#### Fuzzy Finding (if fzf installed)
```powershell
ff        # Fuzzy find files
fd        # Fuzzy find and cd to directory
```

#### Utilities
```powershell
touch file.txt    # Create or update file timestamp
Show-Colors       # Display all console colors
```

### 🔄 Reset/Update Everything
```powershell
# Force reinstall all components
Reset-PowerShellEnvironment -Force
```

### 🐚 Make PowerShell Your Default Shell (macOS)
```powershell
# This will add pwsh to /etc/shells and set it as default
Set-PowerShellAsDefaultShell
```

## 🛠️ Customization

### Profile Location
- **macOS/Linux**: `~/.config/powershell/Microsoft.PowerShell_profile.ps1`
- **Windows**: `~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1`
- **Quick edit**: `code $PROFILE`

### Change Oh-My-Posh Theme
```powershell
# List all available themes
Get-PoshThemes

# Edit profile to change theme path
code $PROFILE
```

### Add Your Own Aliases
Add custom aliases in the "Custom Aliases and Functions" section of the profile.

## 🔍 Troubleshooting

### "Command not found" after installation
- Restart PowerShell for PATH changes to take effect
- On macOS, run `Update-Environment` to refresh paths

### Homebrew installation fails (macOS)
- Make sure you have Xcode command line tools: `xcode-select --install`
- Try manual installation from https://brew.sh

### Module installation fails
- Check internet connection
- Try manual installation: `Install-Module ModuleName -Scope CurrentUser -Force`

### Git asks for editor
- The profile sets nano automatically
- Manual set: `git config --global core.editor nano`

## 🌟 Features in Detail

### Platform Detection
- Automatically detects macOS, Windows, or Linux
- Installs appropriate package managers and tools
- Platform-specific functions only load where relevant

### PATH Management (macOS)
- Automatically syncs system paths from `/etc/paths` and `/etc/paths.d/`
- Ensures Homebrew and system binaries are accessible

### Smart Git Configuration
- Sets nano as the default editor
- Prompts for name/email if not configured
- Configures sensible defaults (main branch, colors, etc.)

### Windows-Specific
- Hyper-V VM management functions
- Windows package management via winget

## 📝 Requirements

- **PowerShell 7.0+** (Install from Microsoft)
- **Internet connection** (for first-time setup)
- **Admin rights** (for some installations)

## 🤝 Contributing

Feel free to customize this profile for your needs! Some ideas:
- Add more git aliases
- Include your favorite tools
- Customize the prompt theme
- Add project-specific functions

## 📄 License

This profile is provided as-is for personal use. Feel free to modify and share!

