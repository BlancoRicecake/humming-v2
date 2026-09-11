require "json"
require "tempfile"

# Shared by both fastlane entry points. Paths never depend on fastlane's cwd.
module HumTrackRelease
  MOBILE = File.expand_path("..", __dir__)
  ROOT = File.dirname(MOBILE)
  DEFINE_KEYS = %w[SUPABASE_URL SUPABASE_ANON_KEY GOOGLE_WEB_CLIENT_ID ENGINE_URL CLARITY_PROJECT_ID SENTRY_DSN_MOBILE].freeze

  def self.defines(env: ENV, secrets_path: File.join(ROOT, "backend/.env.secrets"))
    values = {}
    if File.file?(secrets_path)
      File.foreach(secrets_path) do |line|
        key, value = line.strip.split("=", 2)
        next unless DEFINE_KEYS.include?(key) && value && !value.empty?
        value = value[1...-1] if value.length >= 2 && ["\"", "'"].include?(value[0]) && value[-1] == value[0]
        values[key] = value
      end
    end
    unless env.fetch("HUMTRACK_DART_DEFINES_JSON", "").empty?
      parsed = JSON.parse(env.fetch("HUMTRACK_DART_DEFINES_JSON"))
      raise ArgumentError, "HUMTRACK_DART_DEFINES_JSON must be an object" unless parsed.is_a?(Hash)
      DEFINE_KEYS.each { |key| values[key] = parsed[key] if parsed.key?(key) }
    end
    DEFINE_KEYS.each do |key|
      value = env[key]
      values[key] = value unless value.nil? || value.empty?
    end
    missing = DEFINE_KEYS.reject { |key| values[key].is_a?(String) && !values[key].strip.empty? }
    raise ArgumentError, "Missing release configuration: #{missing.join(', ')}" unless missing.empty?
    values
  end

  def self.version(env: ENV, pubspec_path: File.join(MOBILE, "pubspec.yaml"))
    match = File.read(pubspec_path).match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/)
    raise ArgumentError, "pubspec.yaml must contain version: x.y.z+N" unless match
    name = env.fetch("HUMTRACK_VERSION", "").empty? ? match[1] : env.fetch("HUMTRACK_VERSION")
    number = env.fetch("HUMTRACK_BUILD_NUMBER", "").empty? ? match[2] : env.fetch("HUMTRACK_BUILD_NUMBER")
    raise ArgumentError, "Invalid release version" unless name.match?(/\A\d+\.\d+\.\d+\z/)
    raise ArgumentError, "Invalid release build number" unless number.match?(/\A[1-9]\d*\z/)
    [name, number.to_i]
  end

  def self.with_defines(values)
    Tempfile.create(["humtrack-defines-", ".json"]) do |file|
      file.write(JSON.generate(values))
      file.flush
      yield file.path
    end
  end

  def self.require_google_plist!
    path = File.join(MOBILE, "ios/Runner/GoogleService-Info.plist")
    raise ArgumentError, "Missing production GoogleService-Info.plist" unless File.file?(path)
    contents = File.read(path)
    if contents.include?("CI_COMPILE_ONLY") || !contents.include?("CLIENT_ID")
      raise ArgumentError, "A production GoogleService-Info.plist is required for distribution"
    end
  end

  def self.require_android_signing!
    path = File.join(MOBILE, "android/key.properties")
    raise ArgumentError, "Missing Android release key.properties; refusing debug-signed distribution" unless File.file?(path)
    properties = File.readlines(path).filter_map do |line|
      key, value = line.strip.split("=", 2)
      [key, value] if key && value
    end.to_h
    missing = %w[storeFile storePassword keyAlias keyPassword].reject { |key| properties[key] && !properties[key].empty? }
    raise ArgumentError, "Missing Android signing properties: #{missing.join(', ')}" unless missing.empty?
    store = File.expand_path(properties.fetch("storeFile"), File.join(MOBILE, "android/app"))
    raise ArgumentError, "Android release keystore does not exist" unless File.file?(store)
  end
end
