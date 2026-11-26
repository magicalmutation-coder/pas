# modules\calc\calc.psm1
#
# Arithmetic a model can call instead of writing a shell one-liner. Deliberately
# a parser, not Invoke-Expression: an expression from a model is untrusted text,
# and `1; Remove-Item ...` must be a parse error rather than a command.
#
# Grammar (recursive descent, right-associative ^):
#   expr   := term (('+'|'-') term)*
#   term   := unary (('*'|'/'|'%') unary)*
#   unary  := ('+'|'-') unary | power
#   power  := primary ('^' unary)?
#   primary:= NUMBER | pi | e | FUNC '(' expr ')' | '(' expr ')'

function Get-CalcTools {
    @(
        [pscustomobject]@{
            name        = 'calc'
            policy      = 'allow'
            description = 'Evaluate arithmetic: + - * / % ^, parentheses, unary minus, sqrt/abs/round/floor/ceil, pi and e. Use it for sums instead of writing a shell command.'
            parameters  = @{
                type = 'object'
                properties = @{ expression = @{ type = 'string'; description = 'e.g. (1200 * 1.2) / 3 or sqrt(2)^2' } }
                required = @('expression')
            }
            handler     = 'Invoke-CalcTool'
        }
    )
}

function Split-CalcTokens {
    param([string]$Text)

    $tokens = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ([char]::IsWhiteSpace($ch)) { $i++; continue }

        if ([char]::IsDigit($ch) -or $ch -eq '.') {
            $start = $i
            $seenDot = $false
            while ($i -lt $Text.Length) {
                $c = $Text[$i]
                if ([char]::IsDigit($c)) { $i++; continue }
                if ($c -eq '.' -and -not $seenDot) { $seenDot = $true; $i++; continue }
                break
            }
            $raw = $Text.Substring($start, $i - $start)
            $value = 0.0
            if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
                throw "not a number: '$raw'"
            }
            $tokens.Add([pscustomobject]@{ kind = 'num'; text = $raw; value = $value })
            continue
        }

        if ([char]::IsLetter($ch)) {
            $start = $i
            while ($i -lt $Text.Length -and ([char]::IsLetterOrDigit($Text[$i]) -or $Text[$i] -eq '_')) { $i++ }
            $tokens.Add([pscustomobject]@{ kind = 'name'; text = $Text.Substring($start, $i - $start).ToLowerInvariant(); value = 0 })
            continue
        }

        if ('+-*/%^()'.Contains([string]$ch)) {
            $tokens.Add([pscustomobject]@{ kind = 'op'; text = [string]$ch; value = 0 })
            $i++
            continue
        }

        throw "unexpected character '$ch' - only numbers, + - * / % ^ ( ), pi, e and sqrt/abs/round/floor/ceil are allowed"
    }
    return , $tokens
}

function Invoke-Calc {
    # Returns a double. Throws a message a model can act on.
    param([string]$Expression)

    if (-not $Expression -or -not $Expression.Trim()) { throw 'expression is empty' }
    if ($Expression.Length -gt 400) { throw 'expression is too long (400 characters max)' }

    $tokens = Split-CalcTokens $Expression
    if (-not $tokens.Count) { throw 'expression is empty' }
    if ($tokens.Count -gt 400) { throw 'expression has too many parts' }

    $script:calcPos = 0
    $script:calcDepth = 0

    function Peek { if ($script:calcPos -lt $tokens.Count) { return $tokens[$script:calcPos] } return $null }
    function Take { $t = Peek; if ($t) { $script:calcPos++ }; return $t }

    function ParsePrimary {
        $script:calcDepth++
        if ($script:calcDepth -gt 32) { throw 'expression is nested too deeply' }
        try {
            $t = Take
            if (-not $t) { throw 'expression ended early' }

            if ($t.kind -eq 'num') { return [double]$t.value }

            if ($t.kind -eq 'name') {
                if ($t.text -eq 'pi') { return [Math]::PI }
                if ($t.text -eq 'e') { return [Math]::E }
                if ($t.text -in @('sqrt', 'abs', 'round', 'floor', 'ceil')) {
                    $open = Take
                    if (-not $open -or $open.text -ne '(') { throw "$($t.text) needs parentheses, e.g. $($t.text)(9)" }
                    $v = ParseExpr
                    $close = Take
                    if (-not $close -or $close.text -ne ')') { throw 'missing a closing )' }
                    switch ($t.text) {
                        'sqrt' { if ($v -lt 0) { throw 'sqrt of a negative number' }; return [Math]::Sqrt($v) }
                        'abs' { return [Math]::Abs($v) }
                        'round' { return [Math]::Round($v) }
                        'floor' { return [Math]::Floor($v) }
                        'ceil' { return [Math]::Ceiling($v) }
                    }
                }
                throw "unknown name '$($t.text)' - try pi, e, sqrt, abs, round, floor or ceil"
            }

            if ($t.text -eq '(') {
                $v = ParseExpr
                $close = Take
                if (-not $close -or $close.text -ne ')') { throw 'missing a closing )' }
                return $v
            }

            throw "unexpected '$($t.text)'"
        } finally {
            $script:calcDepth--
        }
    }

    function ParseUnary {
        $t = Peek
        if ($t -and $t.kind -eq 'op' -and ($t.text -eq '-' -or $t.text -eq '+')) {
            [void](Take)
            $v = ParseUnary
            if ($t.text -eq '-') { return -$v }
            return $v
        }
        return ParsePower
    }

    function ParsePower {
        $base = ParsePrimary
        $t = Peek
        if ($t -and $t.kind -eq 'op' -and $t.text -eq '^') {
            [void](Take)
            # Right-associative: 2^3^2 is 2^(3^2).
            $exp = ParseUnary
            return [Math]::Pow($base, $exp)
        }
        return $base
    }

    function ParseTerm {
        $v = ParseUnary
        while ($true) {
            $t = Peek
            if (-not $t -or $t.kind -ne 'op' -or -not ('*/%'.Contains($t.text))) { break }
            [void](Take)
            $r = ParseUnary
            switch ($t.text) {
                '*' { $v = $v * $r }
                '/' { if ($r -eq 0) { throw 'division by zero' }; $v = $v / $r }
                '%' { if ($r -eq 0) { throw 'modulo by zero' }; $v = $v % $r }
            }
        }
        return $v
    }

    function ParseExpr {
        $v = ParseTerm
        while ($true) {
            $t = Peek
            if (-not $t -or $t.kind -ne 'op' -or -not ('+-'.Contains($t.text))) { break }
            [void](Take)
            $r = ParseTerm
            if ($t.text -eq '-') { $v = $v - $r } else { $v = $v + $r }
        }
        return $v
    }

    $result = ParseExpr
    if ($script:calcPos -lt $tokens.Count) {
        $leftover = $tokens[$script:calcPos].text
        throw "unexpected '$leftover' after the expression ended"
    }
    return [double]$result
}

function Format-CalcNumber {
    param([double]$Value)

    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { return [string]$Value }
    # 12 significant digits is enough for anything a person reads, and it stops
    # 0.1+0.2 printing as 0.30000000000000004.
    $rounded = [Math]::Round($Value, 12)
    if ($rounded -eq [Math]::Truncate($rounded) -and [Math]::Abs($rounded) -lt 1e15) {
        return ([long]$rounded).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $rounded.ToString('0.############', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-CalcTool {
    param($A, $Job, $ArgsObj)

    $expr = ''
    if ($ArgsObj -and $ArgsObj.expression) { $expr = [string]$ArgsObj.expression }
    if (-not $expr.Trim()) { return 'calc needs an expression, e.g. {"expression":"(1200 * 1.2) / 3"}' }

    try {
        $value = Invoke-Calc $expr
    } catch {
        return ('calc: ' + $_.Exception.Message)
    }
    return ($expr.Trim() + ' = ' + (Format-CalcNumber $value))
}

Export-ModuleMember -Function @('Get-CalcTools', 'Invoke-CalcTool', 'Invoke-Calc', 'Format-CalcNumber')
