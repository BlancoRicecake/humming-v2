require "json"
require "net/http"
require "tempfile"
require "time"
require "uri"

# Shared by both fastlane entry points. Paths never depend on fastlane's cwd.
module HumTrackRelease
  MOBILE = File.expand_path("..", __dir__)
  ROOT = File.dirname(MOBILE)
  REQUIRED_DEFINE_KEYS = %w[
    SUPABASE_URL SUPABASE_ANON_KEY GOOGLE_WEB_CLIENT_ID ENGINE_URL
    CLARITY_PROJECT_ID SENTRY_DSN_MOBILE
  ].freeze
  # SENTRY_ENVIRONMENT (2026-11-04): explicit only. Absent, a release build
  # reports as "production" (the app's default). Set "internal" only for an
  # Android internal build that will never be promoted — an iOS TestFlight
  # build is the binary App Store review gets, and a Play internal AAB can be
  # promoted.
  # HUMTRACK_CLOUD_BACKUP (2026-11-04): "false" or absent = cloud off. "true"
  # builds only through validate_cloud! — the live server, an operator's
  # attestation and a fresh provider-contract receipt must all agree.
  OPTIONAL_DEFINE_KEYS = %w[
    SENTRY_ENVIRONMENT HUMTRACK_CLOUD_BACKUP
    APP_ENVIRONMENT FIREBASE_ANALYTICS_ENABLED FIREBASE_PROJECT_ID
    FIREBASE_MESSAGING_SENDER_ID FIREBASE_MEASUREMENT_ID
    FIREBASE_ANDROID_APP_ID FIREBASE_ANDROID_API_KEY
    FIREBASE_IOS_APP_ID FIREBASE_IOS_API_KEY
  ].freeze
  DEFINE_KEYS = (REQUIRED_DEFINE_KEYS + OPTIONAL_DEFINE_KEYS).freeze
  SENTRY_ENVIRONMENTS = %w[production internal staging].freeze
  CLOUD_RECEIPT_MAX_AGE = 14 * 24 * 60 * 60 # seconds
  CLOUD_RECEIPT_KIND = "humtrack-cloud-provider-receipt"
  FIREBASE_REQUIRED_DEFINE_KEYS = %w[
    APP_ENVIRONMENT FIREBASE_PROJECT_ID FIREBASE_MESSAGING_SENDER_ID
    FIREBASE_ANDROID_APP_ID FIREBASE_ANDROID_API_KEY
    FIREBASE_IOS_APP_ID FIREBASE_IOS_API_KEY
  ].freeze

  def self.defines(env: ENV, secrets_path: File.join(ROOT, "backend/.env.secrets"),
                   probe: method(:fetch_json), now: Time.now)
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
    missing = REQUIRED_DEFINE_KEYS.reject { |key| values[key].is_a?(String) && !values[key].strip.empty? }
    raise ArgumentError, "Missing release configuration: #{missing.join(', ')}" unless missing.empty?
    sentry = values["SENTRY_ENVIRONMENT"]
    if sentry && !SENTRY_ENVIRONMENTS.include?(sentry)
      raise ArgumentError, "SENTRY_ENVIRONMENT must be one of #{SENTRY_ENVIRONMENTS.join(', ')}"
    end
    validate_firebase_analytics!(values, env: env)
    validate_cloud!(values, env: env, probe: probe, now: now)
    values
  end

  # A cloud-ON build must point at a server that is really ready, checked now:
  #  1. HUMTRACK_CLOUD_SERVICE_VERIFIED = this build's ENGINE_URL host — the
  #     operator's statement that the customer checks passed for that server
  #     (OPS-REQUIREMENTS §5); never stored in Git.
  #  2. HUMTRACK_CLOUD_PROVIDER_RECEIPT = path to the JSON printed by
  #     `python -m app.cloud_provider_check --apply`: passed, cleanup
  #     confirmed, same host, at most 14 days old.
  #  3. GET {ENGINE_URL}/health/cloud (no token): ready (feature + writes +
  #     cleanup worker on, R2 set, migrations 006/008 answering, worker
  #     healthy), contract 1, and the SAME backend version the receipt tested.
  # Any doubt refuses the build; nothing here is logged beyond the host.
  def self.validate_cloud!(values, env: ENV, probe: method(:fetch_json), now: Time.now)
    flag = values["HUMTRACK_CLOUD_BACKUP"]
    return if flag.nil? || flag == "false"
    raise ArgumentError, "HUMTRACK_CLOUD_BACKUP must be true or false" unless flag == "true"

    engine = URI.parse(values.fetch("ENGINE_URL").to_s)
    unless engine.is_a?(URI::HTTPS) && engine.host && engine.userinfo.nil?
      raise ArgumentError, "Cloud backup needs an https ENGINE_URL"
    end
    host = engine.host
    if env["HUMTRACK_CLOUD_SERVICE_VERIFIED"] != host
      raise ArgumentError, "Cloud backup needs HUMTRACK_CLOUD_SERVICE_VERIFIED=#{host} " \
                           "after the live customer checks for that server"
    end

    path = env["HUMTRACK_CLOUD_PROVIDER_RECEIPT"].to_s
    raise ArgumentError, "Cloud backup needs HUMTRACK_CLOUD_PROVIDER_RECEIPT (provider check JSON)" if path.empty?
    receipt = begin
      JSON.parse(File.read(path))
    rescue StandardError
      raise ArgumentError, "Cloud provider receipt is unreadable"
    end
    checked = begin
      Time.iso8601(receipt["checked_at"].to_s)
    rescue StandardError
      nil
    end
    unless receipt.is_a?(Hash) && receipt["kind"] == CLOUD_RECEIPT_KIND && receipt["passed"] == true &&
           receipt["cleanup_confirmed"] == true && receipt["api_host"] == host && checked &&
           checked <= now + 300 && now - checked <= CLOUD_RECEIPT_MAX_AGE &&
           receipt["server_version"].is_a?(String) && !receipt["server_version"].empty?
      raise ArgumentError, "Cloud provider receipt must be a passed, cleaned-up check of #{host} " \
                           "from the last 14 days"
    end

    readiness = begin
      probe.call(URI.join("#{engine}/", "health/cloud").to_s)
    rescue StandardError
      nil
    end
    unless readiness.is_a?(Hash) && readiness["ready"] == true && readiness["contract"] == 1
      raise ArgumentError, "Cloud backup server #{host} is not ready (/health/cloud)"
    end
    if readiness["version"] != receipt["server_version"]
      raise ArgumentError, "The provider receipt tested another backend version than #{host} runs now"
    end
  end

  # GET a small public JSON document (no credentials, short timeouts).
  def self.fetch_json(url)
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: 10, read_timeout: 10) do |http|
      response = http.get(uri.request_uri, "Accept" => "application/json")
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end
  end

  def self.validate_firebase_analytics!(values, env: ENV)
    flag = values["FIREBASE_ANALYTICS_ENABLED"]
    return if flag.nil? || flag == "false"
    raise ArgumentError, "FIREBASE_ANALYTICS_ENABLED must be true or false" unless flag == "true"

    missing = FIREBASE_REQUIRED_DEFINE_KEYS.reject do |key|
      values[key].is_a?(String) && !values[key].strip.empty?
    end
    unless missing.empty?
      raise ArgumentError, "Incomplete Firebase Analytics configuration: #{missing.join(', ')}"
    end

    environment = values.fetch("APP_ENVIRONMENT")
    unless %w[production staging].include?(environment)
      raise ArgumentError, "APP_ENVIRONMENT must be production or staging when Firebase Analytics is enabled"
    end
    if environment == "production" && env["HUMTRACK_FIREBASE_DISCLOSURES_READY"] != "true"
      raise ArgumentError, "Production Firebase Analytics requires HUMTRACK_FIREBASE_DISCLOSURES_READY=true"
    end
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

  # Mac distribution channels. StoreKit only works in the Mac App Store build;
  # the direct-download build is its own flavor (bundle id + OAuth scheme) so
  # its PKCE callback never lands in the App Store app on the same Mac.
  # Every value is set explicitly so neither build inherits the other's.
  MAC_CHANNELS = {
    "app-store" => {store_flag: "true", scheme: "humtrack", bundle_id: "com.humtrack.app", flavor: nil},
    "direct" => {store_flag: "false", scheme: "humtrack-direct", bundle_id: "com.humtrack.app.direct", flavor: "direct"},
  }.freeze
  MAC_CHANNEL_MARKER = "humtrack-mac-channel:"

  def self.mac_channel(channel)
    MAC_CHANNELS.fetch(channel) do
      raise ArgumentError, "Unknown Mac channel #{channel.inspect}; use #{MAC_CHANNELS.keys.join(' or ')}"
    end
  end

  def self.mac_defines(channel, values)
    c = mac_channel(channel)
    values.merge("HUMTRACK_MAC_APP_STORE" => c[:store_flag], "HUMTRACK_AUTH_SCHEME" => c[:scheme])
  end

  # `flutter build macos` arguments selecting the channel's Xcode flavor.
  def self.mac_flavor_args(channel)
    flavor = mac_channel(channel)[:flavor]
    flavor ? ["--flavor", flavor] : []
  end

  def self.mac_app_path(channel, build_root: File.join(MOBILE, "build/macos/Build/Products"))
    flavor = mac_channel(channel)[:flavor]
    File.join(build_root, flavor ? "Release-#{flavor}" : "Release", "HumTrack.app")
  end

  # The built app must match the channel everywhere: the compiled channel
  # marker and OAuth callback URL in the Flutter App binary, and the bundle id
  # and registered URL scheme in Info.plist.
  def self.verify_mac_channel!(app_path, channel, plist_reader: method(:read_plist_json))
    c = mac_channel(channel)
    binary = File.join(app_path, "Contents/Frameworks/App.framework/Versions/A/App")
    raise ArgumentError, "Flutter App binary missing: #{binary}" unless File.file?(binary)
    data = File.binread(binary)
    found = MAC_CHANNELS.keys.select { |k| data.include?("#{MAC_CHANNEL_MARKER}#{k}") }
    raise ArgumentError, "Mac build channel is #{found.inspect}, expected #{channel.inspect}" unless found == [channel]
    callbacks = MAC_CHANNELS.values.map { |v| "#{v[:scheme]}://auth/callback" }.select { |u| data.include?(u) }
    expected = "#{c[:scheme]}://auth/callback"
    raise ArgumentError, "OAuth callback in binary is #{callbacks.inspect}, expected #{expected.inspect}" unless callbacks == [expected]
    info = plist_reader.call(File.join(app_path, "Contents/Info.plist"))
    raise ArgumentError, "Bundle id is #{info["CFBundleIdentifier"].inspect}, expected #{c[:bundle_id]}" unless info["CFBundleIdentifier"] == c[:bundle_id]
    schemes = Array(info["CFBundleURLTypes"]).flat_map { |t| Array(t["CFBundleURLSchemes"]) }
    raise ArgumentError, "URL schemes are #{schemes.inspect}, expected [#{c[:scheme]}]" unless schemes == [c[:scheme]]
  end

  def self.read_plist_json(path)
    raise ArgumentError, "Info.plist missing: #{path}" unless File.file?(path)
    out = IO.popen(["plutil", "-convert", "json", "-o", "-", path], &:read)
    raise ArgumentError, "Unreadable Info.plist: #{path}" unless $?.success?
    JSON.parse(out)
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

  # firebase_core auto-runs FirebaseApp.configure() at plugin registration
  # whenever this plist exists, so a Sign-In-only plist (no GOOGLE_APP_ID)
  # aborts every launch before Dart starts (iOS 1.0.9 build 38 incident).
  # The file must carry both the Firebase app keys and the Google Sign-In keys.
  IOS_BUNDLE_ID = "com.humtrack.app"
  GOOGLE_PLIST_REQUIRED_KEYS = %w[
    GOOGLE_APP_ID API_KEY GCM_SENDER_ID PROJECT_ID BUNDLE_ID CLIENT_ID REVERSED_CLIENT_ID
  ].freeze

  def self.require_google_plist!(path: File.join(MOBILE, "ios/Runner/GoogleService-Info.plist"))
    raise ArgumentError, "Missing production GoogleService-Info.plist" unless File.file?(path)
    contents = File.read(path)
    if contents.include?("CI_COMPILE_ONLY")
      raise ArgumentError, "A production GoogleService-Info.plist is required for distribution"
    end
    values = contents.scan(%r{<key>([^<]+)</key>\s*<string>([^<]*)</string>}).to_h
    missing = GOOGLE_PLIST_REQUIRED_KEYS.reject { |key| values[key].to_s.strip != "" }
    unless missing.empty?
      raise ArgumentError, "GoogleService-Info.plist is missing: #{missing.join(', ')}"
    end
    unless values["GOOGLE_APP_ID"].match?(/\A1:\d+:ios:[0-9a-f]+\z/)
      raise ArgumentError, "GoogleService-Info.plist GOOGLE_APP_ID is not an iOS Firebase app ID"
    end
    unless values["BUNDLE_ID"] == IOS_BUNDLE_ID
      raise ArgumentError, "GoogleService-Info.plist BUNDLE_ID does not match #{IOS_BUNDLE_ID}"
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
