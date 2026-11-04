# Builds the link-preview pages for shared cards: c/<slug>/index.html carries
# the Open Graph tags chat apps read (they never run the site's JavaScript)
# and sends people on to #/card/<slug>; c/img/<slug>.jpg is the 1200x630
# preview picture. Run it again whenever cards are added or renamed:
#   powershell -ExecutionPolicy Bypass -File tools\card-pages.ps1
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
$root = Split-Path $PSScriptRoot -Parent
$site = "https://seekers-league.com"
$src = [IO.File]::ReadAllText("$root\index.html")

function Slug([string]$n) {
  $t = $n.ToLower().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
  ($t -replace "['’]", '' -replace '[^a-z0-9]+', '-').Trim('-')
}
function Esc([string]$t) { [Net.WebUtility]::HtmlEncode($t) }

$TN = @{ U = "Unit"; G = "Legacy"; S = "Spell"; A = "Attachment"; T = "Terrain" }
$FN = @{ C = "Conclave"; O = "Order"; L = "Legion"; P = "Primal" }
$kwList = [regex]::Match($src, 'const CARD_KW="([^"]*)"').Groups[1].Value.Split('~')
$ex = @{}
foreach ($m in [regex]::Matches([regex]::Match($src, 'const CARD_EX=\{.*?\};').Value, '"([^"]+)":"([^"]*)"')) { $ex[$m.Groups[1].Value] = $m.Groups[2].Value }
$cardsJs = [regex]::Match($src, 'const CARDS=(\[\{.*?\}\])[,;]').Groups[1].Value
$cards = ($cardsJs -replace '([{,])(n|t|f|tr|r|e|kw):', '$1"$2":') | ConvertFrom-Json

New-Item -ItemType Directory -Force "$root\c\img" | Out-Null
$bg = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.Color]::FromRgb(0x22, 0x1a, 0x1c)), ([Windows.Media.Color]::FromRgb(0x10, 0x10, 0x10)), 0
$bone = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xec, 0xe6, 0xda))
$dim = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xa8, 0xa2, 0x96))
$brass = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xc8, 0xa5, 0x68))
$blue = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x7c, 0xb4, 0xe4))
$crim = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xe5, 0x1e, 0x39))
$tfBold = New-Object Windows.Media.Typeface "Segoe UI Semibold"
$tf = New-Object Windows.Media.Typeface "Segoe UI"
function Txt($dc, [string]$t, $face, [double]$size, $brush, [double]$x, [double]$y, [double]$w) {
  $ft = New-Object Windows.Media.FormattedText ($t, [Globalization.CultureInfo]::InvariantCulture, [Windows.FlowDirection]::LeftToRight, $face, $size, $brush, 1.0)
  $ft.MaxTextWidth = $w; $ft.Trimming = [Windows.TextTrimming]::CharacterEllipsis
  $dc.DrawText($ft, (New-Object Windows.Point $x, $y)); return $ft.Height
}

$n = 0
foreach ($c in $cards) {
  $slug = Slug $c.n
  $img = "$root\cards\$slug.webp"
  if (-not (Test-Path $img)) { Write-Warning "no image: $($c.n)"; continue }
  $p = if ($ex.ContainsKey($c.n)) { $ex[$c.n].Split('|') } else { @() }
  $kw = if ($p.Count -gt 2 -and $p[2]) { $p[2].Split('.') | ForEach-Object { $kwList[[int]$_] } } else { @($c.kw) | Where-Object { $_ } }
  $fac = if ($c.f) { ($c.f.ToCharArray() | ForEach-Object { $FN["$_"] }) -join "–" } else { "Neutral" }
  $type = (@($TN[$c.t]) + @($c.tr | Where-Object { $_ })) -join " · "
  $desc = "$type · $fac" + $(if ($kw) { ". " + ($kw -join ", ") } else { "" }) + ". Malediction card on Seekers League."

  # preview picture: the card on the left, its name and lines on the right
  $dec = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$img, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
  $bmp = $dec.Frames[0]
  $land = $bmp.PixelWidth -gt $bmp.PixelHeight
  if ($land) { $w = 600; $h = $w * $bmp.PixelHeight / $bmp.PixelWidth } else { $h = 570; $w = $h * $bmp.PixelWidth / $bmp.PixelHeight }
  $ix = 50; $iy = (630 - $h) / 2
  $dv = New-Object Windows.Media.DrawingVisual
  $dc = $dv.RenderOpen()
  $dc.DrawRectangle($bg, $null, (New-Object Windows.Rect 0, 0, 1200, 630))
  $dc.DrawRectangle($crim, $null, (New-Object Windows.Rect 0, 0, 1200, 6))
  $dc.DrawRoundedRectangle([Windows.Media.Brushes]::Black, $null, (New-Object Windows.Rect ($ix + 6), ($iy + 8), $w, $h), 14, 14)
  $dc.PushClip((New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect $ix, $iy, $w, $h), 12, 12))
  $dc.DrawImage($bmp, (New-Object Windows.Rect $ix, $iy, $w, $h))
  $dc.Pop()
  $tx = $ix + $w + 50; $tw = 1200 - $tx - 50; $y = 120
  $y += Txt $dc "SEEKERS LEAGUE" $tfBold 22 $brass $tx $y $tw
  $y += 14
  $y += Txt $dc $c.n $tfBold 56 $bone $tx $y $tw
  $y += 14
  $y += Txt $dc $type $tf 28 $dim $tx $y $tw
  $y += 8
  $y += Txt $dc $fac $tf 28 $brass $tx $y $tw
  if ($kw) { $y += 14; [void](Txt $dc ($kw -join " · ") $tf 26 $blue $tx $y $tw) }
  [void](Txt $dc "seekers-league.com" $tf 22 $dim $tx 560 $tw)
  $dc.Close()
  $rt = New-Object Windows.Media.Imaging.RenderTargetBitmap 1200, 630, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
  $rt.Render($dv)
  $enc = New-Object Windows.Media.Imaging.JpegBitmapEncoder
  $enc.QualityLevel = 82
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rt))
  $fs = [IO.File]::Create("$root\c\img\$slug.jpg"); $enc.Save($fs); $fs.Close()

  $t = Esc $c.n; $d = Esc $desc
  $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$t · Seekers League</title>
<meta name="description" content="$d">
<meta property="og:type" content="website"><meta property="og:site_name" content="Seekers League">
<meta property="og:title" content="$t"><meta property="og:description" content="$d">
<meta property="og:url" content="$site/c/$slug/">
<meta property="og:image" content="$site/c/img/$slug.jpg"><meta property="og:image:type" content="image/jpeg">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:alt" content="$t card">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:image" content="$site/c/img/$slug.jpg">
<link rel="canonical" href="$site/c/$slug/">
<meta http-equiv="refresh" content="0;url=../../#/card/$slug">
<script>location.replace("../../#/card/$slug")</script>
</head><body style="background:#141414;color:#ece6da;font-family:system-ui,sans-serif;padding:24px">
<p><a style="color:#c8a568" href="../../#/card/$slug">Open $t on Seekers League</a></p>
</body></html>
"@
  New-Item -ItemType Directory -Force "$root\c\$slug" | Out-Null
  [IO.File]::WriteAllText("$root\c\$slug\index.html", $html, (New-Object Text.UTF8Encoding $false))
  $n++
}
"$n card pages written"
