$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assetRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets.xcassets'
$slots = @(
    @('iphone', 20, '2x'), @('iphone', 20, '3x'),
    @('iphone', 29, '2x'), @('iphone', 29, '3x'),
    @('iphone', 40, '2x'), @('iphone', 40, '3x'),
    @('iphone', 60, '2x'), @('iphone', 60, '3x'),
    @('ipad', 20, '1x'), @('ipad', 20, '2x'),
    @('ipad', 29, '1x'), @('ipad', 29, '2x'),
    @('ipad', 40, '1x'), @('ipad', 40, '2x'),
    @('ipad', 76, '1x'), @('ipad', 76, '2x'), @('ipad', 83.5, '2x')
)
foreach ($animal in @('hiroCorgi', 'hiroSleepCat', 'hiroRoundCat', 'hiroShiba', 'hiroSpaniel')) {
    $folder = Join-Path $assetRoot ($animal + '.appiconset')
    $source = [System.Drawing.Image]::FromFile((Join-Path $folder ($animal + '.png')))
    try {
        $images = @()
        $exported = @{}
        foreach ($slot in $slots) {
            $idiom, $points, $scale = $slot
            $pixels = [int]($points * [int]$scale.Substring(0, 1))
            $filename = $animal + '-v2-' + $pixels + '.png'
            if (-not $exported.ContainsKey($pixels)) {
                $bitmap = [System.Drawing.Bitmap]::new($pixels, $pixels, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.DrawImage($source, 0, 0, $pixels, $pixels)
                    $bitmap.Save((Join-Path $folder $filename), [System.Drawing.Imaging.ImageFormat]::Png)
                } finally { $graphics.Dispose(); $bitmap.Dispose() }
                $exported[$pixels] = $true
            }
            $size = $points.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            $images += @{ idiom = $idiom; size = "$($size)x$($size)"; scale = $scale; filename = $filename }
        }
        $images += @{ idiom = 'ios-marketing'; size = '1024x1024'; scale = '1x'; filename = $animal + '.png' }
        $catalog = @{ info = @{ version = 1; author = 'xcode' }; images = $images }
        $catalog | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder 'Contents.json') -Encoding utf8NoBOM
    } finally { $source.Dispose() }
}
Write-Output 'Exported explicit notification, settings, Spotlight and launcher sizes for five animal icons'
