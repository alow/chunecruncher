require 'mp3info'
require 'lastfm'
require 'similar_text'
require 'musicbrainz'
require 'digest'
require 'json'
require 'logger'

MusicBrainz.configure do |c|
  # Application identity (required)
  c.app_name = "ChuneCruncher"
  c.app_version = "0.1"
  c.contact = "your@email"

  # Cache config (optional)
  c.cache_path = "/tmp/musicbrainz-cache"
  c.perform_caching = true

  # Querying config (optional)
  c.query_interval = 1.2 # seconds
  c.tries_limit = 2
end

$LASTFM_API_KEY = ''
$LASTFM_API_SECRET = ''
$MP3DIR = '/chunes_directory'
$LASTFM_MB_ID_CACHE = '/tmp/mp3_parser'
$MP3PARSER_CACHE = '/home/dir/chune_parser_cache'
$LOG_FILE = '/tmp/chune-parser.log'
$TOKEN = "" #= $LASTFM.auth.get_token

abort "#{$MP3DIR} doesn't exist" unless Dir.exists?($MP3DIR)

log = Logger.new($LOG_FILE)

$LASTFM = Lastfm.new($LASTFM_API_KEY, $LASTFM_API_SECRET)
puts "http://www.last.fm/api/auth/?api_key=#{$LASTFM_API_KEY}&token=#{$LASTFM.auth.get_token}"
$LASTFM.session = $LASTFM.auth.get_session(token: $TOKEN)['key']

lastfm_album_not_exist = []

def generate_hash(file)
  Digest::SHA1.file(file).hexdigest
end

def musicbrainz_parse(field, mb_array)
  result = ""
  mb_array.each do |e|
    if field == "album_id" && e.match(/^MusicBrainz Album Id/i)
      result = e.split("\uFEFF").last
    elsif field == "artist_id" && e.match(/^MusicBrainz Album Artist Id/i)
      result = e.split("\uFEFF").last
    elsif field == "mbid" && e.match(/^http:\/\/musicbrainz.org/i)
      result = e.split("\x00").last
    end
  end
  return result
end

def read_cache(cache, id)
  if File.exists?("#{cache}/#{id}")
    f = File.new("#{cache}/#{id}", "r")
    json = JSON.parse(f.read)
    f.close
    return json
  end
  nil
end

def write_cache(cache, id, struct)
  Dir.mkdir(cache) unless Dir.exists?(cache)
  f = File.new("#{cache}/#{id}", "w")
  f.write(struct.to_json)
  f.close
end

def read_directory(dir)
  # return if the directory doesn't exist
  return [] unless Dir.exists?(dir)
  files = Dir.entries(dir)
  files.map! { |f| f.prepend(dir + '/') }
  return files
end

def check_mp3(file)
  track = {}
  Mp3Info.open(file) do |mp3|
    track["absolute_path"]          = file
    track["title"]                  = mp3.tag.title
    track["mbid"]                   = mp3.tag2.UFID.kind_of?(Array) ? musicbrainz_parse("mbid", mp3.tag2.UFID) : mp3.tag2.UFID.split("\x00").last
    track["album"]                  = mp3.tag.album
    track["album_mbid"]             = musicbrainz_parse("album_id", mp3.tag2.TXXX)
    track["artist_mbid"]            = musicbrainz_parse("artist_id", mp3.tag2.TXXX)
    track["artist"]                 = mp3.tag2.TPE2
    track["lastfm_mbid"]            = ""
    track["lastfm_title"]           = ""
    track["number_of_tracks"]       = 0
    track["lastfm_album_playcount"] = "0"
    track["lastfm_song_playcount"]  = "0"
    track["processed"]              = false
    return track
  end
end

def album_search(mbid=nil, artist=nil, album=nil)
  begin
    if mbid.nil?
      log.info("Getting album info from lastfm via artist/album search")
      album_info = $LASTFM.album.get_info(artist: artist, album: album, api_key: $LASTFM_API_KEY)
    else
      log.info("Getting album info from lastfm via mbid")
      album_info = $LASTFM.album.get_info(mbid: mbid, api_key: $LASTFM_API_KEY)
    end
  rescue Lastfm::ApiError => e
    if e.message.strip == "Album not found"
      log.error("Error getting album info from lastfm #{e.code}: #{e.message.strip}")
      album_info = nil
    end
  end

  album_info
end

def track_search(mbid=nil, artist=nil, track=nil)
  begin
    if mbid.nil?
      log.info("Getting track info from lastfm via artist/track")
      lastfm_track_info = $LASTFM.track.get_info(artist: artist, track: track, api_key: $LASTFM_API_KEY)
    else
      log.info("Getting track info from lastfm via mbid")
      lastfm_track_info = $LASTFM.track.get_info(mbid: mbid, api_key: $LASTFM_API_KEY)
    end
  rescue Lastfm::ApiError => e
    if e.message.strip == "Track not found"
      log.info("Error getting track info from lastfm #{e.code}: #{e.message.strip}")
      lastfm_track_info = nil
    end
  end

  lastfm_track_info
end


files = read_directory($MP3DIR)

while !files.empty?
  f = files.shift

  # skip .. and .
  next unless f.match(/\/\.{1,2}$/).nil?

  if File.directory?(f)
    files += read_directory(f)
  else
    # working with a file, skip none mp3s
    next unless f.match(/\.mp3$/i)
    log.info("#{files.length} entries left")
    log.info("Reading: #{f}")
    found_error = false
    track_hash  = generate_hash(f)
    track_info  = read_cache($MP3PARSER_CACHE, track_hash)

    track_info = check_mp3(f) unless !track_info.nil?

    log.info("Processing #{track_info['artist']}::#{track_info['album']}::#{track_info['title']}")
    # we probably haven't processed this file so let's process it
    album_info = read_cache($LASTFM_MB_ID_CACHE, track_info["album_mbid"])

    # We already know this album doesn't exist on lastfm so skip it
    if lastfm_album_not_exist.include?(track_info["album_mbid"])
      log.info("Album (#{track_info["album_mbid"]}) doesn't exist on lastfm")
      next
    end

    # no cached data, get data from lastfm and populate cache
    if !album_info.nil?
      log.info("Read album from cache")
    else
      album_info = album_search(track_info["album_mbid"])
      album_info = album_search(nil, track_info["artist"], track_info["album"]) unless !album_info.nil?

      if !album_info.nil? && album_info["tracks"]["track"].kind_of?(Array)
        log.info("Writing album cache")
        write_cache($LASTFM_MB_ID_CACHE, track_info["album_mbid"], album_info)
      else
        log.info("Error getting album info from lastfm: #{track_info["album_mbid"]}")
        lastfm_album_not_exist.push(track_info["album_mbid"])
        found_error = true
      end
    end

    # error should just skip the rest
    next unless !found_error

    if !track_info["processed"]
      best_match_index      = nil
      best_match_percentage = 0

      album_info["tracks"]["track"].each_with_index do |lastfm_track, i|
        match_percentage = track_info["title"].to_s.downcase.similar(lastfm_track["name"].to_s.downcase)
        log.info("Matching '#{track_info["title"]}' to '#{lastfm_track["name"]}': #{match_percentage}")
        if best_match_percentage < match_percentage
          best_match_index      = i
          best_match_percentage = match_percentage
        end
      end

      track_info["number_of_tracks"]       = album_info["tracks"]["track"].length
      track_info["lastfm_album_playcount"] = album_info["playcount"]

      if !best_match_index.nil?
        lastfm_track_info = nil
        track_info["lastfm_title"] = album_info["tracks"]["track"][best_match_index]["name"]
        track_info["lastfm_mbid"]  = album_info["tracks"]["track"][best_match_index]["mbid"]

        log.info("Found match: #{track_info["title"]} getting track info from lastfm")

        lastfm_track_info = track_search(track_info["lastfm_mbid"])
        lastfm_track_info = track_search(nil, track_info["artist"], track_info["lastfm_title"]) unless !lastfm_track_info.nil?

        if !lastfm_track_info.nil?
          track_info["lastfm_song_playcount"] = lastfm_track_info["playcount"]
          track_info["processed"]             = true

          write_cache($MP3PARSER_CACHE, track_hash, track_info)
          log.info("Writing cache file: #{track_info["title"]}")
        else
          log.error("Error getting track info from lastfm: #{track_info["lastfm_mbid"]}")
          found_error = true
        end
      else
        log.info("No match for: #{track_info["title"]}")
      end
    else
      log.info("Processed already: #{track_info["title"]}")
    end

    sleep 1.5 # Let's be courteous to our fellow netizen
  end
end





