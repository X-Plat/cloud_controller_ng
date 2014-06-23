# Copyright (c) 2009-2012 VMware, Inc.

require "vcap/stager/client"

module VCAP::CloudController
  class DeaPool
    ADVERTISEMENT_EXPIRATION = 10

    def initialize(message_bus, exclusive=nil, matrix_based=false)
      @message_bus = message_bus
      @dea_advertisements = []
      @dea_ips = {}
      @exclusive = exclusive ||=  false
      @matrix_based = matrix_based
    end

    def register_subscriptions
      p @matrix_based
      if @matrix_based
        message_bus.subscribe("matrix.resource.status") do |msg|
          process_advertise_message(msg)
        end
        message_bus.subscribe("dea.advertise") do |msg|
          process_advertise_message_v3(msg)
        end
      else      
        message_bus.subscribe("dea.advertise") do |msg|
          process_advertise_message(msg)
        end
      end
      message_bus.subscribe("dea.shutdown") do |msg|
        process_shutdown_message(msg)
      end
    end

    def process_advertise_message_v3(msg)
       advertisement = DeaAdvertisement.new(msg)
       @dea_ips[advertisement.dea_ip] = advertisement.dea_id if advertisement.dea_ip
    end

    def process_advertise_message(message)
      mutex.synchronize do
        advertisement = DeaAdvertisement.new(message)
        advertisement.dea_id= @dea_ips[advertisement.dea_ip]
        #remove_advertisement_for_id(advertisement.dea_id)
        remove_advertisement_for_ip(advertisement.dea_ip)
        @dea_advertisements << advertisement
        if @exclusive && advertisement.is_hybrid? 
           logger.warn "Hybrid dea node #{advertisement.dea_id} found. You could \
                        disable the exclusive_deploy configure to eliminate this warning. "
        end
      end
    end

    def process_shutdown_message(message)
      fake_advertisement = DeaAdvertisement.new(message)

      mutex.synchronize do
        remove_advertisement_for_id(fake_advertisement.dea_id)
      end
    end

    def find_dea(dea_requirements)
      mem = dea_requirements[:memory]
      stack = dea_requirements[:stack]
      mutex.synchronize do
        prune_stale_deas

        best_dea_ad = EligibleDeaAdvertisementFilter.new(@dea_advertisements).
                       only_meets_needs(mem, stack).
                       #hybrid_deploy_candidates(dea_requirements).
                       #upper_half_by_memory.
                       sample

        best_dea_ad && best_dea_ad.dea_id
      end
    end

    def mark_app_started(opts)
      dea_id = opts[:dea_id]
      app_id = opts[:app_id]
      space_id = opts[:space_id]

      #@dea_advertisements.find { |ad| ad.dea_id == dea_id }.increment_instance_count(app_id, space_id) unless opts[:no_staging]
    end

    def logger
       @logger ||= Steno.logger("cc.dea.pool")
    end

    private

    attr_reader :message_bus

    def prune_stale_deas
      @dea_advertisements.delete_if { |ad| ad.expired? }
    end

    def remove_advertisement_for_id(id)
      @dea_advertisements.delete_if { |ad| ad.dea_id == id }
    end

    def remove_advertisement_for_ip(ip)
      @dea_advertisements.delete_if { |ad| ad.dea_ip == ip }
    end


    def mutex
      @mutex ||= Mutex.new
    end

    class DeaAdvertisement
      attr_reader :stats

      def initialize(stats)
        @stats = stats
        @updated_at = Time.now
      end

      def increment_instance_count(app_id, space_id = nil)
        stats[:app_id_to_count][app_id.to_sym] = num_instances_of(app_id.to_sym) + 1
        #stats[:space_id_to_count][space_id.to_sym] = num_instances_of_space(space_id.to_sym) + 1 if space_id
      end

      def num_instances_of(app_id)
        stats[:app_id_to_count].fetch(app_id.to_sym, 0)
      end

      def num_instances_of_space(space_id)
        stats[:space_id_to_count].fetch(space_id.to_sym, 0)
      end 

      def total_instances_by_app_id
        total = 0
        stats[:app_id_to_count].each_pair { |_, count|
          total += count
        }     
        total
      end

      def total_instances_by_space_id
        total = 0
        stats[:space_id_to_count].each_pair { |_, count|
          total += count
        }  
        total        
      end

      def instance_hybrid?
        stats[:app_id_to_count].select { | _, count | count > 1 }.size > 0
      end

      def has_space?(space_id)
        stats[:space_id_to_count].has_key?(space_id.to_sym)
      end

      def is_hybrid?
        ret = total_spaces > 1 || instance_hybrid?
        return ret
      end

      def total_spaces
        stats[:space_id_to_count].keys.size
      end

      def available_memory
        stats[:available_memory]
      end

      def dea_id
        stats[:id]
      end

      def dea_id=(id)
        stats[:id] = id
      end

      def dea_ip  
        stats[:ip]
      end

      def expired?
        (Time.now.to_i - @updated_at.to_i) > ADVERTISEMENT_EXPIRATION
      end

      def meets_needs?(mem, stack)
        has_sufficient_memory?(mem) && has_stack?(stack)
      end

      def has_stack?(stack)
        stats[:stacks].include?(stack)
      end

      def has_sufficient_memory?(mem)
        available_memory >= mem
      end
    end

    class EligibleDeaAdvertisementFilter
      def initialize(dea_advertisements)
        @dea_advertisements = dea_advertisements.dup
      end

      def only_meets_needs(mem, stack)
        @dea_advertisements.select! { |ad| ad.meets_needs?(mem, stack) }
        self
      end

      def only_fewest_instances_of_app(requirements)
        app_id = requirements[:app_guid]
        fewest_instances_of_app = @dea_advertisements.map { |ad| ad.num_instances_of(app_id) }.min
        @dea_advertisements.select! { |ad| ad.num_instances_of(app_id) == fewest_instances_of_app }
        self
      end

      def exclusive_dea_candidates(requirements)
        app_id = requirements[:app_guid]
        space_id = requirements[:space_guid]
        
        @dea_advertisements.select! { |ad| (ad.total_instances_by_app_id == 0) || 
                                           (ad.has_space?(space_id) && 
                                            ad.total_spaces == 1 && 
                                            ad.num_instances_of(app_id) == 0 
                                           ) 
                                    }
        self
      end

      def hybrid_deploy_candidates(requirements)
          if requirements[:space_guid]
             exclusive_dea_candidates(requirements)
          else
             only_fewest_instances_of_app(requirements)
          end
      end

      def upper_half_by_memory
        unless @dea_advertisements.empty?
          @dea_advertisements.sort_by! { |ad| ad.available_memory }
          min_eligible_memory = @dea_advertisements[@dea_advertisements.size/2].available_memory
          @dea_advertisements.select! { |ad| ad.available_memory >= min_eligible_memory }
        end

        self
      end

      def sample
        @dea_advertisements.sample
      end
    end
  end
end
