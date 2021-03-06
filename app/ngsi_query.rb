# encoding: UTF-8

require 'digest/sha1'

module CitySDKLD

  class NGSI10

    def self.do_query(query)
      query[:api].error!('Not found', 404) unless NGSI_COMPAT

      @limit = query[:params][:limit] ? [1000,query[:params][:limit].to_i].min : 20
      @offset = query[:params][:offset] ? query[:params][:offset].to_i : 0
      @details = (query[:params][:details] and query[:params][:details] == 'on') ? true : false
      @base = App.get_config[:endpoint][:base_uri]
      @count = 0
      case query[:method]
        when :post
          return self.post(query)
        when :put
          return self.put(query)
        when :get
          return self.get(query)
      end
      return {ngsiresult: 'unkown command'}
    end

    def self.get(q)
      case q[:path][-2]
        when :contextEntityTypes
          return self.query_context_entity_types(q) if q[:params][:cetype]
        when :contextEntities
          return self.query_one_entity(q)    if q[:params][:entity]
        when :attributes
          return self.query_one_attribute(q) if q[:params][:entity] and q[:params][:attribute]
          return self.query_context_entity_types(q) if q[:params][:cetype] and q[:params][:attribute]
      end
      return {ngsiresult: 'unkown command'}
    end

    def self.put(q)
      if q[:path][-1] == :attributes and q[:params][:entity]
        return self.update_attributes_for_entity(q)
      end
      return {ngsiresult: 'unkown command'}
    end

    def self.post(q)
      case q[:path][-1]
        when :updateContext
          return self.update_context(q)
        when :queryContext
          return self.query_context(q)
        when :subscribeContext
          return self.subscribe_context(q)
        when :updateContextSubscription
          return {ngsiresult: 'not yet implemented: ' + q[:path][-1]}
        when :unsubscribeContext
          return self.unsubscribe_context(q)
      end
      return {ngsiresult: 'unkown command'}
    end

    def self.unsubscribe_context(q)
      sid = q[:data][:subscriptionId]
      begin
        NGSI_Subscription.where( subscription_id: sid ).delete
      rescue Exception => e
        return {errorCode: {code: '422', reasonPhrase: 'subscriptionId not found'}}
      end
      return {subscriptionId: sid, statusCode: {code: '204', reasonPhrase: 'OK'}}
    end

    def self.get_entity_for_subs(ce, layer)
      retvalue = []
      if ce[:isPattern] == true
        pattern = Regexp::quote(layer.name + '.') + ce[:id]
        objects = CDKObject.select(:cdk_id, :layer_id).where(layer_id: layer.id, cdk_id: Regexp.new(pattern, Regexp::IGNORECASE))
        objects.each do |o|
          retvalue << o.to_hash
        end
      else
        cdk_id = CitySDKLD.cdk_id_from_id(layer.name, ce[:id])
        object = CDKObject.select(:cdk_id, :layer_id).where(cdk_id: cdk_id).first
        if object
          retvalue << object.to_hash
        end
      end
      retvalue
    end

    def self.subscribe_context(q)
      layer = nil
      @count = 0
      @field_types = []
      num_entities = 0
      data = q[:data]

      return {errorCode: {code: '422', reasonPhrase: 'Missing data in request'}} if
        (data[:entities].blank? or data[:duration].blank? or data[:reference].blank? or data[:notifyConditions].blank?)

      return { errorCode: { code: '422', reasonPhrase: 'Time Interval not implemented'}} if
        data[:notifyConditions][0][:type] == 'ONTIMEINTERVAL'

      sid = Digest::SHA1.hexdigest(Time.now.to_s + data[:entities].to_s)[8..31]

      data[:entities].each do |ce|
        if ce[:type]
          CDKLayer.where(rdf_type: 'orion:' + ce[:type]).or(rdf_type: ce[:type]).each do |layer|
            self.populate_field_types(layer)
            entities = self.get_entity_for_subs(ce,layer)
            num_entities += entities.length
            NGSI_Subscription.new_subscription(entities,data,sid)
          end
        end
      end
      return {errorCode: { code: '404', reasonPhrase: 'No context elements found'}} if num_entities == 0
      return {subscribeResponse: {subscriptionId: sid, duration: data[:duration]}}
    end

    def self.update_context_subscription(q)
    end

    def self.update_attributes_for_entity(q)
      data = q[:data]
      newdata = {}
      pattern = "(.*)\\.#{Regexp::quote(q[:params][:entity])}$"
      object = CDKObject.where(cdk_id: Regexp.new(pattern,Regexp::IGNORECASE)).first
      if object
        layer = CitySDKLD.memcached_get(CDKLayer.memcached_key(object.layer_id.to_s))
        data[:attributes].each do |a|
          newdata[a[:name]] = a[:value]
          a[:value] = ''
        end
        q = q.dup
        q[:params][:cdk_id] = object.cdk_id
        q[:params][:layer] = layer[:name]
        q[:data] = newdata
        q[:method] = :patch
        CDKObjectDatum.execute_write(q)
        data[:statusCode] = {code: '200', reasonPhrase: 'OK'}
        return data
      else
        return {errorCode: {code: '404', reasonPhrase: 'No context elements found'}}
      end
    end

    def self.update_context(query)
      ct_response = {contextResponses: [], statusCode: {code: '200', reasonPhrase: 'OK'}}
      data = query[:data]
      if data[:updateAction] =~ /delete/i
        # delete attributes or contextentities
      else
        data[:contextElements].each do |ce|
          layer = CDKLayer.where(rdf_type: 'orion:' + ce[:type]).or(rdf_type: ce[:type]).first
          if !layer
            layer = self.create_layer(ce, query)
            self.create_object(query,layer,ce)
          else
            object = CDKObject.where(cdk_id: CitySDKLD.cdk_id_from_id(layer.name, ce[:id])).first
            if object
              self.update_object(query,layer,ce,object)
            else
              self.create_object(query,layer,ce)
            end
          end
          ct_response[:contextResponses] << ce
        end
      end
      return ct_response
    end

    def self.query_one_entity(q)
      @field_types = []
      r = get_one_entity({id: q[:params][:entity]},nil,nil)
      (r and r[0]) ? r[0] : {errorCode: {code: '404', reasonPhrase: 'No context elements found'}}
    end

    def self.query_one_attribute(q)
      @field_types = []
      r = get_one_entity({id: q[:params][:entity]},nil,nil)
      return {errorCode: {code: '404', reasonPhrase: 'No context elements found'}} if r.nil?
      if r[0]
        r[0][:contextElement][:attributes].each do |a|
          if a[:name] == q[:params][:attribute]
            r[0][:attributes] = [a]
            r[0].delete(:contextElement)
            return r[0]
          end
        end
      end
      {errorCode: {code: '404', reasonPhrase: 'Attribute not found in context element'}}
    end

    def self.get_one_entity(ce, attributes, restriction)
      retvalue = []
      if (ce[:isPattern] == true) or (ce[:isPattern] == 'true')
        pattern = "(.*)\\." + ce[:id]
        objects = self.objects_select_filter(CDKObject.where(cdk_id: Regexp.new(pattern,Regexp::IGNORECASE)), restriction)

        @count += CDKObject.where(cdk_id: Regexp.new(pattern,Regexp::IGNORECASE)).count() if @details
        objects.each do |o|
          layer = CitySDKLD.memcached_get(CDKLayer.memcached_key(o.layer_id.to_s))
          self.populate_field_types(layer)
          retvalue << self.get_one_object(ce, o, layer, attributes)
        end
      else
        object = self.objects_select_filter(CDKObject.where(Sequel.like(:cdk_id, "%#{ce[:id].downcase}")), restriction).first
        if object
          layer = CitySDKLD.memcached_get(CDKLayer.memcached_key(object.layer_id.to_s))
          self.populate_field_types(layer)
          retvalue << self.get_one_object(ce, object, layer, attributes)
        end
      end
      retvalue
    end

    def self.get_one_layered_entity(ce,layer,attributes, restriction)
      retvalue = []

      if (ce[:isPattern] == true) or (ce[:isPattern] == 'true')
        pattern = Regexp::quote(layer.name + '.') + ce[:id]
        objects = self.objects_select_filter(CDKObject.where(layer_id: layer.id, cdk_id: Regexp.new(pattern,Regexp::IGNORECASE)), restriction)
        @count  += CDKObject.where(layer_id: layer.id, cdk_id: Regexp.new(pattern,Regexp::IGNORECASE)).count() if @details
        objects.each do |o|
          retvalue << self.get_one_object(ce, o, layer, attributes)
        end
      else
        cdk_id = CitySDKLD.cdk_id_from_id(layer.name, ce[:id])
        object = self.objects_select_filter(CDKObject.where(cdk_id: cdk_id), restriction).first
        if object
          retvalue << self.get_one_object(ce, object, layer, attributes)
        end
      end
      retvalue
    end

    def self.get_one_object(ce, object, layer, attributes)

      elm = {contextElement: {attributes: [], id: @base + object[:cdk_id], isPattern: false, type: ce[:type]}, statusCode: {code: '200', reasonPhrase: 'OK'}}
      odatum = CDKObjectDatum.get_from_object_and_layer(object.cdk_id, layer[:id])
      odatum[:data].each do |k,v|
        begin
          v = JSON.parse(v, symbolize_names: true)
        rescue
        end
        if attributes.blank? or attributes.include?(k)
          elm[:contextElement][:attributes] << { name: k, value: v, type: @field_types[layer[:id]][k] || 'unknown'}
        end
      end
      if object[:centr] =~ /POINT\(([\d\.]+)\s([\d\.]+)\)/
        if attributes.blank?
          elm[:contextElement][:attributes] << {
            name: 'geography',
            value: "#{$2}, #{$1}",
            type: 'coords',
            metadatas: [
              {
                name: 'location',
                type: 'string',
                value: 'WSG84'
              }
            ]
          }
        end
      end
      elm
    end

    def self.query_context_entity_types(q)
      layer = nil
      @count = 0
      @field_types = []
      cetype = q[:params][:cetype]
      attrs = q[:params][:attribute] ? [ q[:params][:attribute] ] : nil
      ct_response = {contextResponses: []}
      CDKLayer.where(rdf_type: 'orion:' + cetype).or(rdf_type: cetype).each do |layer|
        self.populate_field_types(layer)
        objects = self.objects_select_filter(CDKObject.where(layer_id: layer.id), nil)
        @count += CDKObject.where(layer_id: layer.id).count() if @details
        objects.each do |o|
          ct_response[:contextResponses] << self.get_one_object({type: cetype}, o, layer, attrs)
        end
      end;
      return {errorCode: {code: '404', reasonPhrase: 'No context elements found' }} if ct_response[:contextResponses].length == 0
      ct_response[:errorCode] = {code: 200, reasonPhrase: 'OK', details: "Count: #{@count}"} if @count
      return ct_response
    end

    def self.query_context(query)
      layer = nil
      @count = 0
      @field_types = []
      ct_response = {contextResponses: []}
      data = query[:data]
      attributes = data[:attributes]
      data[:entities].each do |ce|
        if ce[:type]
          CDKLayer.where(rdf_type: 'orion:' + ce[:type]).or(rdf_type: ce[:type]).each do |layer|
            self.populate_field_types(layer)
            ct_response[:contextResponses] += self.get_one_layered_entity(ce, layer, attributes, data[:restriction])
          end
        else
          # typeless query
          ct_response[:contextResponses] += self.get_one_entity(ce, attributes, data[:restriction])
        end
      end
      return {errorCode: { code: '404', reasonPhrase: 'No context elements found'}} if ct_response[:contextResponses].length == 0
      ct_response[:errorCode] = {code: 200, reasonPhrase: 'OK', details: "Count: #{@count}" } if @count
      return ct_response
    end

    def self.populate_field_types(l)
      # cache field types to reduce DB queries
      return if @field_types[ l[:id] ]
      layer = CitySDKLD.memcached_get(CDKLayer.memcached_key(l[:id].to_s))
      @field_types[l[:id]] = {}
      layer[:fields].each do |f|
        @field_types[l[:id]][f[:name]] = f[:type]
      end
    end

    def self.create_object(query,layer,data)
      object = {
        type: 'Feature',
        properties: {
          id: data[:id],
          title: data[:id],
          data: { }
         },
        geometry: {
          type: 'Point',
          coordinates: [4.90033, 52.37277]
        }
      }

      data[:attributes].each do |attribute|
        if attribute[:metadatas]
          seen_geometry = false
          attribute[:metadatas].each do |metadatum|
            if metadatum[:name] == 'location' and attribute[:value] =~ /([\d\.]+)[\s,]+([\d\.]+)/
              object[:geometry][:coordinates] = [$2.to_f, $1.to_f]
              seen_geometry = true
            end
          end
          next if seen_geometry
        end
        object[:properties][:data][attribute[:name]] = attribute[:value]

        # empty values for response object
        attribute[:value] = ''
      end

      q = query.dup
      q[:params] = query[:params].dup
      q[:params][:layer] = layer[:name]
      q[:data] = object
      CDKObject.execute_write(q)
    end

    def self.update_object(query,layer,data,object)
      newdata = {}
      data[:attributes].each do |a|
        newdata[a[:name]] = a[:value]
        a[:value] = ''
      end
      q = query.dup
      q[:params][:cdk_id] = object.cdk_id
      q[:params][:layer] = layer.name
      q[:data] = newdata
      q[:method] = :patch
      CDKObjectDatum.execute_write(q)
    end

    def self.create_layer(data, query)
      layer = {
        name: 'ngsi.' + data[:type].downcase,
        title: data[:type] + ' orion ngsi layer',
        rdf_type: 'orion:' + data[:type],
        fields: [],
        owner: 'citysdk',
        description: 'System-generated, Fi-Ware Orion generated data layer',
        data_sources: ['NGSI'],
        category: 'none',
        subcategory: '',
        licence: 'unspecified'
      }

      data[:attributes].each do |a|
        layer[:fields] << {
          name: a[:name],
          type: a[:type],
          description: ''
        }
      end

      q = query.dup
      q[:data] = layer
      q[:method] = :post
      CDKLayer.execute_write(q)
      CDKLayer.where(rdf_type: 'orion:' + data[:type]).first
    end

    def self.polygon(vertices)
      ret = ''
      vertices.each do |v|
        ret << ',' if ret.length > 0
        ret << v[:longitude]
        ret << " " + v[:latitude]
      end
      'POLYGON((' + ret + '))'
    end

    def self.objects_select_filter(dataset, restriction)
      dataset = dataset.select(:cdk_id, :layer_id, :title,  Sequel.as(Sequel.function(:ST_AsText, Sequel.function(:ST_Centroid, :geom)), :centr))
      if restriction
        restriction[:scopes].each do |s|
          if s[:type] == 'FIWARE_Location'
            if s[:value][:polygon]
              p = self.polygon(s[:value][:polygon][:vertices])
              if s[:value][:polygon][:inverted] == true
                dataset = dataset.exclude(
                  Sequel.function(:ST_Contains,
                    Sequel.function(:ST_SetSRID,Sequel.function(:ST_PolygonFromText, p), 4326),
                      Sequel.function(:ST_Centroid, :geom)) )
              else
                dataset = dataset
                  .where( Sequel.function(:ST_Contains,
                    Sequel.function(:ST_SetSRID,Sequel.function(:ST_PolygonFromText, p), 4326),
                      Sequel.function(:ST_Centroid, :geom)) )
              end
            elsif s[:value][:circle]
              lat = s[:value][:circle][:centerLatitude].to_f
              lon = s[:value][:circle][:centerLongitude].to_f
              rad = s[:value][:circle][:radius].to_f
              intersects = "ST_Intersects(ST_Transform(Geometry(ST_Buffer(Geography(ST_Transform(ST_SetSRID(ST_Point(#{lon}, #{lat}), 4326), 4326)), #{rad})), 4326), ST_Centroid(geom))"
              if s[:value][:circle][:inverted] == true
                dataset = dataset.exclude(intersects)
              else
                dataset = dataset.where(intersects)
              end
            end
          end
        end
      end
      dataset.offset(@offset).limit(@limit).order(:updated_at)
    end
  end
end
