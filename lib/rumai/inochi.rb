module Rumai

  INSTDIR = File.expand_path('../../..', __FILE__)

  # load inochi configuration
  inochi_file = __FILE__.sub(/rb$/, 'yaml')
  begin

    configs = File.open(inochi_file) do |f|
      require 'yaml'
      YAML.load_stream(f).documents
    end

    INOCHI = configs.shift.to_hash
    INOCHI[:runtime] ||= {}
    INOCHI[:devtime] ||= {}

    INOCHI2 = (configs.shift || {}).to_hash

  rescue => error
    error.message.insert 0,
      "Could not load Inochi configuration file: #{inochi_file.inspect}\n"
    raise error
  end

  # make values available as constants
  INOCHI.each do |param, value|
    const_set param.to_s.upcase, value
  end

  def self.inspect
    "#{PROJECT} #{VERSION} (#{RELEASE})"
  end

  # establish gem version dependencies
  if respond_to? :gem
    [:runtime, :devtime].each do |key|
      INOCHI[key].each do |gem_name, gem_version|
        begin
          gem gem_name, *Array(gem_version)
        rescue LoadError => error
          warn "#{inspect} #{key}: #{error}"
        end
      end
    end
  end

end
