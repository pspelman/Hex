cask "hex" do
  version "0.8.0"
  sha256 :no_check  # Will be filled after first release

  url "https://github.com/pspelman/Hex/releases/download/v#{version}/Hex-#{version}.zip"
  name "Hex"
  desc "On-device voice-to-text for macOS"
  homepage "https://github.com/pspelman/Hex"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Hex.app"

  zap trash: [
    "~/Library/Application Support/com.pspelman.Hex",
    "~/Library/Caches/com.pspelman.Hex",
    "~/Library/Containers/com.pspelman.Hex",
    "~/Library/Preferences/com.pspelman.Hex.plist",
  ]
end
