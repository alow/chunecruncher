require 'mp3info'
require 'digest'
require 'json'
require 'fileutils'

$MP3DIR = '/chunes_directory'
$MP3PARSER_CACHE = '/home/dir/chune_parser_cache'
$MP3SORTED = '/home/dir/sorted-chunes'
$LOG_FILE = '/tmp/chune-sorter.log'

abort "#{$MP3DIR} doesn't exist" unless Dir.exists?($MP3DIR)

File.unlink($LOG_FILE) unless !File.exists?($LOG_FILE)

def generate_hash(file)
  Digest::SHA1.file(file).hexdigest
end

def write_log(message)
  f = File.new($LOG_FILE, "a")
  f.write(message + "\n")
  f.close
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

def mp3_sort(album)
  total_plays = 0
  variance = 0
  song_plays = []

  album.each_with_index do |t, i|

    if t["lastfm_song_playcount"].kind_of?(String)
      song_plays << t["lastfm_song_playcount"].to_i
    else
      song_plays << 0
    end
    total_plays += song_plays.last
  end

  average_plays = total_plays / album.length.to_f

  song_plays.each do |s|
    variance += (s - average_plays)**2
  end
  variance /= song_plays.length.to_f

  stddev = Math.sqrt(variance)
  puts "Album: #{album[0]["album"]}"
  puts "Average plays: #{average_plays}"
  puts "Variance: #{variance}"
  puts "Std dev: #{stddev}"

  rank = [
    0,
    average_plays - stddev,
    average_plays - 0.5 * stddev,
    average_plays,
    average_plays + 0.5 * stddev]

  album.each_with_index do |t, i|
    track_rank = rank.rindex do |x|
      if t["lastfm_song_playcount"].kind_of?(String)
        t["lastfm_song_playcount"].to_i >= x
      else
        0 >= x
      end
    end

    Dir.mkdir("#{$MP3SORTED}/#{track_rank}") unless Dir.exists?("#{$MP3SORTED}/#{track_rank}")
    puts "Moving #{t["absolute_path"]}"
    FileUtils.mv(t["absolute_path"], "#{$MP3SORTED}/#{track_rank}/#{t["artist"].delete("/")} - #{t["title"].delete("/")}.mp3")
  end
end

files = read_directory($MP3DIR)
directories = [];

while !files.empty?
  f = files.shift

  # skip .. and .
  next unless f.match(/\/\.{1,2}$/).nil?

  if File.directory?(f)
    directories << f
    files += read_directory(f)
  end
end

directories.each do |d|
  files = read_directory(d)
  mp3_files = files.keep_if { |f| f.match(/\.mp3$/i) }
  next unless !mp3_files.empty?

  processed_files = 0
  album = []
  mp3_files.each do |mp3|
    processed_details = read_cache($MP3PARSER_CACHE, generate_hash(mp3))
    if !processed_details.nil?
      processed_files += 1
      album << processed_details
    end
  end

  # Threshold for sorting albums
  if album.length == mp3_files.length
    puts "#{album}"
    mp3_sort(album)
  end

end


