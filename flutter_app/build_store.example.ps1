# Baytak AR - store build script (PowerShell).
#
# WHY: pasting long keys into one giant command line is how keys pick up
# line breaks and silently corrupt the build (observed live: a wrapped
# anon-key paste made every AI call fail). Here every value sits on its
# own line, and the script trims whitespace defensively.
#
# SETUP: copy this file to build_store.ps1 (which is gitignored), fill in
# the four values, then run:   .\build_store.ps1
# Add -Install to also install to the connected phone.

param([switch]$Install)

# ---- fill these in --------------------------------------------------------
$SUPABASE_URL      = "https://YOUR-REF.supabase.co"
$SUPABASE_ANON_KEY = "eyJ...paste the anon key here..."
$AI_PROXY_URL      = "https://YOUR-REF.supabase.co/functions/v1/ai-proxy"
$LICENSE_KEY       = "bk-your-store-2026-xxxx"
# ---------------------------------------------------------------------------

# strip any whitespace/newlines a paste may have introduced
$SUPABASE_URL      = ($SUPABASE_URL      -replace '\s','')
$SUPABASE_ANON_KEY = ($SUPABASE_ANON_KEY -replace '\s','')
$AI_PROXY_URL      = ($AI_PROXY_URL      -replace '\s','')
$LICENSE_KEY       = ($LICENSE_KEY       -replace '\s','')

Write-Host "Building with proxy $AI_PROXY_URL (license $LICENSE_KEY)..."
flutter build apk `
  --dart-define=SUPABASE_URL=$SUPABASE_URL `
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY `
  --dart-define=AI_PROXY_URL=$AI_PROXY_URL `
  --dart-define=LICENSE_KEY=$LICENSE_KEY

if ($LASTEXITCODE -eq 0 -and $Install) {
  flutter install
}
