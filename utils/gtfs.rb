# encoding: UTF-8

module CDKCommands

  # process internal commands, CSDK://<command>
  # as webservice; returning 'data' json object
  def self.process_command(command,data,obj,params)
    case command
    when 'gtfs.stops.now'
      stop_id = obj[:layers]["gtfs.stops"][:data]["stop_id"]
      tzdiff = params['tz'] ? -60 * (Time.now.utc_offset / 3600 + params['tz'].to_i) : 0
      return self.now_for_stop(stop_id,"#{tzdiff} minutes")
    when 'gtfs.stops.schedule'
      stop_id = obj[:layers]["gtfs.stops"][:data]["stop_id"]
      return self.schedule_for_stop(stop_id)
    when 'gtfs.lines.schedule'
      route_id = obj[:layers]["gtfs.lines"][:data]["route_id"]
      return self.schedule_for_line(route_id,obj[:cdk_id][-1], params)
    else
    end
  end

  def self.get_realtime(key,stop_id,deptime)
    rt = CitySDKLD.memcached_get("#{stop_id}!!#{key}!!#{deptime}")
    if rt
      return "#{rt} (#{deptime})"
    end
    deptime
  end

  @@agency_names = {}
  def self.get_agency_name(id)
    return @@agency_names[id] if(@@agency_names[id])
    res = Sequel::Model.db.fetch("select agency_name from gtfs.agency where agency_id = '#{id}'")
    res.to_a.each do |t|
      @@agency_names[id] = t[:agency_name]
      return @@agency_names[id]
    end
    id
  end


  def self.now_for_stop(stop_id, tz)
    h = {}
    a = Sequel::Model.db.fetch("SELECT * FROM stop_now('#{stop_id}','#{tz}')").all
    a.to_a.each do |t|
      aname = t[:agency_id]
      key = "gtfs.line.#{aname.downcase.gsub(/\W/,'')}.#{t[:route_name].gsub(/\W/,'')}-#{t[:direction_id]}"
      mckey = "gtfs.line.#{t[:route_id]}-#{t[:direction_id]}"
      if h[key].nil?
        h[key] = {
          cdk_id: key,
          times: [],
          headsign: t[:headsign],
          route_id: t[:route_id],
          route_name: t[:route_name],
          route_type: t[:route_type]
        }
      end
      h[key][:times] << self.get_realtime(mckey,stop_id,t[:departure])
      h[key][:times].uniq!

      line = Object.where(:cdk_id=>key).first
      if line
        members = line.members.to_a
        lstops = Object.where(:nodes__id => members).all
        lstops = lstops.sort_by { |a| members.index(a.values[:id]) }
        seen_current = false
        h[key][:stops] = []
        lstops.each do |k|
          seen_current = true if k[:cdk_id] == stop.cdk_id
          h[key][:stops] << k[:cdk_id] if (seen_current and (k[:cdk_id] != stop.cdk_id))
        end
      end
    end

    r = []
    h.each_value do |v| r << v end
    return {
      results: r
    }
  end

  def self.schedule_for_stop(stop_id)
    h = {}
    t = Time.now
    (0..6).each do |day|
      d = (t + 86400 * day).strftime("%a %-d %b")
      a = Sequel::Model.db.fetch("SELECT * FROM departs_from_stop('#{stop_id}', #{day})").all
      a.to_a.each do |t|
        aname = self.get_agency_name(t[:agency_id])
        key = "gtfs.line.#{aname.downcase.gsub(/\W/,'')}.#{t[:route_name].gsub(/\W/,'')}-#{t[:direction_id]}"
        if h[key].nil?
          h[key] = {
            cdk_id: key,
            day: {},
            headsign: t[:headsign],
            route_id: t[:route_id],
            route_name: t[:route_name],
            route_type: t[:route_type]
          }
        end
        if(h[key][:day][d].nil?)
          h[key][:day][d] = []
        end
        h[key][:day][d] << t[:departure]
      end
    end
    r = []
    h.each_value do |v| r << v end
    return {
      results: r
    }
  end

  def self.schedule_for_line(route_id,direction,params)
    h = {}

    stops = []
    trips = {}

    day = params[:day] || 0

    d = (Time.now + 86400 * day.to_i).strftime("%a %-d %b")

    # TODO: Use Sequel to insert query parameters
    a = Sequel::Model.db.fetch("SELECT * FROM line_schedule('#{route_id}', #{direction}, #{day})").all
    mckey = "gtfs.line.#{route_id}-#{direction}"

    a.to_a.each do |t|
      key = "gtfs.stop.#{t[:stop_id].downcase.gsub(/\W/,'.')}"
      stops << key if !stops.include?(key)
      trips[t[:trip_id]] = [] if trips[t[:trip_id]].nil?
      trips[t[:trip_id]] << [key, self.get_realtime(mckey,t[:stop_id],t[:departure_time])]
    end

    t = []
    trips.each_value do |v| t << v end


    h[0] = {
      line: line.cdk_id,
      date: d,
      trips: t.sort do |a,b|
        a[0][1] <=> b[0][1]
      end
    }

    r = []
    h.each_value do |v| r << v end
    return {
      results: r
    }
  end



end

__END__

  module PublicTransport

    def self.get_realtime(key,stop_id,deptime)
      rt = CitySDKLD.memcached_get("#{stop_id}!!#{key}!!#{deptime}")
      if rt
        return "#{rt} (#{deptime})"
      end
      return deptime
    end


    def self.schedule_for_line(line, day)
      g = line.get_layer('gtfs')
      if(g)
        h = {}

        stops = []
        trips = {}

        d = ( Time.now+86400 * day.to_i ).strftime("%a %-d %b")

        a = Sequel::Model.db.fetch("select * from line_schedule('#{g[:data]['route_id']}', #{line.cdk_id[-1]}, #{day})").all
        mckey = "gtfs.line.#{g[:data]['route_id']}-#{line.cdk_id[-1]}"

        a.to_a.each do |t|
          key = "gtfs.stop.#{t[:stop_id].downcase.gsub(/\W/,'.')}"
          stops << key if !stops.include?(key)
          trips[t[:trip_id]] = [] if trips[t[:trip_id]].nil?
          trips[t[:trip_id]] << [ key, self.get_realtime(mckey,t[:stop_id],t[:departure_time]) ]
        end

        t = []
        trips.each_value do |v| t << v end


        h[0] = {
          :line => line.cdk_id,
          :date => d,
          :trips => t.sort do |a,b|
            a[0][1] <=> b[0][1]
          end
        }

        r = []
        h.each_value do |v| r << v end
        return {
          :status => 'success',
          :pages => 1,
          :results => r
        }.to_json
      end
    end

    def self.process_stop?(n,params)
      ['ptlines','schedule','now'].include?(params[:cmd])
    end

    def self.process_stop(stop,params)
      if params.key? 'cdk_id'
        if stop
          case params[:cmd]
          when 'ptlines'
            lines = Object.where("members @> '{ #{stop.id} }' ").eager_graph(:node_data).where(:node_id => :nodes__id)
            lines = lines.all.map { |a| a.values.merge(:node_data=>a.node_data.map{|al| al.values}) }

            puts lines.inspect

            return {
              :status => 'success',
              :pages => 1,
              :per_page => lines.length,
              :record_count => lines.length,
              #:results => lines.each {|l| Object.to_hash(l,params)},
              :chips => "vis"
            }.to_json
          when 'schedule'
            return schedule_for_stop(stop)
          when 'now'
            tzdiff = params['tz'] ? -60 * (Time.now.utc_offset/3600 + params['tz'].to_i) : 0
            return now_for_stop(stop,"#{tzdiff} minutes")
          else
            CitySDKLD.do_abort(422,"Command #{params[:cmd]} not defined for ptstop.")
          end
        else
          CitySDKLD.do_abort(422,'Stop ' + params[:cdk_id] + ' not found..')
        end
      else
        CitySDKLD.do_abort(500,'Server error. ')
      end
    end

    def self.process_line?(n,params)
      ['ptstops','schedule'].include?(params[:cmd])
    end

    def self.process_line(line,params)
      if params.key? 'cdk_id'
        if(line)
          case params[:cmd]
          when 'ptstops'
            members = line.members.to_a
            stops = Object.where(:nodes__id => members).eager_graph(:node_data).where(:node_data__node_id => :nodes__id).all
            stops = stops.sort_by { |a| members.index(a.values[:id]) }.map { |a|
              a.values.merge( :node_data =>
               a.node_data.map{ |al|
                 al.values
                }
              )
            }
            return {
              :status => 'success',
              :pages => 1,
              :per_page => stops.length,
              :record_count => stops.length #,
              #:results => stops.each {|l| Object.to_hash(l,params)}
            }.to_json
          when 'schedule'
            return schedule_for_line(line,params[:day]||0)
          else
            CitySDKLD.do_abort(422,"Command #{params[:cmd]} not defined for ptline.")
          end
        else
          CitySDKLD.do_abort(422,'Line ' + params[:cdk_id] + ' not found..')
        end
      else
        CitySDKLD.do_abort(500,'Server error. ')
      end
    end
  end
end