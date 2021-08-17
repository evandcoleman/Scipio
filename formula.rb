class Scipio < Formula
  desc "Scipio: A cache tool for Swift Package Manager"
  homepage "https://github.com/evandcoleman/Scipio"
  url ""
  sha256 ""
  head "https://github.com/evandcoleman/Scipio.git", :branch => "main"

  def install
    system "swift build --disable-sandbox -c release"
    bin.install ".build/release/scipio"
  end
end