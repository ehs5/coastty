cask "coastty" do
  version "0.1.0"
  sha256 "1946def3c9275dcdee606b922f695ec9c5ca2df068b986f4b2a9457b90884fce"

  url "https://github.com/ehs5/coastty/releases/download/v#{version}/Coastty.dmg"
  name "Coastty"
  desc "Terminal emulator with agent detection, Spaces and sessions that outlive the app"
  homepage "https://github.com/ehs5/coastty"

  depends_on macos: :ventura

  app "Coastty.app"
  binary "#{appdir}/Coastty.app/Contents/MacOS/coastty"

  zap trash: [
    "~/.config/coastty",
    "~/.local/state/coastty-host",
    "~/Library/Caches/com.espensteen.coastty",
    "~/Library/HTTPStorages/com.espensteen.coastty",
    "~/Library/Preferences/com.espensteen.coastty.plist",
    "~/Library/Saved Application State/com.espensteen.coastty.savedState",
  ]
end
