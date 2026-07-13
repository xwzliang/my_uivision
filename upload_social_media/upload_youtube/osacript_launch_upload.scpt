with timeout of 120 seconds
    -- 1) bring Terminal to the front (will launch it if it’s not running)
    tell application "Terminal" to activate
    -- 2) give it a beat so it can spin up fully
    delay 2
    -- 3) run your upload script in a new window/tab
    tell application "Terminal"
        do script "/Users/broliang/git/my_n8n/uivision/upload_youtube.sh"
    end tell
end timeout