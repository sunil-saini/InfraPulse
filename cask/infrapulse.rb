cask "infrapulse" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/sunil-saini/homebrew-tools/releases/download/v#{version}/InfraPulse-#{version}.zip"
  name "InfraPulse"
  desc "Native macOS monitor for cloud and infrastructure connectivity"
  homepage "https://github.com/sunil-saini/homebrew-tools"

  depends_on macos: :ventura
  depends_on formula: "awscli"

  app "InfraPulse.app"

  preflight do
    system_command "/bin/sh", args: ["-c", <<~EOS]
      /bin/launchctl bootout gui/#{Process.uid}/com.infrapulse >/dev/null 2>&1 || true
      /bin/launchctl bootout gui/#{Process.uid}/com.opstools.infrapulse >/dev/null 2>&1 || true
      lock="#{Dir.home}/Library/Application Support/InfraPulse/infrapulse.lock"
      pid=$(/bin/cat "$lock" 2>/dev/null || true)
      case "$pid" in
        ''|*[!0-9]*) ;;
        *)
          # Only the flock is dropped on exit, so a stale pid may be recycled.
          if /bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/grep -q 'InfraPulse$'; then
            /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
            /bin/sleep 2
            /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
          fi
          ;;
      esac
      # An interrupted upgrade leaves an empty app Homebrew refuses to replace.
      # rmdir only succeeds when it is empty, so a real install is untouched.
      /bin/rmdir "#{appdir}/InfraPulse.app" >/dev/null 2>&1 || true
    EOS
  end

  uninstall_preflight do
    system_command "/bin/sh", args: ["-c", <<~EOS]
      /bin/launchctl bootout gui/#{Process.uid}/com.infrapulse >/dev/null 2>&1 || true
      /bin/launchctl bootout gui/#{Process.uid}/com.opstools.infrapulse >/dev/null 2>&1 || true
      # Never bootout com.infrapulse.updater here: on an in-app upgrade that job
      # is the one running brew, and this stanza runs from the installed cask.
      /bin/rm -f "#{Dir.home}/Library/LaunchAgents/com.infrapulse.plist"
      /bin/rm -f "#{Dir.home}/Library/LaunchAgents/com.infrapulse.updater.plist"
    EOS
  end

  # This is an internal-team cask. The app is currently unsigned, so remove
  # the download quarantine attribute after copying it to /Applications.
  postflight do
    system_command "/bin/mkdir", args: ["-p", "#{Dir.home}/Library/LaunchAgents"]
    system_command "/usr/bin/install", args: [
      "-m", "644", "#{staged_path}/com.infrapulse.plist",
      "#{Dir.home}/Library/LaunchAgents/com.infrapulse.plist",
    ]
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/InfraPulse.app"]
    system_command "/bin/launchctl", args: ["bootstrap", "gui/#{Process.uid}", "#{Dir.home}/Library/LaunchAgents/com.infrapulse.plist"]
  end

  caveats <<~EOS
    InfraPulse is installed in /Applications and runs as a menu-bar app.
    It starts automatically at login and monitors the default AWS profile.
  EOS

  # Preferences land under the bundle identifier and the app name, plus the
  # debug build's own; listing only the identifier leaves the rest behind.
  zap trash: [
    "~/Library/Caches/com.infrapulse",
    "~/Library/Caches/com.infrapulse.debug",
    "~/Library/Caches/com.opstools.infrapulse",
    "~/Library/Caches/com.opstools.infrapulse.debug",
    "~/Library/LaunchAgents/com.infrapulse.plist",
    "~/Library/LaunchAgents/com.infrapulse.updater.plist",
    "~/Library/LaunchAgents/com.opstools.infrapulse.plist",
    "~/Library/Application Support/InfraPulse",
    "~/Library/Logs/InfraPulse",
    "~/Library/Preferences/InfraPulse.plist",
    "~/Library/Preferences/com.infrapulse.plist",
    "~/Library/Preferences/com.infrapulse.debug.plist",
    "~/Library/Preferences/com.opstools.infrapulse.plist",
  ]
end
