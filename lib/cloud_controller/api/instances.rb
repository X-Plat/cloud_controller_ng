# Copyright (c) 2009-2012 VMware, Inc.

module VCAP::CloudController
  rest_controller :Instances do
    disable_default_routes
    path_base "apps"
    model_class_name :App

    permissions_required do
      read Permissions::CFAdmin
      update Permissions::CFAdmin 
      update Permissions::SpaceDeveloper
      read Permissions::SpaceDeveloper
    end

    def instances(id)
      app = find_id_and_validate_access(:read, id)

      if app.failed?
        raise VCAP::Errors::StagingError.new("cannot get instances since staging failed")
      elsif app.pending?
        raise VCAP::Errors::NotStaged
      end

      instances = DeaClient.find_all_instances(app)
      Yajl::Encoder.encode(instances)
    end

    get  "#{path_id}/instances", :instances

    def kill_instance(id, index)
      app = find_id_and_validate_access(:update, id)

      DeaClient.stop_indices(app, [index.to_i])
      [HTTP::NO_CONTENT, nil]
    end

    delete "#{path_id}/instances/:index", :kill_instance
  end
end
