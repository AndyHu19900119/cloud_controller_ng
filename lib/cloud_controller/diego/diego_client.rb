module VCAP::CloudController::Diego
  class DesireAppMessage < JsonMessage
    required :process_guid, String
    required :memory_mb, Integer
    required :disk_mb, Integer
    required :file_descriptors, Integer
    required :droplet_uri, String
    required :stack, String
    required :start_command, String
    required :environment, [{
      name: String,
      value: String,
    }]
    required :num_instances, Integer
    required :routes, [String]
    optional :health_check_timeout_in_seconds, Integer
    required :log_guid, String
  end

  class DesireDockerAppMessage < JsonMessage
    required :process_guid, String
    required :memory_mb, Integer
    required :disk_mb, Integer
    required :file_descriptors, Integer
    required :docker_image, String
    required :stack, String
    required :start_command, String
    required :environment, [{
                                name: String,
                                value: String,
                            }]
    required :num_instances, Integer
    required :routes, [String]
    optional :health_check_timeout_in_seconds, Integer
    required :log_guid, String
  end

  class DiegoUnavailable < RuntimeError
    def initialize(exception = nil)
      @wrapped_exception = exception
    end

    def to_s
      message = "Diego runtime is unavailable."
      message << " Error: #{@wrapped_exception}" if @wrapped_exception
      message
    end
  end

  class DiegoClient
    def initialize(enabled, message_bus, service_registry, blobstore_url_generator)
      @enabled = enabled
      @message_bus = message_bus
      @service_registry = service_registry
      @blobstore_url_generator = blobstore_url_generator
      @buildpack_entry_generator = BuildpackEntryGenerator.new(@blobstore_url_generator)
    end

    def connect!
      @service_registry.run!
    end

    def running_enabled(app)
      @enabled && (app.environment_json || {})["CF_DIEGO_RUN_BETA"] == "true"
    end

    def staging_enabled(app)
      return false unless @enabled
      running_enabled(app) || ((app.environment_json || {})["CF_DIEGO_BETA"] == "true")
    end

    def staging_needed(app)
      staging_enabled(app) && (app.uploaded_and_needs_staging? || app.detected_start_command.empty?)
    end

    def send_desire_request(app)
      logger.info("desire.app.begin", :app_guid => app.guid)
      @message_bus.publish("diego.desire.app", desire_request(app).encode)
    end

    def send_docker_desire_request(app)
      logger.info("desire.docker.app.begin", :app_guid => app.guid)
      @message_bus.publish("diego.docker.desire.app", desire_docker_request(app).encode)
    end

    def send_stage_request(app, staging_task_id)
      app.update(staging_task_id: staging_task_id)

      logger.info("staging.begin", :app_guid => app.guid)

      @message_bus.publish("diego.staging.start", staging_request(app))
    end

    def docker_staging_needed?(app)
      docker_staging_enabled?(app) && (app.has_docker_image? && app.needs_staging?)
    end

    def stage_app_on_diego_docker(app)
      @message_bus.publish("diego.docker.staging.start", docker_staging_request(app))
    end

    def desire_request(app)
      request = {
          process_guid: lrp_guid(app),
          memory_mb: app.memory,
          disk_mb: app.disk_quota,
          file_descriptors: app.file_descriptors,
          droplet_uri: @blobstore_url_generator.perma_droplet_download_url(app.guid),
          stack: app.stack.name,
          start_command: app.detected_start_command,
          environment: environment(app),
          num_instances: desired_instances(app),
          routes: app.uris,
          log_guid: app.guid,
      }

      if app.health_check_timeout
        request[:health_check_timeout_in_seconds] =
            app.health_check_timeout
      end

      DesireAppMessage.new(request)
    end

    def desire_docker_request(app)
      request = {
          process_guid: lrp_guid(app),
          memory_mb: app.memory,
          disk_mb: app.disk_quota,
          file_descriptors: app.file_descriptors,
          docker_image: app.docker_image,
          stack: app.stack.name,
          start_command: app.detected_start_command,
          environment: environment(app),
          num_instances: desired_instances(app),
          routes: app.uris,
          log_guid: app.guid,
      }

      if app.health_check_timeout
        request[:health_check_timeout_in_seconds] =
            app.health_check_timeout
      end

      DesireDockerAppMessage.new(request)
    end

    def desired_instances(app)
      app.started? ? app.instances : 0
    end

    def docker_staging_request(app)
      {
          :app_id => app.guid,
          :task_id => app.staging_task_id,
          :memory_mb => app.memory,
          :disk_mb => app.disk_quota,
          :file_descriptors => app.file_descriptors,
          :environment => environment(app),
          :stack => app.stack.name,
          :docker_image => app.docker_image,
      }
    end

    def staging_request(app)
      {
        :app_id => app.guid,
        :task_id => app.staging_task_id,
        :memory_mb => app.memory,
        :disk_mb => app.disk_quota,
        :file_descriptors => app.file_descriptors,
        :environment => environment(app),
        :stack => app.stack.name,
        :build_artifacts_cache_download_uri => @blobstore_url_generator.buildpack_cache_download_url(app),
        :app_bits_download_uri => @blobstore_url_generator.app_package_download_url(app),
        :buildpacks => @buildpack_entry_generator.buildpack_entries(app)
      }
    end

    def lrp_instances(app)
      if @service_registry.tps_addrs.empty?
        raise DiegoUnavailable
      end

      address = @service_registry.tps_addrs.first
      guid    = lrp_guid(app)

      uri = URI("#{address}/lrps/#{guid}")
      logger.info "Requesting lrp information for #{guid} from #{address}"

      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 10
      http.open_timeout = 10

      body = http.get(uri.path).body
      logger.info "Received lrp response for #{guid}: #{body}"

      result = []

      tps_instances = JSON.parse(body)
      tps_instances.each do |instance|
        result << {
          process_guid:  instance['process_guid'],
          instance_guid: instance['instance_guid'],
          index:         instance['index'],
          state:         instance['state'].upcase,
          since:         instance['since_in_ns'].to_i / 1_000_000_000,
        }
      end

      logger.info "Returning lrp instances for #{guid}: #{result.inspect}"

      result
    rescue Errno::ECONNREFUSED => e
      raise DiegoUnavailable.new(e)
    end

    def environment(app)
      env = []
      env << {name: "VCAP_APPLICATION", value: app.vcap_application.to_json}
      env << {name: "VCAP_SERVICES", value: app.system_env_json["VCAP_SERVICES"].to_json}
      db_uri = app.database_uri
      env << {name: "DATABASE_URL", value: db_uri} if db_uri
      env << {name: "MEMORY_LIMIT", value: "#{app.memory}m"}
      app_env_json = app.environment_json || {}
      app_env_json.each { |k, v| env << {name: k, value: v} }
      env
    end

    def logger
      @logger ||= Steno.logger("cc.diego_client")
    end

    def lrp_guid(app)
      "#{app.guid}-#{app.version}"
    end
  end
end
