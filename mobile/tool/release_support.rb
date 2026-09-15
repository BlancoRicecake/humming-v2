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

  # Deliver checks/creates the version before its reject_if_possible hook.
  # An approved, unreleased version must become editable before that check.
  def self.prepare_app_store_version!(app:, version:, replace_pending:, attempts: 20, wait: -> { sleep(15) })
    versions = app.get_app_store_versions(filter: {platform: "IOS"}, includes: "appStoreVersionSubmission")
    target = versions.find { |item| item.version_string == version }
    return if target.nil?

    state = target.app_version_state || target.app_store_state
    editable = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY]
    return if editable.include?(state)

    pending = %w[PENDING_APPLE_RELEASE PENDING_DEVELOPER_RELEASE IN_REVIEW WAITING_FOR_REVIEW]
    raise ArgumentError, "App Store version #{version} cannot be replaced in state #{state}" unless pending.include?(state)
    raise ArgumentError, "Replacing App Store version #{version} requires HUMTRACK_REPLACE_PENDING_RELEASE=true" unless replace_pending
    submission = target.app_store_version_submission
    raise ArgumentError, "App Store version #{version} has no cancellable submission" unless submission
    raise ArgumentError, "Apple disallows cancellation for version #{version}" if submission.can_reject == false
    # Public API responses can omit canReject. Fastlane's reject! treats nil as
    # false, although the official DELETE endpoint accepts this pending version.
    # The endpoint raises on rejection; a successful 204 can have no return value.
    submission.delete!

    attempts.times do |index|
      current = app.get_edit_app_store_version(platform: "IOS")
      return if current && current.version_string == version && editable.include?(current.app_version_state || current.app_store_state)
      wait.call if index < attempts - 1
    end
    raise ArgumentError, "Apple has not made version #{version} editable yet; retry submission without uploading another build"
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
