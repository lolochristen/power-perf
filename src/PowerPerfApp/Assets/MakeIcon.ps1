Add-Type -AssemblyName System.Drawing

# ── shared drawing helpers ──────────────────────────────────────────────────────

function Draw-Background {
    param($g, $x, $y, $w, $h, [bool]$circle = $true)

    $rect = New-Object System.Drawing.RectangleF($x, $y, $w, $h)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 24, 30, 52),
        [System.Drawing.Color]::FromArgb(255, 14, 18, 36),
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
    )
    if ($circle) {
        $g.FillEllipse($brush, $x, $y, $w, $h)
    } else {
        $g.FillRectangle($brush, $x, $y, $w, $h)
    }
    $brush.Dispose()
}

function Draw-GaugeArc {
    param($g, $cx, $cy, $r, [float]$thick)

    $arcPen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(200, 80, 200, 100), $thick)
    $arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($arcPen, ($cx - $r), ($cy - $r), (2 * $r), (2 * $r), 160, -320)
    $arcPen.Dispose()
}

function Draw-Bolt {
    param($g, $cx, $cy, $boltH, [bool]$outline = $true)

    # Lightning bolt polygon defined on a 256-tall basis, centred at origin
    # Points designed so the bolt is ~38% wide relative to its height
    $scale = $boltH / 256.0
    $hw    = 40 * $scale   # half-width offset from centre

    $pts = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([float]($cx + $hw),        [float]($cy - $boltH * 0.47)),
        [System.Drawing.PointF]::new([float]($cx - $hw * 1.55), [float]($cy + $boltH * 0.04)),
        [System.Drawing.PointF]::new([float]($cx - $hw * 0.1),  [float]($cy + $boltH * 0.04)),
        [System.Drawing.PointF]::new([float]($cx - $hw * 1.2),  [float]($cy + $boltH * 0.47)),
        [System.Drawing.PointF]::new([float]($cx + $hw * 1.55), [float]($cy - $boltH * 0.04)),
        [System.Drawing.PointF]::new([float]($cx + $hw * 0.1),  [float]($cy - $boltH * 0.04)),
        [System.Drawing.PointF]::new([float]($cx + $hw),        [float]($cy - $boltH * 0.47))
    )

    $boltBrush = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(255, 255, 210, 20))
    $g.FillPolygon($boltBrush, $pts)
    $boltBrush.Dispose()

    if ($outline -and $boltH -ge 20) {
        $outlinePen = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::FromArgb(70, 0, 0, 0),
            [float]($boltH * 0.025))
        $g.DrawPolygon($outlinePen, $pts)
        $outlinePen.Dispose()
    }
}

function New-Bitmap {
    param([int]$w, [int]$h)
    $bmp = New-Object System.Drawing.Bitmap($w, $h,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    return $bmp, $g
}

function Save-Png {
    param($bmp, [string]$path)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "  $path"
}

# ── square badge (circle bg + arc + bolt) ──────────────────────────────────────

function New-SquareAsset {
    param([int]$w, [int]$h)

    $bmp, $g = New-Bitmap $w $h

    $pad   = [int]($w * 0.06)
    $inner = $w - 2 * $pad
    Draw-Background $g $pad $pad $inner $inner $true

    $cx    = $w / 2.0
    $cy    = $h / 2.0
    $arcR  = ($inner / 2.0) * 0.78
    $thick = [float]($w * 0.07)
    Draw-GaugeArc $g $cx $cy $arcR $thick

    $boltH = $h * 0.60
    Draw-Bolt $g $cx $cy $boltH ($w -ge 30)

    $g.Dispose()
    return $bmp
}

# ── wide tile (rectangle bg + arc left + bolt) ─────────────────────────────────

function New-WideAsset {
    param([int]$w, [int]$h)

    $bmp, $g = New-Bitmap $w $h

    # Dark background (full rectangle, rounded corners via clip)
    $radius = [int]($h * 0.12)
    $path   = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, (2 * $radius), (2 * $radius), 180, 90)
    $path.AddArc(($w - 2 * $radius), 0, (2 * $radius), (2 * $radius), 270, 90)
    $path.AddArc(($w - 2 * $radius), ($h - 2 * $radius), (2 * $radius), (2 * $radius), 0, 90)
    $path.AddArc(0, ($h - 2 * $radius), (2 * $radius), (2 * $radius), 90, 90)
    $path.CloseFigure()
    $g.SetClip($path)

    Draw-Background $g 0 0 $w $h $false

    # Circle / arc on the left half
    $cx    = $h * 0.5
    $cy    = $h * 0.5
    $arcR  = $h * 0.36
    $thick = [float]($h * 0.07)
    Draw-GaugeArc $g $cx $cy $arcR $thick

    # Bolt centred on the circle
    $boltH = $h * 0.60
    Draw-Bolt $g $cx $cy $boltH $true

    # "PowerPerf" label on the right
    $fontSize = [float]($h * 0.22)
    $font  = New-Object System.Drawing.Font("Segoe UI", $fontSize,
        [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $textX = $h * 1.05
    $textY = ($h - $fontSize * 1.3) / 2.0
    $g.DrawString("PowerPerf", $font, $brush, [float]$textX, [float]$textY)
    $font.Dispose()
    $brush.Dispose()

    $g.ResetClip()
    $g.Dispose()
    return $bmp
}

# ── splash screen (wide, centred circle + bolt on dark bg) ─────────────────────

function New-SplashAsset {
    param([int]$w, [int]$h)

    $bmp, $g = New-Bitmap $w $h

    Draw-Background $g 0 0 $w $h $false

    $cx    = $w / 2.0
    $cy    = $h / 2.0
    $r     = $h * 0.32
    $thick = [float]($h * 0.065)

    # Background circle
    $circleBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.RectangleF(($cx - $r), ($cy - $r), (2 * $r), (2 * $r))),
        [System.Drawing.Color]::FromArgb(255, 34, 42, 68),
        [System.Drawing.Color]::FromArgb(255, 20, 26, 48),
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
    $g.FillEllipse($circleBrush, ($cx - $r), ($cy - $r), (2 * $r), (2 * $r))
    $circleBrush.Dispose()

    Draw-GaugeArc $g $cx $cy ($r * 0.82) $thick

    $boltH = $h * 0.50
    Draw-Bolt $g $cx $cy $boltH $true

    # App name below
    $fontSize = [float]($h * 0.11)
    $font  = New-Object System.Drawing.Font("Segoe UI", $fontSize,
        [System.Drawing.FontStyle]::Bold)
    $brush = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(220, 255, 255, 255))
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $labelRect = New-Object System.Drawing.RectangleF(0, ($cy + $r * 1.1), $w, ($h / 4.0))
    $g.DrawString("PowerPerf", $font, $brush, $labelRect, $sf)
    $font.Dispose()
    $brush.Dispose()
    $sf.Dispose()

    $g.Dispose()
    return $bmp
}

# ── ICO builder ─────────────────────────────────────────────────────────────────

function New-Ico {
    param([string]$OutputPath, [int[]]$Sizes)

    $pngBlobs = [System.Collections.Generic.List[byte[]]]::new()

    foreach ($sz in $Sizes) {
        $bmp = New-SquareAsset $sz $sz
        $ms  = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBlobs.Add($ms.ToArray())
        $ms.Dispose()
        $bmp.Dispose()
    }

    $count      = $pngBlobs.Count
    $dataOffset = 6 + 16 * $count

    $fs     = [System.IO.File]::OpenWrite($OutputPath)
    $writer = New-Object System.IO.BinaryWriter($fs)

    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$count)

    $offset = $dataOffset
    for ($i = 0; $i -lt $count; $i++) {
        $sz = $Sizes[$i]
        $w  = if ($sz -eq 256) { 0 } else { $sz }
        $writer.Write([byte]$w)
        $writer.Write([byte]$w)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$pngBlobs[$i].LongLength)
        $writer.Write([uint32]$offset)
        $offset += $pngBlobs[$i].Length
    }

    foreach ($blob in $pngBlobs) { $writer.Write($blob) }
    $writer.Dispose()
    $fs.Dispose()
    Write-Host "  $OutputPath"
}

# ── generate all assets ─────────────────────────────────────────────────────────

$dir = $PSScriptRoot
Write-Host "Generating assets in $dir ..."

# ICO (256, 64, 32, 16)
New-Ico "$dir\PowerPerf.ico" @(256, 64, 32, 16)

# Square badges
(New-SquareAsset  50  50) | ForEach-Object { Save-Png $_ "$dir\StoreLogo.png" }
(New-SquareAsset  88  88) | ForEach-Object { Save-Png $_ "$dir\Square44x44Logo.scale-200.png" }
(New-SquareAsset  24  24) | ForEach-Object { Save-Png $_ "$dir\Square44x44Logo.targetsize-24_altform-unplated.png" }
(New-SquareAsset 300 300) | ForEach-Object { Save-Png $_ "$dir\Square150x150Logo.scale-200.png" }
(New-SquareAsset  48  48) | ForEach-Object { Save-Png $_ "$dir\LockScreenLogo.scale-200.png" }

# Wide tile
(New-WideAsset  620 300) | ForEach-Object { Save-Png $_ "$dir\Wide310x150Logo.scale-200.png" }

# Splash screen
(New-SplashAsset 1240 600) | ForEach-Object { Save-Png $_ "$dir\SplashScreen.scale-200.png" }

Write-Host "Done."
