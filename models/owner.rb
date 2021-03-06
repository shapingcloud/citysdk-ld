# encoding: UTF-8

class CDKOwner < Sequel::Model(:owners)
  one_to_many :layers

  def self.get_dataset(query)
    dataset = self.dataset
  end

  def self.execute_write(query)
    data = query[:data]
    written_owner_id = nil

    required_keys = [
      :name,
      :email,
      :website,
      :fullname,
      :domains,
      :organization,
      :password
    ]

    optional_keys = [
      :admin
    ]

    # Make sure POST data contains only valid keys
    unless (data.keys - (required_keys + optional_keys)).empty?
      query[:api].error!("Incorrect keys found in owner PUT/POST data: #{(data.keys - (required_keys + optional_keys)).join(', ')}", 422)
    end

    if data[:password]
      password = data[:password]
      secure, message = CitySDKLD.password_secure? password
      if secure
        data[:salt] = Digest::MD5.hexdigest(Random.rand().to_s)
        data[:password] = Digest::MD5.hexdigest(data[:salt] + password)
      else
        query[:api].error!(message, 422)
      end
    end

    if data[:domains]
      begin
        data[:domains] = Sequel.pg_array(data[:domains])
      rescue
        query[:api].error!('Invalid domains encountered - must be comma-separated list of layer prefixes', 422)
      end
    end

    case query[:method]
    when :post
      # create

      # need to be admin to create owners
      self.verify_admin(query)

      owner_id = self.id_from_name data[:name]
      if owner_id
        query[:api].error!("Owner already exists: #{data[:name]}", 422)
      end

      if data.keys.length < required_keys.length
        query[:api].error!("Cannot create owner, keys are missing in POST data: #{(required_keys - data.keys).join(', ')}", 422)
      end

      written_owner_id = insert(data)
    when :patch
      # update
      if data[:name]
        query[:api].error!('Owner name cannot be changed', 422)
      end

      self.verify_admin(query) if data[:admin]

      owner_id = self.id_from_name query[:params][:owner]

      if owner_id
        self.verify_owner(query, owner_id)
        where(id: owner_id).update(data)
      else
        query[:api].error!("Owner not found: #{query[:params][:owner]}", 404)
      end
      written_owner_id = owner_id
    end

    dataset.where(id: written_owner_id)
  end

  def self.execute_delete(query)

    return self.delete_session(query) if query[:resource] == :sessions

    self.verify_admin(query)

    owner_id = id_from_name query[:params][:owner]
    if owner_id == 0
      query[:api].error!("Owner 'citysdk' cannot be deleted", 422)
    elsif owner_id
      # Move all objects on layers belonging to this owner that still
      # have data on other layers to layer = -1. See layer.rb > execute_delete
      # for example

      # TODO: create SQL function in 003_functions migration

      move_objects = <<-SQL
        UPDATE objects SET layer_id = -1
        WHERE id IN (
          SELECT id FROM objects AS o2
          WHERE layer_id IN (
            SELECT id FROM layers WHERE owner_id = ?
          ) AND EXISTS (
            SELECT TRUE FROM object_data
            WHERE o2.id = object_id
            AND object_data.layer_id != o2.layer_id
            AND o2.layer_id != -1
          )
        );
      SQL

      Sequel::Model.db.transaction do
        Sequel::Model.db.fetch(move_objects, owner_id).all
        where(id: owner_id).delete
        CDKObject.delete_orphans
      end
    else
      query[:api].error!("Owner not found: #{query[:params][:owner]}", 404)
    end
  end

  def self.id_from_name(name)
    owner = dataset.select(:id).where(name: name).first
    if owner
      owner[:id]
    else
      nil
    end
  end

  def self.check_session_timeout(query, owner)
    if owner[:session_expires] < Time.now
      query[:api].error!("Session has timed out", 401)
    end
    owner.update(session_expires: Time.now + 5.minutes)
    owner
  end

  def self.admin?(query)
    if query[:api].headers['X-Auth']
      owner = self.where(session_key: query[:api].headers['X-Auth']).first
      return (owner[:admin] && owner[:session_expires] > Time.now) if owner
    end
    false
  end

  def self.self_or_admin?(query, name)
    if query[:api].headers['X-Auth']
      owner = self.where(session_key: query[:api].headers['X-Auth']).first
      if owner and owner[:session_expires] > Time.now
        return (owner[:admin] or owner[:name] == name)
      end
    end
    false
  end

  def self.verify_owner(query, owner_id)
    if query[:api].headers['X-Auth']
      owner = self.where(session_key: query[:api].headers['X-Auth']).first
      return self.check_session_timeout(query, owner) if owner and (owner[:admin] or (owner[:id] == owner_id))
    end
    query[:api].error!("Operation requires correct authorization - must be resource's owner or admin", 401)
  end

  def self.verify_owner_for_layer(query, layer_id)
    if query[:api].headers['X-Auth']
      owner = self.where(session_key: query[:api].headers['X-Auth']).first
      layer = CDKLayer.where(id: layer_id).first
      return self.check_session_timeout(query, owner) if owner and (owner[:admin] or (owner[:id] == layer[:owner_id]))
    end
    query[:api].error!("Operation requires correct authorization - must be resource's owner or admin", 401)
  end

  def self.verify_domain(query, domain)
    query[:api].error!("Operation requires authorization", 401) unless query[:api].headers['X-Auth']
    owner = self.where(session_key: query[:api].headers['X-Auth']).first
    return self.check_session_timeout(query, owner) if owner and (owner[:admin] or owner[:domains].include?(domain))
    query[:api].error!("Owner has no access to domain '#{domain}'", 403)
  end

  def self.verify_admin(query)
    return true if self.admin?(query)
    query[:api].error!('Operation requires administrative authorization', 401)
  end

  def self.session_key(query)
    owner = self.authenticate(query[:params][:name], query[:params][:password])
    if owner
      if (owner[:session_key] and owner[:session_expires] > Time.now)
        key = owner.session_key
      else
        key = Digest::MD5.hexdigest(Time.now.to_s + query[:params][:password])
      end
      owner.update({session_key: key, session_expires: Time.now + 5.minutes})
      return key
    else
      nil
    end
  end

  def self.current_owner
    self.where(session_key: query[:api].headers['X-Auth']).first
  end

  def self.delete_session(query)
    if query[:api].headers['X-Auth']
      self.where(session_key: query[:api].headers['X-Auth']).update({session_key: nil})
    end
    ''
  end

  def self.authenticate(name, password)
    owner = CDKOwner.where(name: name).first
    if owner and (Digest::MD5.hexdigest(owner[:salt] + password ) == owner[:password])
      return owner
    else
      nil
    end
  end

  def self.make_hash(o, q=nil)
    h = {
      name: o[:name],
      fullname: o[:fullname],
      email: o[:email],
      website: o[:website],
      organization: o[:organization],
      admin: o[:admin],
    }.delete_if{ |_, v| v.nil? or v == '' }
    h[:domains] = o[:domains].join(', ') if (o[:domains] and q and self.self_or_admin?(q,o[:name]))
    h
  end

end
