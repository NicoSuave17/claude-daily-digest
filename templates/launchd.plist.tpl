<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>__LABEL__</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-l</string>
        <string>__INSTALL_DIR__/bin/daily-review.sh</string>
    </array>

    <!-- Fire every day at 9:03am local time. Minute is 3 (not 0) to
         avoid the global fleet pile-up on the top of the hour. -->
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>3</integer>
    </dict>

    <!-- Do NOT fire on launchctl load. We only want scheduled + catch-up fires. -->
    <key>RunAtLoad</key>
    <false/>

    <!-- launchd runs this job as soon as the Mac wakes up if the 9:03
         slot was missed while the machine was asleep. Native behavior. -->

    <!-- 15 minute wall clock limit. -->
    <key>ExitTimeOut</key>
    <integer>900</integer>

    <!-- Environment: inherit PATH so `claude` and helpers resolve. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>__BREW_PREFIX__/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>__HOME__</string>
    </dict>

    <!-- launchd's own stdout/stderr. The script handles its own dated logs. -->
    <key>StandardOutPath</key>
    <string>__INSTALL_DIR__/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>__INSTALL_DIR__/logs/launchd.err.log</string>

    <key>WorkingDirectory</key>
    <string>__HOME__</string>

    <!-- Don't restart on failure. -->
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
