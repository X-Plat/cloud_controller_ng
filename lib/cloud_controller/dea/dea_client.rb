# Copyright (c) 2009-2012 VMware, Inc.

require "vcap/stager/client"
require "vcap/errors"

module VCAP::CloudController
  module DeaClient
    class FileUriResult < Struct.new(:file_uri_v1, :file_uri_v2, :credentials)
      def initialize(opts = {})
        if opts[:file_uri_v2]
          self.file_uri_v2 = opts[:file_uri_v2]
        end
        if opts[:file_uri_v1]
          self.file_uri_v1 = opts[:file_uri_v1]
        end
        if opts[:credentials]
          self.credentials = opts[:credentials]
        end
      end
    end

    class << self
      include VCAP::Errors

      attr_reader :config, :message_bus, :dea_pool, :info_hash

      def configure(config, message_bus, dea_pool)
        @config = config
        @message_bus = message_bus
        @dea_pool = dea_pool
        @info_hash={}
      end

      def run
        @dea_pool.register_subscriptions
      end

      def start(app, options={})
        instances_to_start = options[:instances_to_start] || app.instances
        start_instances_in_range(app, ((app.instances - instances_to_start)...app.instances))
        app.routes_changed = false
      end

      def stop(app)
        dea_publish_stop(:droplet => app.guid)
      end

      def change_running_instances(app, delta)
        if delta > 0
          range = (app.instances - delta...app.instances)
          start_instances_in_range(app, range)
        elsif delta < 0
          range = (app.instances...app.instances - delta)
          stop_indices_in_range(app, range)
        end
      end

      def find_specific_instance(app, options = {})
        message = { :droplet => app.guid }
        message.merge!(options)

        dea_request_find_droplet(message, :timeout => 2).first
      end

      def find_instances(app, message_options = {}, request_options = {})
        message = { :droplet => app.guid }
        message.merge!(message_options)

        request_options[:result_count] ||= app.instances
        request_options[:timeout] ||= 2

        dea_request_find_droplet(message, request_options)
      end

      def get_file_uri_for_instance(app, path, instance)
        if instance < 0 || instance >= app.instances
          msg = "Request failed for app: #{app.name}, instance: #{instance}"
          msg << " and path: #{path || '/'} as the instance is out of range."

          raise FileError.new(msg)
        end

        search_opts = {
          :indices => [instance],
          :version => app.version
        }

        result = get_file_uri(app, path, search_opts)
        unless result
          msg = "Request failed for app: #{app.name}, instance: #{instance}"
          msg << " and path: #{path || '/'} as the instance is not found."

          raise FileError.new(msg)
        end
        result
      end

      def get_file_uri_for_instance_id(app, path, instance_id)
        result = get_file_uri(app, path, :instance_ids => [instance_id])
        unless result
          msg = "Request failed for app: #{app.name}, instance_id: #{instance_id}"
          msg << " and path: #{path || '/'} as the instance_id is not found."

          raise FileError.new(msg)
        end
        result
      end

      def find_stats(app, opts = {})
        opts = { :allow_stopped_state => false }.merge(opts)

        if app.stopped?
          unless opts[:allow_stopped_state]
            msg = "Request failed for app: #{app.name}"
            msg << " as the app is in stopped state."

            raise StatsError.new(msg)
          end

          return {}
        end

        search_options = {
          :include_stats => true,
          :states => [:RUNNING],
          :version => app.version,
        }

        running_instances = find_instances(app, search_options)

        stats = {} # map of instance index to stats.
        running_instances.each do |instance|
          index = instance[:index]
          if index >= 0 && index < app.instances
            stats[index] = {
              :state => instance[:state],
              :stats => instance[:stats],
            }
          end
        end

        # we may not have received responses from all instances.
        app.instances.times do |index|
          unless stats[index]
            stats[index] = {
              :state => "DOWN",
              :since => Time.now.to_i,
            }
          end
        end

        stats
      end

      def find_all_instances(app)
        if app.stopped?
          msg = "Request failed for app: #{app.name}"
          msg << " as the app is in stopped state."

          raise InstancesError.new(msg)
        end

        num_instances = app.instances
        message = {
          :state => :FLAPPING,
          :version => app.version,
        }

        flapping_indices = HealthManagerClient.find_status(app, message)

        all_instances = {}
        if flapping_indices && flapping_indices[:indices]
          flapping_indices[:indices].each do |entry|
            index = entry[:index]
            if index >= 0 && index < num_instances
              all_instances[index] = {
                :state => "FLAPPING",
                :since => entry[:since],
              }
            end
          end
        end

        message = {
          :states => [:STARTING, :RUNNING],
          :version => app.version,
        }

        expected_running_instances = num_instances - all_instances.length
        if expected_running_instances > 0
          request_options = { :expected => expected_running_instances }
          running_instances = find_instances(app, message, request_options)

          running_instances.each do |instance|
            index = instance[:index]
            if index >= 0 && index < num_instances
              all_instances[index] = {
                :state => instance[:state],
                :since => instance[:state_timestamp],
                :debug_ip => instance[:debug_ip],
                :debug_port => instance[:debug_port],
                :console_ip => instance[:console_ip],
                :console_port => instance[:console_port]
              }
            end
          end
        end

        num_instances.times do |index|
          unless all_instances[index]
            all_instances[index] = {
              :state => "DOWN",
              :since => Time.now.to_i,
            }
          end
        end

        all_instances
      end

      # @param [Enumerable, #each] indices an Enumerable of indices / indexes
      def start_instances_with_message(app, indices, message_override = {})
        msg = start_app_message(app)
        indices.each do |idx|
          msg[:index] = idx
          dea_requirements = {
            :memory => app.memory,
            :stack => app.stack.name,
            :app_guid => app.guid
          }
          dea_requirements.merge!(:space_guid => app.space_guid) if config[:exclusive_deploy]
          dea_id = dea_pool.find_dea(dea_requirements)

          if dea_id
            dea_publish_start(dea_id, msg.merge(message_override))
            dea_pool.mark_app_started(dea_id: dea_id, app_id: app.guid, space_id: app.space_guid)
          else
            logger.error "no resources available #{msg}"
          end
        end
      end

      # @param [Array] indices an Enumerable of integer indices
      def stop_indices(app, indices)
        dea_publish_stop(:droplet => app.guid,
                    :version => app.version,
                    :indices => indices
                   )
      end

      # @param [Array] indices an Enumerable of guid instance ids
      def stop_instances(app, instances)
        dea_publish_stop(
                    :droplet => app.guid,
                    :instances => instances
                   )
      end

      def update_uris(app)
        return unless app.staged?
        message = dea_update_message(app)
        dea_publish_update(message)
        app.routes_changed = false
      end

      def app_bns_node(app)
        "#{app.space.organization.name}-#{app.space.name}-#{app.name}"  
      end

      def key_from_app(app, type)
        if type == :droplet
          File.join(key_from_guid(app.guid, type), app.droplet_hash)
        else
          key_from_guid(app.guid, type)
        end
      end

      def key_from_guid(guid, type)
        guid = guid.to_s.downcase
        if type == :buildpack_cache
          File.join("buildpack_cache", guid[0..1], guid[2..3], guid)
        else
          File.join(guid[0..1], guid[2..3], guid)
        end
      end
      def seed_start_to_serve(app) 
        begin
            torrent_dir=File.join(@config[:droplets][:fog_connection][:local_root],@config[:droplets][:seed_dir])
            torrent_file=File.join(torrent_dir,"#{app.guid}.torrent")
            unless File.exists?(torrent_file)
                raise Errno::ENOENT, "WARNING: seed start to serve failed: #{torrent_file} doesn't exist" 
            end
            unzip_dir=File.join(@config[:droplets][:fog_connection][:local_root],@config[:droplets][:unzipdroplet_directory_key],key_from_app(app,:other),"#{app.space.organization.name}_#{app.space.name}_#{app.name.split('_')[0]}")
            result=`gko3 add -n #{unzip_dir} -r #{torrent_file} -S -1 --seed`
            if $?.success?
                logger.info("Start to serve seed by gko3 for app:#{app.guid}")
                taskid=result.split("\n")[1].split(":")[1]
                infohash=`gko3 list|grep -P "^\s+#{taskid}\s+"|awk '{print $4}'`.to_s.chomp
                info_hash[app.guid]=infohash
                return infohash
            else
                raise SystemCallError,"ERROR: failed to serve as a seed: gko3 serve -p #{unzip_dir(app)} -r #{torrent_file} -S -1 --besthash"
            end
        rescue => e
            logger.warn("#{e}")
            return nil
        end
      end
      def app_infohash(app)
        if config[:droplets][:use_p2p]
            if info_hash[app.guid].nil?
                return seed_start_to_serve(app)
            else
                return app.infohash    
            end
        else
            return nil
        end
      end
      def start_app_message(app)
        # TODO: add debug support
        {
          :application_db_id => app.id,
          :droplet => app.guid,
          :tags => {
            :space => app.space_guid, 
            :bns_node => app_bns_node(app) ,
            :org_name => app.space.organization.name,
            :space_name => app.space.name
          },
          :name => app.name,
          :uris => app.uris,
          :prod => app.production,
          :sha1 => app.droplet_hash,
          :executableFile => "deprecated",
          :executableUri => Staging.droplet_download_uri(app),
          :version => app.version,
          :services => app.service_bindings.map do |sb|
            ServiceBindingPresenter.new(sb).to_hash
          end,
          :limits => {
            :mem => app.memory,
            :disk => app.disk_quota,
            :fds => app.file_descriptors
          },
          :cc_partition => config[:cc_partition],
          :env => (app.environment_json || {}).map {|k,v| "#{k}=#{v}"},
          :console => app.console,
          :debug => app.debug,
          :use_p2p => !app_infohash(app).nil?,
          :infohash => app_infohash(app),
        }
      end

      private

      # @param [Enumerable, #each] indices the range / sequence of instances to start
      def start_instances_in_range(app, indices)
        start_instances_with_message(app, indices)
      end

      # @param [Enumerable, #to_a] indices the range / sequence of instances to stop
      def stop_indices_in_range(app, indices)
        stop_indices(app, indices.to_a)
      end

      # @return [FileUriResult]
      def get_file_uri(app, path, options)
        if app.stopped?
          msg = "Request failed for app: #{app.name} path: #{path || '/'} "
          msg << "as the app is in stopped state."

          raise FileError.new(msg)
        end

        search_options = {
          :states => [:STARTING, :RUNNING, :CRASHED],
          :path => path,
        }.merge(options)

        if instance_found = find_specific_instance(app, search_options)
          result = FileUriResult.new
          if instance_found[:file_uri_v2]
            result.file_uri_v2 = instance_found[:file_uri_v2]
          end

          uri_v1 = [instance_found[:file_uri], instance_found[:staged], "/", path].join("")
          result.file_uri_v1 = uri_v1
          result.credentials = instance_found[:credentials]

          return result
        end

        nil
      end

      def dea_update_message(app)
        {
          :droplet  => app.guid,
          :uris     => app.uris,
        }
      end

      def dea_publish_stop(args)
        logger.debug "sending 'dea.stop' with '#{args}'"
        message_bus.publish("dea.stop", args)
      end

      def dea_publish_update(args)
        logger.debug "sending 'dea.update' with '#{args}'"
        message_bus.publish("dea.update", args)
      end

      def dea_publish_start(dea_id, args)
        logger.debug "sending 'dea.start' for dea_id: #{dea_id} with '#{args}'"
        message_bus.publish("dea.#{dea_id}.start", args)
      end

      def dea_request_find_droplet(args, opts = {})
        logger.debug "sending dea.find.droplet with args: '#{args}' and opts: '#{opts}'"
        message_bus.synchronous_request("dea.find.droplet", args, opts)
      end

      def logger
        @logger ||= Steno.logger("cc.dea.client")
      end
    end
  end
end
