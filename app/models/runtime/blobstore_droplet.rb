module CloudController
  class BlobstoreDroplet
    def initialize(app, blobstore)
      @app = app
      @blobstore = blobstore
    end

    def file
      if @app.staged? && blobstore_key
        blobstore.file(blobstore_key)
      end
    end

    def download_to(destination_path)
      if blobstore_key
        blobstore.download_from_blobstore(blobstore_key, destination_path)
      end
    end

    def local_path
      f = file
      f.send(:path) if f
    end

    def download_url
      f = file
      return nil unless f
      return blobstore.download_uri_for_file(f)
    end

    def delete
      blobstore.delete(new_blobstore_key)
      begin
        blobstore.delete(old_blobstore_key)
      rescue Errno::EISDIR
        # The new droplets are with a path which is under the old droplet path
        # This means that sometimes, if there are multiple versions of a droplet,
        # the directory will still exist after we delete the droplet.
        # We don't care for now, but we don't want the errors.
      end
    end

    def exists?
      return !!app.droplet_hash && !!blobstore_key
    end

    def save(source_path, droplets_to_keep=2)
      hash = Digest::SHA1.file(source_path).hexdigest
      blobstore.cp_to_blobstore(
        source_path,
        File.join(app.guid, hash)
      )
      app.droplet_hash = hash
      current_droplet_size = app.droplets_dataset.count

      if current_droplet_size > droplets_to_keep
        app.droplets_dataset.
          order_by(Sequel.asc(:created_at)).
          limit(current_droplet_size - droplets_to_keep).destroy
      end

      app.save
      app.reload
    end

    private
    attr_reader :blobstore, :app

    def blobstore_key
      if blobstore.exists?(new_blobstore_key)
        return new_blobstore_key
      elsif blobstore.exists?(old_blobstore_key)
        return old_blobstore_key
      end
    end

    def new_blobstore_key
      File.join(app.guid, app.droplet_hash)
    end

    def old_blobstore_key
      app.guid
    end
  end
end
