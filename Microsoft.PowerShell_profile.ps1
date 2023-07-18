using namespace System.Management.Automation
using namespace System.Management.Automation.Language

#############################
# Encoding
#############################

[console]::InputEncoding = [console]::OutputEncoding = New-Object System.Text.UTF8Encoding

#############################
# PSReadLine
#############################

Import-Module PSReadLine

Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadlineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadlineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadlineKeyHandler -Key DownArrow -Function HistorySearchForward

Set-PSReadLineOption -Predictionsource History

# Smart Insertion

Set-PSReadLineKeyHandler -Key '"', "'" `
    -BriefDescription SmartInsertQuote `
    -LongDescription "Insert paired quotes if not already on a quote" `
    -ScriptBlock {
    param($key, $arg)

    $quote = $key.KeyChar

    $selectionStart = $null
    $selectionLength = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$selectionStart, [ref]$selectionLength)

    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    # If text is selected, just quote it without any smarts
    if ($selectionStart -ne -1) {
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($selectionStart, $selectionLength, $quote + $line.SubString($selectionStart, $selectionLength) + $quote)
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($selectionStart + $selectionLength + 2)
        return
    }

    $ast = $null
    $tokens = $null
    $parseErrors = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$ast, [ref]$tokens, [ref]$parseErrors, [ref]$null)

    function FindToken {
        param($tokens, $cursor)

        foreach ($token in $tokens) {
            if ($cursor -lt $token.Extent.StartOffset) { continue }
            if ($cursor -lt $token.Extent.EndOffset) {
                $result = $token
                $token = $token -as [StringExpandableToken]
                if ($token) {
                    $nested = FindToken $token.NestedTokens $cursor
                    if ($nested) { $result = $nested }
                }

                return $result
            }
        }
        return $null
    }

    $token = FindToken $tokens $cursor

    # If we're on or inside a **quoted** string token (so not generic), we need to be smarter
    if ($token -is [StringToken] -and $token.Kind -ne [TokenKind]::Generic) {
        # If we're at the start of the string, assume we're inserting a new string
        if ($token.Extent.StartOffset -eq $cursor) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$quote$quote ")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
            return
        }

        # If we're at the end of the string, move over the closing quote if present.
        if ($token.Extent.EndOffset -eq ($cursor + 1) -and $line[$cursor] -eq $quote) {
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
            return
        }
    }

    if ($null -eq $token -or
        $token.Kind -eq [TokenKind]::RParen -or $token.Kind -eq [TokenKind]::RCurly -or $token.Kind -eq [TokenKind]::RBracket) {
        if ($line[0..$cursor].Where{ $_ -eq $quote }.Count % 2 -eq 1) {
            # Odd number of quotes before the cursor, insert a single quote
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($quote)
        }
        else {
            # Insert matching quotes, move cursor to be in between the quotes
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$quote$quote")
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
        }
        return
    }

    # If cursor is at the start of a token, enclose it in quotes.
    if ($token.Extent.StartOffset -eq $cursor) {
        if ($token.Kind -eq [TokenKind]::Generic -or $token.Kind -eq [TokenKind]::Identifier -or 
            $token.Kind -eq [TokenKind]::Variable -or $token.TokenFlags.hasFlag([TokenFlags]::Keyword)) {
            $end = $token.Extent.EndOffset
            $len = $end - $cursor
            [Microsoft.PowerShell.PSConsoleReadLine]::Replace($cursor, $len, $quote + $line.SubString($cursor, $len) + $quote)
            [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($end + 2)
            return
        }
    }

    # We failed to be smart, so just insert a single quote
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert($quote)
}

Set-PSReadLineKeyHandler -Key '(', '{', '[' `
    -BriefDescription InsertPairedBraces `
    -LongDescription "Insert matching braces" `
    -ScriptBlock {
    param($key, $arg)

    $closeChar = switch ($key.KeyChar) {
        <#case#> '(' { [char]')'; break }
        <#case#> '{' { [char]'}'; break }
        <#case#> '[' { [char]']'; break }
    }

    $selectionStart = $null
    $selectionLength = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$selectionStart, [ref]$selectionLength)

    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    
    if ($selectionStart -ne -1) {
        # Text is selected, wrap it in brackets
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace($selectionStart, $selectionLength, $key.KeyChar + $line.SubString($selectionStart, $selectionLength) + $closeChar)
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($selectionStart + $selectionLength + 2)
    }
    else {
        # No text is selected, insert a pair
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)$closeChar")
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
    }
}

Set-PSReadLineKeyHandler -Key ')', ']', '}' `
    -BriefDescription SmartCloseBraces `
    -LongDescription "Insert closing brace or skip" `
    -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    if ($line[$cursor] -eq $key.KeyChar) {
        [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($cursor + 1)
    }
    else {
        [Microsoft.PowerShell.PSConsoleReadLine]::Insert("$($key.KeyChar)")
    }
}

Set-PSReadLineKeyHandler -Key Backspace `
    -BriefDescription SmartBackspace `
    -LongDescription "Delete previous character or matching quotes/parens/braces" `
    -ScriptBlock {
    param($key, $arg)

    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

    if ($cursor -gt 0) {
        $toMatch = $null
        if ($cursor -lt $line.Length) {
            switch ($line[$cursor]) {
                <#case#> '"' { $toMatch = '"'; break }
                <#case#> "'" { $toMatch = "'"; break }
                <#case#> ')' { $toMatch = '('; break }
                <#case#> ']' { $toMatch = '['; break }
                <#case#> '}' { $toMatch = '{'; break }
            }
        }

        if ($toMatch -ne $null -and $line[$cursor - 1] -eq $toMatch) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Delete($cursor - 1, 2)
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar($key, $arg)
        }
    }
}

#############################
# Highlighting
#############################

Import-Module PSColor
# Import-Module syntax-highlighting

#############################
# Completions
#############################

Import-Module $Env:SCOOP\modules\posh-cargo
Import-Module $Env:SCOOP\modules\posh-docker
Import-Module $Env:SCOOP\modules\posh-git
Import-Module $Env:SCOOP\modules\scoop-completion
Import-Module $Env:SCOOP\modules\dockercompletion
Import-Module $Env:SCOOP\apps\bottom\current\completion\_btm.ps1
starship completions powershell | Out-String | Invoke-Expression
rustup completions powershell | Out-String | Invoke-Expression
fnm completions --shell powershell | Out-String | Invoke-Expression
dvm completions powershell | Out-String | Invoke-Expression
deno completions powershell --unstable | Out-String | Invoke-Expression
# (& conda 'shell.powershell' 'hook') | Out-String | Invoke-Expression
(& volta completions powershell) | Out-String | Invoke-Expression
Invoke-Expression (& { $hook = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwd' } else { 'prompt' } (zoxide init powershell --hook $hook | Out-String) })

#############################
# Fuck!
#############################

$Env:PYTHONIOENCODING = "utf-8"
thefuck --alias | Out-String | Invoke-Expression

#############################
# Starship
#############################

Invoke-Expression (&starship init powershell)

#############################
# Rust
#############################

# Rustup

$Env:RUSTUP_DIST_SERVER = "https://mirrors.ustc.edu.cn/rust-static"
$Env:RUSTUP_UPDATE_ROOT = "https://mirrors.ustc.edu.cn/rust-static/rustup"

#############################
# fnm
#############################

$Env:FNM_DIR = "D:\.fnm"
$Env:FNM_NODE_DIST_MIRROR = "https://cdn.npmmirror.com/binaries/node"

fnm env --use-on-cd | Out-String | Invoke-Expression

#############################
# Misc
#############################

$Env:FFMPEG_DIR = "$Env:SCOOP\apps\ffmpeg-shared\current"
$Env:LIBCLANG_PATH = "$Env:SCOOP\apps\llvm\current\bin"

#############################
# PyEnv
#############################

# $Env:PYTHON_BUILD_MIRROR_URL = "https://npm.taobao.org/mirrors/python"

#############################
# Zoxide alias
# Well, this should be here
#############################

# Remove-Alias -Name cd -Force
# Set-Alias cd z

#############################
# PNPM
#############################

$Env:PNPM_HOME = "D:\.pnpm"
$Env:Path += ";$Env:PNPM_HOME"

#############################
# Path
#############################

$Env:Path += ";C:\Users\Hatsune_Miku\.deno\bin"

#############################
# Binary Mirror
#############################

$Env:NODEJS_ORG_MIRROR = "https://cdn.npmmirror.com/binaries/node"
$Env:NVM_NODEJS_ORG_MIRROR = "https://cdn.npmmirror.com/binaries/node"
$Env:PHANTOMJS_CDNURL = "https://cdn.npmmirror.com/binaries/phantomjs"
$Env:CHROMEDRIVER_CDNURL = "https://cdn.npmmirror.com/binaries/chromedriver"
$Env:OPERADRIVER_CDNURL = "https://cdn.npmmirror.com/binaries/operadriver"
$Env:ELECTRON_MIRROR = "https://cdn.npmmirror.com/binaries/electron/"
$Env:ELECTRON_BUILDER_BINARIES_MIRROR = "https://cdn.npmmirror.com/binaries/electron-builder-binaries/"
$Env:SASS_BINARY_SITE = "https://cdn.npmmirror.com/binaries/node-sass"
$Env:SWC_BINARY_SITE = "https://cdn.npmmirror.com/binaries/node-swc"
$Env:NWJS_URLBASE = "https://cdn.npmmirror.com/binaries/nwjs/v"
$Env:PUPPETEER_DOWNLOAD_HOST = "https://cdn.npmmirror.com/binaries"
$Env:SENTRYCLI_CDNURL = "https://cdn.npmmirror.com/binaries/sentry-cli"
$Env:SAUCECTL_INSTALL_BINARY_MIRROR = "https://cdn.npmmirror.com/binaries/saucectl"
$Env:npm_config_sharp_binary_host = "https://cdn.npmmirror.com/binaries/sharp"
$Env:npm_config_sharp_libvips_binary_host = "https://cdn.npmmirror.com/binaries/sharp-libvips"
$Env:npm_config_robotjs_binary_host = "https://cdn.npmmirror.com/binaries/robotj"
# For Cypress >=10.6.0, https://docs.cypress.io/guides/references/changelog#10-6-0
$Env:CYPRESS_DOWNLOAD_PATH_TEMPLATE = 'https://cdn.npmmirror.com/binaries/cypress/${version}/${platform}-${arch}/cypress.zip'

#############################
# Aliases
#############################

# Fix @antfu/ni
Remove-Alias -Name ni -Force
# Fix Scoop Install alias
Remove-Alias -Name si -Force

# Git
Import-Module $Env:SCOOP\modules\git-aliases
Set-Alias git hub
# VS Code
Set-Alias code code-insiders

# Node
function nio { ni --prefer-offline @Args }
function nid { ni -D @Args }
function niod { ni -D --prefer-offline @Args }
function d { nr dev @Args }
function s { nr start @Args }
function b { nr build @Args }
function bw { nr build --watch @Args }
function t { nr test @Args }
function tu { nr test -u @Args }
function tw { nr test --watch @Args }
function w { nr watch @Args }
function p { pnpm publish --access public --no-git-checks @Args }
function tc { nr typecheck @Args }
function l { nr lint @Args }
function lf { nr lint:fix @Args }
function release { nr release @Args }
function re { nr release @Args }

function taze { nx taze@latest @Args }
function tzm { taze major @Args }
function tz { taze major -wfri @Args }
function giget { nx giget@latest @Args }
function vc { nx vercel@latest @Args }
function vcp { vc --prod @Args }

# Deno
$DEPLOY_TOKEN = ""
function dctl { deployctl deploy --token=$DEPLOY_TOKEN @Args }
function dctlp { dctl --prod @Args }

# Go
function gg { go get @Args }
function gmt { go mod tidy @Args }
function gmi { go mod init @Args }
function gt { go test @Args }
function gta { go test ./... @Args }

# Python
function pi { pip install @Args }
function pu { pip install --upgrade @Args }
function pup { pu pip }

# Misc
function yg { you-get -o="D:\.you-get" @Args } # You-get
function si { scoop install @Args } # Scoop Install
function sun { scoop uninstall @Args } # Scoop Uninstall
function proxy {
    $Env:http_proxy = "http://127.0.0.1:7890"
    $Env:https_proxy = "http://127.0.0.1:7890"
}
function unproxy {
    $Env:http_proxy = ""
    $Env:https_proxy = ""
}
function fnmn { fnm --node-dist-mirror https://nodejs.org/download/nightly/ @Args }
function Rename-Branch {
    git branch -m $Args[0] $Args[1]
    git fetch origin
    git branch -u "origin/$Args[1]" $Args[1]
    git remote set-head origin -a
}

# INIT Proxy

proxy
