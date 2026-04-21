on run argv
    with timeout of 120 seconds
        tell application "Google Chrome"
            activate

            set targetWindowFound to false

            repeat with w in windows
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    try
                        set tabUrl to URL of t
                    on error
                        set tabUrl to ""
                    end try

                    if tabUrl does not contain "ui.vision.html" then
                        set active tab index of w to tabIndex
                        set index of w to 1
                        set targetWindowFound to true
                        exit repeat
                    end if
                end repeat

                if targetWindowFound then exit repeat
            end repeat
        end tell
    end timeout
end run
