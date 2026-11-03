cask "pane-switcher-for-rex" do
  version "1.0.1"
  sha256 "aca3329ef3b53370aa22109acac80bac76f451e7418976498458f0e1befff465"

  url "https://github.com/Kristijan/pane-switcher-for-rex/releases/download/v#{version}/Pane-Switcher-for-Rex-#{version}-arm64.zip"
  name "Pane Switcher for Rex"
  desc "Native pane picker for Rex"
  homepage "https://github.com/Kristijan/pane-switcher-for-rex"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Pane Switcher for Rex.app"

  uninstall quit: "com.kristijan.paneswitch"

  zap launchctl: "com.kristijan.paneswitch",
      trash: [
        "~/Library/Application Support/Pane Switcher for Rex",
        "~/Library/Preferences/com.kristijan.paneswitch.plist",
        "~/Library/Saved Application State/com.kristijan.paneswitch.savedState",
      ]
end
