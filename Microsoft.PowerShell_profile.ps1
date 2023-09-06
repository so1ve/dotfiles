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

Import-Module $env:SCOOP\modules\posh-cargo
Import-Module $env:SCOOP\modules\posh-docker
Import-Module $env:SCOOP\modules\posh-git
Import-Module $env:SCOOP\modules\scoop-completion
Import-Module $env:SCOOP\modules\dockercompletion
Import-Module $env:SCOOP\apps\bottom\current\completion\_btm.ps1
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

$env:PYTHONIOENCODING = "utf-8"
thefuck --alias | Out-String | Invoke-Expression

#############################
# Starship
#############################

Invoke-Expression (&starship init powershell)

#############################
# Rust
#############################

# Rustup

$env:RUSTUP_DIST_SERVER = "https://mirrors.ustc.edu.cn/rust-static"
$env:RUSTUP_UPDATE_ROOT = "https://mirrors.ustc.edu.cn/rust-static/rustup"

#############################
# fnm
#############################

$env:FNM_DIR = "D:\.fnm"
$env:FNM_NODE_DIST_MIRROR = "https://cdn.npmmirror.com/binaries/node"

fnm env --use-on-cd | Out-String | Invoke-Expression

#############################
# Misc
#############################

$env:FFMPEG_DIR = "$env:SCOOP\apps\ffmpeg-shared\current"
$env:LIBCLANG_PATH = "$env:SCOOP\apps\llvm\current\bin"

#############################
# PyEnv
#############################

# $env:PYTHON_BUILD_MIRROR_URL = "https://npm.taobao.org/mirrors/python"

#############################
# Zoxide alias
# Well, this should be here
#############################

# Remove-Alias -Name cd -Force
# Set-Alias cd z

#############################
# PNPM
#############################

$env:PNPM_HOME = "D:\.pnpm"
$env:Path += ";$env:PNPM_HOME"

#############################
# Path
#############################

$env:Path += ";C:\Users\Hatsune_Miku\.deno\bin"

#############################
# Binary Mirror
#############################

$env:NODEJS_ORG_MIRROR = "https://cdn.npmmirror.com/binaries/node"
$env:NVM_NODEJS_ORG_MIRROR = "https://cdn.npmmirror.com/binaries/node"
$env:PHANTOMJS_CDNURL = "https://cdn.npmmirror.com/binaries/phantomjs"
$env:CHROMEDRIVER_CDNURL = "https://cdn.npmmirror.com/binaries/chromedriver"
$env:OPERADRIVER_CDNURL = "https://cdn.npmmirror.com/binaries/operadriver"
$env:ELECTRON_MIRROR = "https://cdn.npmmirror.com/binaries/electron/"
$env:ELECTRON_BUILDER_BINARIES_MIRROR = "https://cdn.npmmirror.com/binaries/electron-builder-binaries/"
$env:SASS_BINARY_SITE = "https://cdn.npmmirror.com/binaries/node-sass"
$env:SWC_BINARY_SITE = "https://cdn.npmmirror.com/binaries/node-swc"
$env:NWJS_URLBASE = "https://cdn.npmmirror.com/binaries/nwjs/v"
$env:PUPPETEER_DOWNLOAD_HOST = "https://cdn.npmmirror.com/binaries"
$env:SENTRYCLI_CDNURL = "https://cdn.npmmirror.com/binaries/sentry-cli"
$env:SAUCECTL_INSTALL_BINARY_MIRROR = "https://cdn.npmmirror.com/binaries/saucectl"
$env:npm_config_sharp_binary_host = "https://cdn.npmmirror.com/binaries/sharp"
$env:npm_config_sharp_libvips_binary_host = "https://cdn.npmmirror.com/binaries/sharp-libvips"
$env:npm_config_robotjs_binary_host = "https://cdn.npmmirror.com/binaries/robotj"
# For Cypress >=10.6.0, https://docs.cypress.io/guides/references/changelog#10-6-0
$env:CYPRESS_DOWNLOAD_PATH_TEMPLATE = 'https://cdn.npmmirror.com/binaries/cypress/${version}/${platform}-${arch}/cypress.zip'

#############################
# Aliases
#############################

# Fix @antfu/ni
Remove-Alias -Name ni -Force
# Fix Scoop Install alias
Remove-Alias -Name si -Force

# Git
Import-Module $env:SCOOP\modules\git-aliases -DisableNameChecking
# VS Code
Set-Alias code code-insiders

# Node
function npm { corepack npm @args }
function npx { corepack npx @args }
function yarn { corepack yarn @args }
function pnpm { corepack pnpm @args }
function pnpx { corepack pnpx @args }

function nio { ni --prefer-offline @args }
function nid { ni -D @args }
function niod { ni -D --prefer-offline @args }
function d { nr dev @args }
function s { nr start @args }
function b { nr build @args }
function bw { nr build --watch @args }
function t { nr test @args }
function tu { nr test -u @args }
function tw { nr test --watch @args }
function w { nr watch @args }
function p { pnpm publish --access public --no-git-checks @args }
function tc { nr typecheck @args }
function l { nr lint @args }
function lf { nr lint:fix @args }
function re { nr release @args }
function play { nr play @args }
function create { pnpm create @args }

function taze { nx taze@latest @args }
function tzm { taze major @args }
function tz { taze major -wfri @args }
function giget { nx giget@latest @args }
function vc { nx vercel@latest @args }
function vcp { vc --prod @args }
function .. {
	cd ..
}
function .... {
	cd ../..
}

# Deno
$DEPLOY_TOKEN = ""
function dctl { deployctl deploy --token=$DEPLOY_TOKEN @args }
function dctlp { dctl --prod @args }

# Go
function gg { go get @args }
function gmt { go mod tidy @args }
function gmi { go mod init @args }
function gt { go test @args }
function gta { go test ./... @args }

# Python
function pi { pip install @args }
function pu { pip install --upgrade @args }
function pup { pu pip }

# Misc
function yg { you-get -o="D:\.you-get" @args } # You-get
function si { scoop install @args } # Scoop Install
function sun { scoop uninstall @args } # Scoop Uninstall
function proxy {
	$env:http_proxy = "http://127.0.0.1:7890"
	$env:https_proxy = "http://127.0.0.1:7890"
}
function unproxy {
	$env:http_proxy = ""
	$env:https_proxy = ""
}
function fnmn { fnm --node-dist-mirror https://nodejs.org/download/nightly/ @args }
function Rename-Branch {
	git branch -m $Args[0] $Args[1]
	git fetch origin
	git branch -u "origin/$Args[1]" $Args[1]
	git remote set-head origin -a
}

# Copilot for CLI
function ?? { 
	$TmpFile = New-TemporaryFile
	github-copilot-cli what-the-shell ("use powershell to " + $args) --shellout $TmpFile
	if ([System.IO.File]::Exists($TmpFile)) { 
			$TmpFileContents = Get-Content $TmpFile
					if ($TmpFileContents -ne $nill) {
					Invoke-Expression $TmpFileContents
					Remove-Item $TmpFile
			}
	}
}
function git? {
	$TmpFile = New-TemporaryFile
	github-copilot-cli git-assist ("use powershell to " + $args) --shellout $TmpFile
	if ([System.IO.File]::Exists($TmpFile)) {
			$TmpFileContents = Get-Content $TmpFile
					if ($TmpFileContents -ne $nill) {
					Invoke-Expression $TmpFileContents
					Remove-Item $TmpFile
			}
	}
}
function gh? {
	$TmpFile = New-TemporaryFile
	github-copilot-cli gh-assist ("use powershell to " + $args) --shellout $TmpFile
	if ([System.IO.File]::Exists($TmpFile)) {
			$TmpFileContents = Get-Content $TmpFile
					if ($TmpFileContents -ne $nill) {
					Invoke-Expression $TmpFileContents
					Remove-Item $TmpFile
			}
	}
}

# Fuck hard reset
function git {
	if ($args[0] -eq "reset" -and $args[1] -eq "--hard") {
		Write-Error "Fuck hard reset!!"
	} else {
		& hub @args
	}
}
function main {
	$mainExists = git branch --list main
	if ($mainExists) {
		git checkout main
	} else {
		git checkout master
	}
}

# INIT Proxy

proxy
