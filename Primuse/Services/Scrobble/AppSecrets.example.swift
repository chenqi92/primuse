/*
 Last.fm defaults are configured through Config/Secrets.local.xcconfig.

 1. Copy Config/Secrets.local.xcconfig.example to Config/Secrets.local.xcconfig.
 2. Fill LASTFM_API_KEY and LASTFM_API_SECRET with values from
    https://www.last.fm/api/account/create.
 3. Keep Secrets.local.xcconfig out of git.

 Leave both values empty to require users to paste their own Last.fm API key
 and shared secret in Settings. Do not place real secrets in tracked Swift
 source files.
 */
