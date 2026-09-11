require "minitest/autorun"
require "tmpdir"
require_relative "release_support"

class ReleaseSupportTest < Minitest::Test
  def configuration
    HumTrackRelease::DEFINE_KEYS.to_h { |key| [key, "value-#{key}"] }
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
end
