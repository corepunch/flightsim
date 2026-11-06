require "json"
require "fileutils"
require "uri"

module Store
  ROOT = File.expand_path("..", __dir__)
  DIRECTORY = File.join(ROOT, "fastlane")
  PRIVATE = File.join(DIRECTORY, "private")
  METADATA = File.join(DIRECTORY, "metadata")
  SCREENSHOTS = File.join(DIRECTORY, "screenshots")
  BUNDLE_ID = "com.corepunch.spacefight"
  APP_ID = "6831063163"
  TEAM_ID = "BM2R8F5YHC"

  def self.version
    File.read(File.join(DIRECTORY, "version.txt")).strip
  end

  def self.credentials
    path = File.join(PRIVATE, "api_key.json")
    raise "Create fastlane/private/api_key.json; see Tools/APPSTORE.md." unless File.file?(path)
    data = JSON.parse(File.read(path))
    %w[key_id issuer_id key_filepath].each do |key|
      raise "Missing #{key} in fastlane/private/api_key.json." if data[key].to_s.strip.empty?
    end
    data["key_filepath"] = File.expand_path(data["key_filepath"], PRIVATE)
    raise "The configured .p8 key file does not exist." unless File.file?(data["key_filepath"])
    data
  end

  def self.review_information
    path = File.join(PRIVATE, "review_information.json")
    File.file?(path) ? JSON.parse(File.read(path), symbolize_names: true) : {}
  end

  def self.metadata_problems
    problems = []
    problems << "Set fastlane/version.txt to the App Store version." unless version.match?(/\A\d+(?:\.\d+){0,2}\z/)
    limits = { "name" => 30, "subtitle" => 30, "description" => 4000,
               "keywords" => 100, "promotional_text" => 170 }
    %w[name description support_url privacy_url].each do |field|
      path = File.join(METADATA, "en-US", "#{field}.txt")
      problems << "Fill fastlane/metadata/en-US/#{field}.txt." unless File.file?(path) && !File.read(path).strip.empty?
    end
    limits.each do |field, limit|
      path = File.join(METADATA, "en-US", "#{field}.txt")
      next unless File.file?(path)
      text = File.read(path).strip
      count = field == "keywords" ? text.bytesize : text.length
      problems << "#{field}.txt exceeds #{limit} #{field == 'keywords' ? 'bytes' : 'characters'}." if count > limit
    end
    %w[support_url privacy_url].each do |field|
      path = File.join(METADATA, "en-US", "#{field}.txt")
      next unless File.file?(path) && !File.read(path).strip.empty?
      url = URI.parse(File.read(path).strip) rescue nil
      problems << "#{field}.txt must contain a public HTTPS URL." unless url.is_a?(URI::HTTPS) && url.host
    end
    copyright = File.join(METADATA, "copyright.txt")
    problems << "Fill fastlane/metadata/copyright.txt." unless File.file?(copyright) && !File.read(copyright).strip.empty?
    problems
  end
end
