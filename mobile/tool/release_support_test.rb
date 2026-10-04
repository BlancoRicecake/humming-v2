require "minitest/autorun"
require "tmpdir"
require_relative "release_support"

class ReleaseSupportTest < Minitest::Test
  FakeSubmission = Struct.new(:can_reject, :deleted) do
    def delete!
      self.deleted = true
      nil
    end
  end

  FakeVersion = Struct.new(:version_string, :app_version_state, :app_store_state, :app_store_version_submission) do
    def rejected = app_store_version_submission&.deleted
  end

  class FakeApp
    attr_reader :versions
    def initialize(versions, edit_versions)
      @versions, @edit_versions = versions, edit_versions
    end
    def get_app_store_versions(**) = @versions
    def get_edit_app_store_version(**) = @edit_versions.shift
  end

  def test_approved_version_is_cancelled_and_polled_until_editable
    target = FakeVersion.new("1.0.6", "PENDING_DEVELOPER_RELEASE", nil, FakeSubmission.new(nil, false))
    editable = FakeVersion.new("1.0.6", "DEVELOPER_REJECTED")
    waits = 0
    app = FakeApp.new([target], [nil, editable])
    HumTrackRelease.prepare_app_store_version!(app: app, version: "1.0.6", replace_pending: true, wait: -> { waits += 1 })
    assert target.rejected
    assert_equal 1, waits
  end

  def test_pending_version_is_unchanged_without_replace_permission
    target = FakeVersion.new("1.0.6", "PENDING_DEVELOPER_RELEASE", nil, FakeSubmission.new(nil, false))
    app = FakeApp.new([target], [])
    assert_raises(ArgumentError) { HumTrackRelease.prepare_app_store_version!(app: app, version: "1.0.6", replace_pending: false) }
    refute target.rejected
  end

  def test_other_versions_and_live_releases_are_never_cancelled
    other = FakeVersion.new("1.0.7", "PENDING_DEVELOPER_RELEASE", nil, FakeSubmission.new(nil, false))
    live = FakeVersion.new("1.0.6", "READY_FOR_DISTRIBUTION", nil, FakeSubmission.new(nil, false))
    app = FakeApp.new([other, live], [])
    assert_raises(ArgumentError) { HumTrackRelease.prepare_app_store_version!(app: app, version: "1.0.6", replace_pending: true) }
    refute other.rejected
    refute live.rejected
  end

  def test_cancellation_timeout_prevents_version_creation
    target = FakeVersion.new("1.0.6", "PENDING_DEVELOPER_RELEASE", nil, FakeSubmission.new(nil, false))
    app = FakeApp.new([target], [nil, nil])
    error = assert_raises(ArgumentError) { HumTrackRelease.prepare_app_store_version!(app: app, version: "1.0.6", replace_pending: true, attempts: 2, wait: -> {}) }
    assert_includes error.message, "retry submission without uploading another build"
  end

  def test_explicit_cancellation_denial_is_respected
    target = FakeVersion.new("1.0.6", "PENDING_DEVELOPER_RELEASE", nil, FakeSubmission.new(false, false))
    app = FakeApp.new([target], [])
    assert_raises(ArgumentError) { HumTrackRelease.prepare_app_store_version!(app: app, version: "1.0.6", replace_pending: true) }
    refute target.rejected
  end

  def configuration
    HumTrackRelease::DEFINE_KEYS.to_h { |key| [key, "value-#{key}"] }.merge(
      "APP_ENVIRONMENT" => "staging",
      "FIREBASE_ANALYTICS_ENABLED" => "false",
    )
  end

  def test_partial_environment_keeps_other_file_values_and_excludes_server_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env.secrets")
      File.write(path, configuration.map { |key, value| "#{key}='#{value}'" }.join("\n") + "\nSUPABASE_SERVICE_ROLE_KEY=never-compile-this")
      result = HumTrackRelease.defines(env: {"ENGINE_URL" => "https://example.test"}, secrets_path: path)
      assert_equal "https://example.test", result["ENGINE_URL"]
      assert_equal configuration["SUPABASE_ANON_KEY"], result["SUPABASE_ANON_KEY"]
      refute result.key?("SUPABASE_SERVICE_ROLE_KEY")
    end
  end

  def test_missing_release_settings_fail_before_build
    error = assert_raises(ArgumentError) { HumTrackRelease.defines(env: {"SUPABASE_URL" => "https://private.example"}, secrets_path: "/absent") }
    assert_includes error.message, "SUPABASE_ANON_KEY"
    refute_includes error.message, "https://private.example"
  end

  def test_optional_analytics_settings_do_not_block_existing_releases
    required = HumTrackRelease::REQUIRED_DEFINE_KEYS.to_h { |key| [key, "value-#{key}"] }
    result = HumTrackRelease.defines(env: required, secrets_path: "/absent")
    assert_equal required, result
    refute result.key?("FIREBASE_ANALYTICS_ENABLED")
  end

  def test_enabled_firebase_requires_complete_mobile_configuration
    values = configuration.merge("FIREBASE_ANALYTICS_ENABLED" => "true", "APP_ENVIRONMENT" => "staging")
    values.delete("FIREBASE_IOS_API_KEY")
    error = assert_raises(ArgumentError) do
      HumTrackRelease.defines(env: {"HUMTRACK_DART_DEFINES_JSON" => JSON.generate(values)}, secrets_path: "/absent")
    end
    assert_includes error.message, "FIREBASE_IOS_API_KEY"
    refute_includes error.message, values["FIREBASE_PROJECT_ID"]
  end

  def test_staging_firebase_accepts_complete_configuration_without_disclosure_gate
    values = configuration.merge("FIREBASE_ANALYTICS_ENABLED" => "true", "APP_ENVIRONMENT" => "staging")
    result = HumTrackRelease.defines(
      env: {"HUMTRACK_DART_DEFINES_JSON" => JSON.generate(values)},
      secrets_path: "/absent",
    )
    assert_equal "true", result["FIREBASE_ANALYTICS_ENABLED"]
  end

  def test_production_firebase_requires_explicit_disclosure_readiness
    values = configuration.merge("FIREBASE_ANALYTICS_ENABLED" => "true", "APP_ENVIRONMENT" => "production")
    json = JSON.generate(values)
    error = assert_raises(ArgumentError) do
      HumTrackRelease.defines(env: {"HUMTRACK_DART_DEFINES_JSON" => json}, secrets_path: "/absent")
    end
    assert_includes error.message, "HUMTRACK_FIREBASE_DISCLOSURES_READY=true"

    result = HumTrackRelease.defines(
      env: {
        "HUMTRACK_DART_DEFINES_JSON" => json,
        "HUMTRACK_FIREBASE_DISCLOSURES_READY" => "true",
      },
      secrets_path: "/absent",
    )
    assert_equal "production", result["APP_ENVIRONMENT"]
  end

  def test_invalid_firebase_enable_flag_is_rejected
    values = configuration.merge("FIREBASE_ANALYTICS_ENABLED" => "yes")
    assert_raises(ArgumentError) do
      HumTrackRelease.defines(env: {"HUMTRACK_DART_DEFINES_JSON" => JSON.generate(values)}, secrets_path: "/absent")
    end
  end

  def test_json_configuration_filters_keys_and_shell_metacharacters_are_data
    values = configuration.merge("SENTRY_DSN_MOBILE" => "value with spaces & $(touch nope)", "SERVER_SECRET" => "private")
    result = HumTrackRelease.defines(env: {"HUMTRACK_DART_DEFINES_JSON" => JSON.generate(values)}, secrets_path: "/absent")
    refute result.key?("SERVER_SECRET")
    path = nil
    HumTrackRelease.with_defines(result) do |file|
      path = file
      assert_equal values["SENTRY_DSN_MOBILE"], JSON.parse(File.read(file))["SENTRY_DSN_MOBILE"]
    end
    refute File.exist?(path)
  end

  def test_invalid_json_values_are_rejected
    values = configuration.merge("GOOGLE_WEB_CLIENT_ID" => false)
    assert_raises(ArgumentError) { HumTrackRelease.defines(env: {"HUMTRACK_DART_DEFINES_JSON" => JSON.generate(values)}, secrets_path: "/absent") }
  end

  def test_version_is_stable_across_working_directories_and_rejects_invalid_override
    expected = HumTrackRelease.version(env: {})
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { assert_equal expected, HumTrackRelease.version(env: {}) }
    end
    assert_equal ["1.0.6", 33], HumTrackRelease.version(env: {"HUMTRACK_VERSION" => "1.0.6", "HUMTRACK_BUILD_NUMBER" => "33"})
    assert_raises(ArgumentError) { HumTrackRelease.version(env: {"HUMTRACK_BUILD_NUMBER" => "33; command"}) }
  end

  def write_plist(dir, entries)
    body = entries.map { |k, v| "<key>#{k}</key>\n<string>#{v}</string>" }.join("\n")
    path = File.join(dir, "GoogleService-Info.plist")
    File.write(path, "<plist version=\"1.0\"><dict>\n#{body}\n</dict></plist>")
    path
  end

  def complete_plist
    {
      "API_KEY" => "AIzaTest", "GCM_SENDER_ID" => "123", "PROJECT_ID" => "humtrack-test",
      "GOOGLE_APP_ID" => "1:123:ios:abc123", "BUNDLE_ID" => "com.humtrack.app",
      "CLIENT_ID" => "123-x.apps.googleusercontent.com",
      "REVERSED_CLIENT_ID" => "com.googleusercontent.apps.123-x", "PLIST_VERSION" => "1",
    }
  end

  def test_google_plist_accepts_merged_firebase_and_sign_in_keys
    Dir.mktmpdir do |dir|
      HumTrackRelease.require_google_plist!(path: write_plist(dir, complete_plist))
    end
  end

  def test_google_plist_rejects_sign_in_only_file
    Dir.mktmpdir do |dir|
      sign_in_only = complete_plist.slice("BUNDLE_ID", "CLIENT_ID", "REVERSED_CLIENT_ID", "PLIST_VERSION")
      error = assert_raises(ArgumentError) do
        HumTrackRelease.require_google_plist!(path: write_plist(dir, sign_in_only))
      end
      assert_includes error.message, "GOOGLE_APP_ID"
    end
  end

  def test_google_plist_rejects_firebase_only_file
    Dir.mktmpdir do |dir|
      firebase_only = complete_plist.reject { |k, _| %w[CLIENT_ID REVERSED_CLIENT_ID].include?(k) }
      error = assert_raises(ArgumentError) do
        HumTrackRelease.require_google_plist!(path: write_plist(dir, firebase_only))
      end
      assert_includes error.message, "CLIENT_ID"
    end
  end

  def test_google_plist_rejects_android_app_id_and_wrong_bundle
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) do
        HumTrackRelease.require_google_plist!(path: write_plist(dir, complete_plist.merge("GOOGLE_APP_ID" => "1:123:android:abc123")))
      end
      assert_raises(ArgumentError) do
        HumTrackRelease.require_google_plist!(path: write_plist(dir, complete_plist.merge("BUNDLE_ID" => "com.other.app")))
      end
      assert_raises(ArgumentError) do
        HumTrackRelease.require_google_plist!(path: File.join(dir, "missing.plist"))
      end
    end
  end
end
