module Stations

using Utils
import Utils.GeoLoc

using Calendar
import Calendar.CalendarTime

import Base.show

export Station, Observation
#export show, obs_times, raw_obs, obs_var, id, name, load_station_info, load_station_data


abstract AbstractStation

type Observation

    # station of origin
    station::AbstractStation

    # observation time
    tm::CalendarTime

    # observed value
    value::Float64

    # name of the variable
    obs_type::String

    # variance of the observation
    var :: Float64

    # default constructor
    Observation(s, tm, value, obs_type, var) = new(s, tm, value, obs_type, var)

end


type Station <: AbstractStation

    # station id
    id::String

    # station name
    name::String

    # station location (lat/lon decimal)
    loc::GeoLoc

    # station elevation (meters)
    elevation::Float64

    # dictionary mapping variable names to observations
    obs::Dict{String,Array{Observation}}

    # available observation types from the station
    sensor_types :: Array{String}

    Station() = new("", "", GeoLoc(0.0, 0.0), 0.0,  Dict{String,Array{Observation}}(), Array(String,0))

    Station(id, name, loc, elevation) = new(id, name, loc, elevation, Dict{String,Array{Observation}}(), Array(String,0))

end


function show(io::IO, o::Observation)
#    write(io, "Obs($o.value of $o.obs_type at $o.station.id, $o.tm with var $o.var)")
    print(io, "Obs(", o.obs_type, "=", o.value, " at ", o.station.id, ", ", o.tm, " with var ", o.var, ")")
end


function obs_times(s::Station, obs_type::String)
    return [o.tm for o in observations(s, obs_type)]
end



function obs_var(s::Station, obs_type::String)
    return s.obs[obs_type]
end


function id(s::Station)
    return s.id
end


function name(s::Station)
    return s.name
end


function observations(s::Station, obs_type::String)
    return s.obs[obs_type]
end


function observations(s::Station, obs_type::String, tm::Array{CalendarTime})
    
    # retrieve all the observations for the given type
    obs = s.obs[obs_type]
    otm = [o.tm for o in obs]
    obs_ret = Dict(CalendarTime, Observation)
    
    i, j = 1, 1
    while (i <= length(tm)) && (j <= length(otm))
        if tm[i] == otm[j]
            obs_ret[tm[i]] = obs[i]
            i += 1
            j += 1
        elseif tm[i] > obst[j]
            j += 1
        elseif tm[i] < obst[j]
            j += 1
        end
    end
    
    return obs_ret
end


function load_station_info(fname :: String)

    s = Station()

    # open file
    io = open(fname, "r")

    # read station id
    s.id = strip(readline_skip_comments(io))

    # read station name
    s.name = strip(readline_skip_comments(io))

    # read station geo location
    s.loc = Utils.parse_geolocation(readline_skip_comments(io))

    # read elevation
    s.elevation = float(strip(readline_skip_comments(io)))

    # read all observation types acquired by the station
    s.sensor_types = map(x -> strip(x), split(readline_skip_comments(io), ","))
    nvars = length(s.sensor_types)

    # create var time series containers
    for v in s.sensor_types
        s.obs[v] = Array(Float64, 0)
    end

    # close the info file
    close(io)

    return s
end



function load_station_data(s::Station, fname::String)

    # open file
    io = open(fname, "r")

    # read observations, time is first (and in GMT), then one value per measurement or nan if not available
    while !eof(io)

        # read the date
        tm_str = strip(readline_skip_comments(io))
        tm = Calendar.parse("%Y-%M-%d_%H:%m", tm_str, "GMT")

        # read in observed variables
        variables = map(x -> strip(x), split(readline_skip_comments(io), ","))

        # read in observed values
        vals = map(x -> float(x), split(readline_skip_comments(io), ","))

        # read in variances of observations
        variances = map(x -> float(x), split(readline_skip_comments(io), ","))

        obs = Observation[]
        for i in 1:length(variables)
            var = variables[i]
            push!(s.obs[var], Observation(s, tm, vals[i], var, variances[i]))
        end

    end

    # cleanup
    close(io)

    # return the created station
    return s

end


function build_observation_data(ss::Array{Station}, obs_type::String)
    Ns = length(ss)
    obs = Observation[]
    
    # observation data
    for s in ss
        append!(obs, observations(s, obs_type))
    end

    # repackage into a time-indexed structure
    obs_data = Dict{CalendarTime,Array{Observation}}()
    for o in obs
        if has(obs_data, o.tm) push!(obs_data[o.tm], o) else obs_data[o.tm] = [o] end
    end

    return obs_data
end


function readline_skip_comments(io :: IO)
    s = "#"
    while length(s) == 0 || s[1] == '#'
        s = readline(io)
    end
    return s
end


end
