# Encoding: utf-8
# IBM WebSphere Application Server Liberty Buildpack
# Copyright 2013-2015 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'fileutils'
require 'liberty_buildpack'
require 'liberty_buildpack/buildpack_version'
require 'liberty_buildpack/container/common_paths'
require 'liberty_buildpack/util/configuration_utils'
require 'liberty_buildpack/util/constantize'
require 'liberty_buildpack/util/heroku'
require 'liberty_buildpack/diagnostics/logger_factory'
require 'liberty_buildpack/diagnostics/common'
require 'pathname'
require 'time'
require 'yaml'

module LibertyBuildpack

  # Encapsulates the detection, compile, and release functionality for Java application
  class Buildpack

    # +Buildpack+ driver method. Creates a logger and yields a new instance of +Buildpack+
    # to the given block catching any exceptions and logging diagnostics. As part of initialisation,
    # all of the files located in the following directories are +require+d:
    # * +lib/liberty_buildpack/container+
    # * +lib/liberty_buildpack/jre+
    # * +lib/liberty_buildpack/framework+
    #
    # @param [String] app_dir the path of the application directory
    # @param [String] message an error message with an insert for the reason for failure
    # @return [Object] the return value from the given block
    def self.drive_buildpack_with_logger(app_dir, message)
      logger = LibertyBuildpack::Diagnostics::LoggerFactory.create_logger app_dir
      begin
        yield new(app_dir)
      rescue => e
        logger.error(message % e.inspect)
        logger.debug("Exception #{e.inspect} backtrace:\n#{e.backtrace.join("\n")}")
        abort e.message
      end
    end

	def self.createMappings(tenantId, serviceId)
     begin
      file = File.open("/tmp/staged/app/#{tenantId}.war/WEB-INF/ibm-web-bnd.xml", "w")
      file.write("<web-bnd
        xmlns=\"http://websphere.ibm.com/xml/ns/javaee\"
        xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"
        xsi:schemaLocation=\"http://websphere.ibm.com/xml/ns/javaee
                        http://websphere.ibm.com/xml/ns/javaee/ibm-web-bnd_1_0.xsd\"
        version=\"1.0\">
    <virtual-host name=\"default_host\"/>
    <resource-ref name=\"jdbc/JNDItest\" binding-name=\"jdbc/#{serviceId}\"/>
    
    </web-bnd>") 
    rescue IOError => e
      #some error occur, dir not writable etc.
    ensure
      file.close unless file == nil 
    end
   end

   def self.saasify
      is_mt_app = ENV["IS_MT_APP"]
      service_mappings = "{\"Tenant1\":\"Service1\",\"Tenant2\":\"Service2\"}"
      tenant_Ids = "{\"1\":\"Tenant1\",\"2\":\"Tenant2\"}"
      parsed_service_mappings = JSON.parse(ENV["SERVICE_MAPPINGS"])	
      parsed_tenant_ids = JSON.parse(ENV["TENANT_IDS"])      

      if is_mt_app["yes"] 
	 Dir.mkdir '/tmp/staged/Tenant.war'
	 FileUtils.cp_r '/tmp/staged/app/.', '/tmp/staged/Tenant.war'
	 FileUtils.rm_rf(Dir.glob("/tmp/staged/app/*")) 
	 no_tenants = ENV["NO_TENANTS"].to_i
	 for i in 1..no_tenants
	  FileUtils.cp_r "/tmp/staged/Tenant.war", "/tmp/staged/app/Tenant#{i}.war"
	  Buildpack.createMappings(parsed_tenant_ids["#{i}"], parsed_service_mappings[parsed_tenant_ids["#{i}"]]) 
	 end
	 FileUtils.rm_rf('/tmp/staged/Tenant.war')
	 Dir.mkdir '/tmp/staged/app/META-INF'
      end
    end
	
    # Iterates over all of the components to detect if this buildpack can be used to run an application
    #
    # @return [Array<String>] An array of strings that identify the components and versions that will be used to run
    #                         this application.  If no container can run the application, the array will be empty
    #                         (+[]+).
    def detect
      # jre detections performed during initialization of components
      framework_detections = Buildpack.component_detections @frameworks
      container_detections = Buildpack.component_detections @containers
      raise "Application can not be run by more than one container: #{container_detections.join(', ')}" if container_detections.size > 1
      tags = container_detections.empty? ? [] : container_detections.concat([@jre_version]).concat(framework_detections).flatten.compact
      tags
    end

    # Transforms the application directory such that the JRE, container, and frameworks can run the application
    #
    # @return [void]
    def compile
      # Report buildpack build version
      puts BUILDPACK_MESSAGE % @buildpack_version
      @logger.debug { 'Liberty Buildpack starting compile' }

      the_container = container # diagnose detect failure early
      FileUtils.mkdir_p @lib_directory
	  
	  Buildpack.saasify

      @jre.compile
      frameworks.each { |framework| framework.compile }
      the_container.compile
      puts '-----> Liberty buildpack is done creating the droplet'
      @logger.debug { 'Liberty Buildpack compile complete' }
    end

    # Generates the payload required to run the application.  The payload format is defined by the
    # {Heroku Buildpack API}[https://devcenter.heroku.com/articles/buildpack-api#buildpack-api].
    #
    # @return [String] The payload required to run the application.
    def release
      @logger.debug { 'Liberty Buildpack starting release' }
      the_container = container # diagnose detect failure early
      @jre.release
      frameworks.each { |framework| framework.release }
      command = the_container.release

      payload = {
          'addons' => [],
          'config_vars' => {},
          'default_process_types' => {
              'web' => command
          }
      }.to_yaml

      @logger.debug { "Liberty Buildpack release complete. Release Payload #{payload}" }
      payload
    end

    private_class_method :new

    private

    LICENSE_CONFIG = '../../config/licenses.yml'.freeze
    BUILDPACK_MESSAGE = '-----> Liberty Buildpack Version: %s'.freeze

    JRE_TYPE = 'jres'.freeze
    FRAMEWORK_TYPE = 'frameworks'.freeze
    CONTAINER_TYPE = 'containers'.freeze

    LIB_DIRECTORY = '.lib'

    # Instances should only be constructed by this class.
    def initialize(app_dir)
      @logger = LibertyBuildpack::Diagnostics::LoggerFactory.get_logger
      @buildpack_version = BuildpackVersion.new
      Buildpack.log_debug_data @logger
      Buildpack.require_component_files
      components = LibertyBuildpack::Util::ConfigurationUtils.load('components')

      @lib_directory = Buildpack.lib_directory app_dir
      @common_paths = LibertyBuildpack::Container::CommonPaths.new
      environment = ENV.to_hash
      vcap_application = environment.delete 'VCAP_APPLICATION'
      vcap_services = environment.delete 'VCAP_SERVICES'
      license_ids = get_license_hash
      jvm_type = environment['JVM']

      basic_context = {
          app_dir: app_dir,
          environment: environment,
          java_home: '',
          java_opts: [],
          lib_directory: @lib_directory,
          common_paths: @common_paths,
          vcap_application: vcap_application ? YAML.load(vcap_application) : {},
          vcap_services: vcap_services ? YAML.load(vcap_services) : {},
          license_ids: license_ids ? license_ids : {},
          jvm_type: jvm_type
      }
      initialize_components(components, basic_context)
    end

    def self.component_detections(components)
      compacted_tags = components.map { |component| component.detect }.compact
      compacted_tags.select { |tag| tag != '' }
    end

    def self.configure_context(basic_context, type)
      component_id = type.match(/^(?:.*::)?(.*)$/)[1].downcase
      configured_context = basic_context.clone
      configured_context[:configuration] = LibertyBuildpack::Util::ConfigurationUtils.load(component_id)
      configured_context
    end

    def self.construct_components(components, type, basic_context)
      components[type].map do |component|
        component.constantize.new(Buildpack.configure_context(basic_context, component))
      end
    end

    def self.container_directory
      Pathname.new(File.expand_path('container', File.dirname(__FILE__)))
    end

    def self.framework_directory
      Pathname.new(File.expand_path('framework', File.dirname(__FILE__)))
    end

    def self.git_dir
      File.expand_path('../../.git', File.dirname(__FILE__))
    end

    def self.jre_directory
      Pathname.new(File.expand_path('jre', File.dirname(__FILE__)))
    end

    def self.log_debug_data(logger)
      logger.debug do
        safe_env = ENV.to_hash
        if safe_env.has_key? 'VCAP_SERVICES'
          safe_env.merge!({ 'VCAP_SERVICES' => LibertyBuildpack::Util.safe_vcap_services(safe_env['VCAP_SERVICES']) })
        end
        if LibertyBuildpack::Util::Heroku.heroku?
          LibertyBuildpack::Util.safe_heroku_env!(safe_env)
        end
        "Environment Variables: #{safe_env}"
      end

      # Log information about the buildpack's git repository to enable stale forks to be spotted.
      # Call the debug method passing a parameter rather than a block so that, should the git command
      # become inaccessible to the buildpack at some point in the future, we find out before someone
      # happens to switch on debug logging.
      if system("git --git-dir=#{git_dir} status 2>/dev/null 1>/dev/null")
        logger.debug("git remotes: #{`git --git-dir=#{git_dir} remote -v`}")
        logger.debug("git HEAD commit: #{`git --git-dir=#{git_dir} log HEAD^! --`}")
      else
        logger.debug('Buildpack is not stored in a git repository')
      end
    end

    def self.lib_directory(app_dir)
      File.join app_dir, LIB_DIRECTORY
    end

    def self.require_component_files
      component_files = jre_directory.children
      component_files.concat framework_directory.children
      component_files.concat container_directory.children

      component_files.each do |file|
        require file.relative_path_from(root_directory) unless file.directory?
      end
    end

    def self.root_directory
      Pathname.new(File.expand_path('..', File.dirname(__FILE__)))
    end

    def container
      found_container = @containers.find { |container| container.detect }
      raise 'No supported application type was detected' unless found_container
      found_container
    end

    def frameworks
      @frameworks.select { |framework| framework.detect }
    end

    def get_license_hash
      jvm_license = 'IBM_JVM_LICENSE'
      liberty_license = 'IBM_LIBERTY_LICENSE'

      license_file = File.expand_path(LICENSE_CONFIG, File.dirname(__FILE__))
      if File.exists? license_file
        license_ids = YAML.load_file(license_file)
      else
        license_ids = { jvm_license => ENV[jvm_license], liberty_license => ENV[liberty_license] }
      end
      license_ids
    end

    def initialize_components(components, basic_context)
      # raise an error when the components.yml file doesn't have at least one Container
      raise "No components of type #{CONTAINER_TYPE} defined in components configuration. At least one must be defined" if components[CONTAINER_TYPE].nil?

      # raise an error when the components.yml doesn't have at least one JRE
      raise "No components of type #{JRE_TYPE} defined in components configuration.  At least one must be defined" if components[JRE_TYPE].nil?

      # finds the first jre component and its version that doesn't return false.  Just need one jre component.
      jres = Buildpack.construct_components(components, JRE_TYPE, basic_context)
      @jre = jres.find { |jre| @jre_version = jre.detect }
      @logger.error("JRE component did not detect a valid version. It's possible that the JVM environment variable needs to be set or its value needs to be corrected.") if @jre.nil?

      @frameworks = Buildpack.construct_components(components, FRAMEWORK_TYPE, basic_context)
      @containers = Buildpack.construct_components(components, CONTAINER_TYPE, basic_context)
    end

    def self.initialize_env(dir)
      blacklist = %w(PATH GIT_DIR CPATH CPPATH LD_PRELOAD LIBRARY_PATH)
      if Dir.exists?(dir)
        Dir.foreach(dir) do |name|
          file = File.join(dir, name)
          if File.file?(file) && !blacklist.include?(name)
            value = File.read(file).strip
            ENV[name] = value
          end
        end
      end
    end

  end

end
