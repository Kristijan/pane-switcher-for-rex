cask "pane-switcher-for-rex" do
  version "1.0.0"
  sha256 "8992658558aa94115b35fd7da44cc7ad94105d28d8359ab4ba529c485f837417"

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
