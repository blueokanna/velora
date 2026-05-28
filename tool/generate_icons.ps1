param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$light = Join-Path $Root 'assets\light.png'
$dark = Join-Path $Root 'assets\dark.png'

function Ensure-Directory([string]$Path) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
}

function Resize-Png([string]$Source, [string]$Target, [int]$Width, [int]$Height = $Width) {
  Ensure-Directory $Target
  $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $sourceBitmap = [System.Drawing.Image]::FromFile($Source)
  try {
    $graphics.DrawImage($sourceBitmap, 0, 0, $Width, $Height)
    $bitmap.Save($Target, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $sourceBitmap.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

function Write-Ico([string]$Source, [string]$Target, [int]$Size = 256) {
  $tempPng = Join-Path ([System.IO.Path]::GetTempPath()) (([System.Guid]::NewGuid().ToString()) + '.png')
  Resize-Png $Source $tempPng $Size
  try {
    $pngBytes = [System.IO.File]::ReadAllBytes($tempPng)
    Ensure-Directory $Target
    $stream = [System.IO.File]::Open($Target, [System.IO.FileMode]::Create)
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
      $dimension = if ($Size -ge 256) { 0 } else { $Size }
      $writer.Write([UInt16]0)
      $writer.Write([UInt16]1)
      $writer.Write([UInt16]1)
      $writer.Write([byte]$dimension)
      $writer.Write([byte]$dimension)
      $writer.Write([byte]0)
      $writer.Write([byte]0)
      $writer.Write([UInt16]1)
      $writer.Write([UInt16]32)
      $writer.Write([UInt32]$pngBytes.Length)
      $writer.Write([UInt32]22)
      $writer.Write($pngBytes)
    } finally {
      $writer.Dispose()
      $stream.Dispose()
    }
  } finally {
    Remove-Item $tempPng -Force -ErrorAction SilentlyContinue
  }
}

$android = @{
  'android\app\src\main\res\mipmap-mdpi\ic_launcher.png' = 48
  'android\app\src\main\res\mipmap-mdpi\ic_launcher_round.png' = 48
  'android\app\src\main\res\mipmap-hdpi\ic_launcher.png' = 72
  'android\app\src\main\res\mipmap-hdpi\ic_launcher_round.png' = 72
  'android\app\src\main\res\mipmap-xhdpi\ic_launcher.png' = 96
  'android\app\src\main\res\mipmap-xhdpi\ic_launcher_round.png' = 96
  'android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png' = 144
  'android\app\src\main\res\mipmap-xxhdpi\ic_launcher_round.png' = 144
  'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png' = 192
  'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher_round.png' = 192
  'android\app\src\main\res\drawable\ic_launcher_foreground.png' = 432
}

foreach ($entry in $android.GetEnumerator()) {
  Resize-Png $light (Join-Path $Root $entry.Key) $entry.Value
}

Resize-Png $dark (Join-Path $Root 'android\app\src\main\res\drawable\ic_launcher_monochrome.png') 432

$ios = @{
  'Icon-App-20x20@1x.png' = 20
  'Icon-App-20x20@2x.png' = 40
  'Icon-App-20x20@3x.png' = 60
  'Icon-App-29x29@1x.png' = 29
  'Icon-App-29x29@2x.png' = 58
  'Icon-App-29x29@3x.png' = 87
  'Icon-App-40x40@1x.png' = 40
  'Icon-App-40x40@2x.png' = 80
  'Icon-App-40x40@3x.png' = 120
  'Icon-App-60x60@2x.png' = 120
  'Icon-App-60x60@3x.png' = 180
  'Icon-App-76x76@1x.png' = 76
  'Icon-App-76x76@2x.png' = 152
  'Icon-App-83.5x83.5@2x.png' = 167
  'Icon-App-1024x1024@1x.png' = 1024
}

foreach ($entry in $ios.GetEnumerator()) {
  Resize-Png $light (Join-Path $Root ('ios\Runner\Assets.xcassets\AppIcon.appiconset\' + $entry.Key)) $entry.Value
}

$macos = @{
  'app_icon_16.png' = 16
  'app_icon_32.png' = 32
  'app_icon_64.png' = 64
  'app_icon_128.png' = 128
  'app_icon_256.png' = 256
  'app_icon_512.png' = 512
  'app_icon_1024.png' = 1024
}

foreach ($entry in $macos.GetEnumerator()) {
  Resize-Png $light (Join-Path $Root ('macos\Runner\Assets.xcassets\AppIcon.appiconset\' + $entry.Key)) $entry.Value
}

$web = @{
  'web\favicon.png' = 64
  'web\icons\Icon-192.png' = 192
  'web\icons\Icon-512.png' = 512
  'web\icons\Icon-maskable-192.png' = 192
  'web\icons\Icon-maskable-512.png' = 512
  'web\favicon-dark.png' = 64
  'linux\icon.png' = 512
}

foreach ($entry in $web.GetEnumerator()) {
  $source = if ($entry.Key -eq 'web\favicon-dark.png') { $dark } else { $light }
  Resize-Png $source (Join-Path $Root $entry.Key) $entry.Value
}

Write-Ico $light (Join-Path $Root 'windows\runner\resources\app_icon.ico') 256
Write-Ico $dark (Join-Path $Root 'windows\runner\resources\app_icon_dark.ico') 256

Write-Host 'Velora icons generated successfully.'