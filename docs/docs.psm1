# modules\docs\docs.psm1
#
# Read common document formats without Office or a paid SDK:
#   * docx/xlsx/pptx/odt are ZIP + XML, so System.IO.Compression is enough;
#   * PDF is either pdftotext (if installed) or a built-in FlateDecode pass;
#   * images are resized with System.Drawing.
#
# Text extraction only. Nothing here writes to the source file.

function Get-DocTools {
    @(
        [pscustomobject]@{
            name        = 'doc_read'
            policy      = 'allow'
            description = 'Extract the text of a document: PDF, .docx, .xlsx, .pptx, .odt/.ods/.odp, .txt/.md/.html/.csv/.json. Returns the text (or a spreadsheet as tab-separated rows) and says how it was extracted. A path is relative to the workspace unless it is absolute.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path      = @{ type = 'string'; description = 'Document path' }
                    max_chars = @{ type = 'integer'; description = 'Truncate the result, default 20000, max 200000' }
                }
                required = @('path')
            }
            handler     = 'Invoke-DocRead'
        }
        [pscustomobject]@{
            name        = 'image_resize'
            policy      = 'ask'
            description = 'Resize an image to fit within max_width x max_height and save a copy (default: same folder, "-small" suffix). Keeps the aspect ratio. Useful before look_at, which refuses images over 8 MB.'
            parameters  = @{
                type = 'object'
                properties = @{
                    path       = @{ type = 'string'; description = 'Source image (png, jpg, bmp, gif)' }
                    out        = @{ type = 'string'; description = 'Destination path, optional' }
                    max_width  = @{ type = 'integer'; description = 'Default 1600' }
                    max_height = @{ type = 'integer'; description = 'Default 1600' }
                    quality    = @{ type = 'integer'; description = 'JPEG quality 1-100, default 85' }
                }
                required = @('path')
            }
            handler     = 'Invoke-ImageResize'
        }
    )
}

function Resolve-DocPath {
    param($A, [string]$Path)

    if (-not $Path) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $ws = ''
    try { $ws = [string]$A.Workspace } catch { }
    if (-not $ws) { $ws = (Get-Location).Path }
    return (Join-Path $ws $Path)
}

function Get-ZipEntryText {
    param($Zip, [string]$Name)

    $entry = $Zip.GetEntry($Name)
    if (-not $entry) { return '' }
    $s = $entry.Open()
    try {
        $sr = [System.IO.StreamReader]::new($s, [System.Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    } finally {
        try { $sr.Dispose() } catch { }
        try { $s.Dispose() } catch { }
    }
}

function ConvertFrom-XmlText {
    # XML fragments in these formats are simple: tags carry structure, the text
    # between them is the content. Turn paragraph ends into newlines first.
    param([string]$Xml)

    if (-not $Xml) { return '' }
    $t = $Xml
    $t = $t -replace '(?i)</w:p>', "`n"
    $t = $t -replace '(?i)<w:tab[^>]*/>', "`t"
    $t = $t -replace '(?i)<w:br[^>]*/>', "`n"
    $t = $t -replace '(?i)</a:p>', "`n"
    $t = $t -replace '(?i)</text:p>', "`n"
    $t = $t -replace '(?i)</text:h>', "`n"
    $t = $t -replace '(?i)<text:tab[^>]*/>', "`t"
    $t = $t -replace '(?s)<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace "`r`n", "`n"
    $t = $t -replace "`n{3,}", "`n`n"
    return $t.Trim()
}

$script:PdfToTextPath = $null

function Get-PdfToTextPath {
    # pdftotext beats the built-in extractor on real PDFs (embedded fonts, hex
    # strings). PATH first, then the winget package folder, because a process
    # that started before the install does not see the new PATH entry.
    if ($script:PdfToTextPath) { return $script:PdfToTextPath }
    $c = Get-Command 'pdftotext.exe' -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { $script:PdfToTextPath = [string]$c.Source; return $script:PdfToTextPath }
    foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'), (Join-Path $env:ProgramFiles 'poppler'))) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        try {
            $f = Get-ChildItem -LiteralPath $base -Filter 'pdftotext.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { $script:PdfToTextPath = $f.FullName; return $script:PdfToTextPath }
        } catch { }
    }
    return ''
}

function Get-PdfText {
    # Best effort without a dependency. pdftotext is used when present; otherwise
    # every FlateDecode stream is inflated and the text operators inside it are
    # read. That handles ordinary text PDFs; a PDF that embeds subset fonts with
    # custom encodings can come back as gibberish, and the caller is told so.
    param([string]$Path)

    $pdftotext = Get-PdfToTextPath
    if ($pdftotext) {
        $tmp = Join-Path $env:TEMP ('pa-pdf-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $pdftotext
            foreach ($a in @('-layout', '-enc', 'UTF-8', $Path, $tmp)) { $psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $null = $p.StandardError.ReadToEnd()
            [void]$p.WaitForExit(30000)
            if (Test-Path -LiteralPath $tmp) { return [pscustomobject]@{ text = [System.IO.File]::ReadAllText($tmp); method = 'pdftotext' } }
        } catch { } finally { try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch { } }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $raw = [System.Text.Encoding]::Latin1.GetString($bytes)
    $sb = [System.Text.StringBuilder]::new()

    foreach ($m in [regex]::Matches($raw, '(?s)stream\r?\n(.*?)endstream')) {
        $chunk = $m.Groups[1].Value
        $text = ''
        $data = [System.Text.Encoding]::Latin1.GetBytes($chunk)
        try {
            # zlib header: 2 bytes, then raw deflate, then Adler-32.
            if ($data.Length -gt 6 -and $data[0] -eq 0x78) {
                $ms = [System.IO.MemoryStream]::new($data, 2, $data.Length - 6)
                $ds = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
                $out = [System.IO.MemoryStream]::new()
                $ds.CopyTo($out)
                $ds.Dispose(); $ms.Dispose()
                $text = [System.Text.Encoding]::Latin1.GetString($out.ToArray())
                $out.Dispose()
            } else {
                $text = $chunk
            }
        } catch { continue }

        if ($text -notmatch '\bBT\b') { continue }
        # Text strings between parentheses, then Tj/TJ or the quote operators.
        foreach ($t in [regex]::Matches($text, '(?s)\((?:[^()\\]|\\.)*\)')) {
            $s = $t.Value.Substring(1, $t.Value.Length - 2)
            $s = $s -replace '\\n', "`n" -replace '\\r', "`r" -replace '\\t', "`t"
            $s = $s -replace '\\([()\\])', '$1'
            [void]$sb.Append($s)
        }
        [void]$sb.Append("`n")
    }

    $result = $sb.ToString()
    $result = $result -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '' 
    $result = $result -replace "`n{3,}", "`n`n"
    return [pscustomobject]@{ text = $result.Trim(); method = $(if ($result.Trim()) { 'built-in FlateDecode (no pdftotext)' } else { 'none' }) }
}

function Get-XlsxText {
    param($Zip)

    $shared = @()
    $sst = Get-ZipEntryText $Zip 'xl/sharedStrings.xml'
    if ($sst) {
        foreach ($m in [regex]::Matches($sst, '(?s)<si>(.*?)</si>')) {
            $val = [regex]::Replace($m.Groups[1].Value, '(?s)<[^>]+>', '')
            $shared += [System.Net.WebUtility]::HtmlDecode($val)
        }
    }

    $out = [System.Text.StringBuilder]::new()
    $sheets = @($Zip.Entries | Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' } | Sort-Object FullName)
    foreach ($sh in $sheets) {
        [void]$out.AppendLine(('--- ' + $sh.FullName))
        $xml = Get-ZipEntryText $Zip $sh.FullName
        foreach ($rm in [regex]::Matches($xml, '(?s)<row[^>]*>(.*?)</row>')) {
            $cells = @()
            foreach ($cm in [regex]::Matches($rm.Groups[1].Value, '(?s)<c([^>]*)>(.*?)</c>')) {
                $attrs = $cm.Groups[1].Value
                $inner = $cm.Groups[2].Value
                $vm = [regex]::Match($inner, '(?s)<v>(.*?)</v>')
                $value = if ($vm.Success) { $vm.Groups[1].Value } else { '' }
                if ($attrs -match 't="s"' -and $value -match '^\d+$') {
                    $idx = [int]$value
                    if ($idx -ge 0 -and $idx -lt $shared.Count) { $value = $shared[$idx] }
                }
                $tm = [regex]::Match($inner, '(?s)<t[^>]*>(.*?)</t>')
                if ($tm.Success) { $value = [System.Net.WebUtility]::HtmlDecode($tm.Groups[1].Value) }
                $cells += ($value -replace "`t", ' ')
            }
            if (($cells -join '').Trim()) { [void]$out.AppendLine(($cells -join "`t")) }
        }
    }
    return $out.ToString()
}

function Get-PptxText {
    param($Zip)

    $out = [System.Text.StringBuilder]::new()
    $slides = @($Zip.Entries | Where-Object { $_.FullName -match '^ppt/slides/slide\d+\.xml$' } |
        Sort-Object { [int]([regex]::Match($_.FullName, '(\d+)\.xml$').Groups[1].Value) })
    foreach ($sl in $slides) {
        $n = [regex]::Match($sl.FullName, '(\d+)\.xml$').Groups[1].Value
        [void]$out.AppendLine(('--- slide ' + $n))
        $xml = Get-ZipEntryText $Zip $sl.FullName
        foreach ($tm in [regex]::Matches($xml, '(?s)<a:t>(.*?)</a:t>')) {
            [void]$out.AppendLine([System.Net.WebUtility]::HtmlDecode($tm.Groups[1].Value))
        }
    }
    return $out.ToString()
}

function Invoke-DocRead {
    param($A, $ArgsObj)

    $raw = [string]$ArgsObj.path
    if (-not $raw) { return 'path is required' }
    $full = Resolve-DocPath $A $raw
    if (-not (Test-Path -LiteralPath $full)) { return "no such file: $raw" }
    if (Test-Path -LiteralPath $full -PathType Container) { return "$raw is a folder, not a document" }

    $max = 20000
    if ($ArgsObj.max_chars) { $max = [math]::Min(200000, [math]::Max(200, [int]$ArgsObj.max_chars)) }

    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
    $text = ''
    $method = ''

    try {
        if ($ext -in @('.txt', '.md', '.log', '.csv', '.json', '.xml', '.yaml', '.yml', '.ini', '.cfg')) {
            $text = [System.IO.File]::ReadAllText($full)
            $method = 'plain text'
        } elseif ($ext -in @('.html', '.htm', '.xhtml')) {
            $html = [System.IO.File]::ReadAllText($full)
            $t = $html -replace '(?is)<(script|style)[^>]*>.*?</\1>', ' '
            $t = $t -replace '(?i)<br[^>]*>|</p>|</div>|</h[1-6]>|</li>', "`n"
            $t = $t -replace '(?s)<[^>]+>', ' '
            $text = ([System.Net.WebUtility]::HtmlDecode($t) -replace '[ \t]{2,}', ' ').Trim()
            $method = 'HTML, tags stripped'
        } elseif ($ext -eq '.pdf') {
            $pdf = Get-PdfText $full
            $text = [string]$pdf.text
            $method = [string]$pdf.method
        } elseif ($ext -in @('.docx', '.xlsx', '.pptx', '.odt', '.ods', '.odp')) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($full)
            try {
                if ($ext -eq '.docx') {
                    $xml = Get-ZipEntryText $zip 'word/document.xml'
                    $text = ConvertFrom-XmlText $xml
                    $method = 'DOCX (word/document.xml)'
                } elseif ($ext -eq '.xlsx') {
                    $text = Get-XlsxText $zip
                    $method = 'XLSX (sharedStrings + sheets, tab-separated)'
                } elseif ($ext -eq '.pptx') {
                    $text = Get-PptxText $zip
                    $method = 'PPTX (slides in order)'
                } else {
                    $xml = Get-ZipEntryText $zip 'content.xml'
                    $text = ConvertFrom-XmlText $xml
                    $method = 'OpenDocument (content.xml)'
                }
            } finally {
                try { $zip.Dispose() } catch { }
            }
        } elseif ($ext -in @('.doc', '.xls', '.ppt')) {
            return ("$ext is the old binary Office format, which this cannot read. Save it as .docx/.xlsx/.pptx (Office: Save As) or export a PDF, then read that.")
        } else {
            return ("doc_read does not handle $ext. It reads PDF, docx, xlsx, pptx, odt/ods/odp and plain text/HTML.")
        }
    } catch {
        return ('could not read ' + $raw + ': ' + $_.Exception.Message)
    }

    if (-not $text.Trim()) {
        if ($ext -eq '.pdf') {
            return ('no text extracted from ' + $raw + '. The PDF may be a scan (an image) or use embedded font encodings. Try pdftotext (poppler) on PATH, or screenshot the pages and use look_at.')
        }
        return ('no text found in ' + $raw + ' (' + $method + ')')
    }

    $truncated = $false
    if ($text.Length -gt $max) { $text = $text.Substring(0, $max); $truncated = $true }

    $head = 'read ' + $raw + '  ' + $text.Length + ' chars' + $(if ($truncated) { ' (truncated)' } else { '' }) + '  [' + $method + ']'
    return ($head + "`n`n" + $text)
}

function Invoke-ImageResize {
    param($A, $ArgsObj)

    $raw = [string]$ArgsObj.path
    if (-not $raw) { return 'path is required' }
    $full = Resolve-DocPath $A $raw
    if (-not (Test-Path -LiteralPath $full)) { return "no such file: $raw" }

    $maxW = 1600
    if ($ArgsObj.max_width) { $maxW = [math]::Min(8000, [math]::Max(16, [int]$ArgsObj.max_width)) }
    $maxH = 1600
    if ($ArgsObj.max_height) { $maxH = [math]::Min(8000, [math]::Max(16, [int]$ArgsObj.max_height)) }
    $quality = 85
    if ($ArgsObj.quality) { $quality = [math]::Min(100, [math]::Max(10, [int]$ArgsObj.quality)) }

    $out = [string]$ArgsObj.out
    if (-not $out) {
        $dir = [System.IO.Path]::GetDirectoryName($full)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($full)
        $extn = [System.IO.Path]::GetExtension($full)
        $out = Join-Path $dir ($base + '-small' + $extn)
    } else {
        $out = Resolve-DocPath $A $out
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        # Load through a memory stream: Image.FromFile keeps the file locked, and
        # the caller may want to delete or replace the source afterwards.
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $ms = [System.IO.MemoryStream]::new($bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        try {
            $ratio = [math]::Min(1.0, [math]::Min($maxW / $img.Width, $maxH / $img.Height))
            $w = [math]::Max(1, [int][math]::Round($img.Width * $ratio))
            $h = [math]::Max(1, [int][math]::Round($img.Height * $ratio))
            $bmp = [System.Drawing.Bitmap]::new($w, $h)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.DrawImage($img, 0, 0, $w, $h)
            } finally { $g.Dispose() }

            $extOut = [System.IO.Path]::GetExtension($out).ToLowerInvariant()
            if ($extOut -in @('.jpg', '.jpeg')) {
                $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
                $ep = [System.Drawing.Imaging.EncoderParameters]::new(1)
                $ep.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$quality)
                $bmp.Save($out, $codec, $ep)
                $ep.Dispose()
            } else {
                $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            $bmp.Dispose()
            $outLen = (Get-Item -LiteralPath $out).Length
            return ('resized ' + $raw + ': ' + $img.Width + 'x' + $img.Height + ' -> ' + $w + 'x' + $h + '  ' + [math]::Round($outLen / 1KB) + ' KB  -> ' + $out)
        } finally {
            $img.Dispose()
            $ms.Dispose()
        }
    } catch {
        return ('could not resize ' + $raw + ': ' + $_.Exception.Message)
    }
}

Export-ModuleMember -Function @('Get-DocTools', 'Invoke-DocRead', 'Invoke-ImageResize')
