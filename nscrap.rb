# Modules
require 'net/http'
require 'timeout'
require 'zlib'
require 'base64'
# Gems
require 'nokogiri'
require 'active_record'

EPISODE_S = 1      # Starting point of the episode scrape
EPISODE_E = 60000  # Finishing point of the episode scrape
LEVEL_S   = 1      # Starting point of the level scrape
LEVEL_E   = 350000 # Finishing point of the level scrape

ATTEMPTS  = 10     # Retries until score is skipped
COMPRESS  = true   # Compress demos before storing in db
EMPTY_E   = 67     # Size of an empty episode score
EMPTY_L   = 46     # Size of an empty level score
EPISODES  = 100
EPSIZE    = 5
REFRESH   = 100    # Refresh rate of the console, in hertz
SCRAPE_E  = true   # Scrape episode scores
SCRAPE_L  = true  # Scrape level scores
TIMEOUT   = 5      # Seconds until score is retried
THREADS   = 10     # Concurrency, set to 1 to disable

CONFIG    = {
  'adapter'   => 'mysql2',
  'database'  => 'n',
  'pool'      => 2 * THREADS,
  'host'      => 'localhost',
  'username'  => 'root',
  'password'  => 'root',
  'encoding'  => 'utf8mb4',
  'collation' => 'utf8mb4_unicode_ci'
}

$count   = 0
$players = THREADS.times.map{ |t| nil }
$indices = THREADS.times.map{ |t| 0 } # ID being parsed by each thread
$time    = 0
$is_lvl  = true
$msg     = false

$count_mutex   = Mutex.new
$player_mutex  = Mutex.new
$indices_mutex = Mutex.new

# < -------------------------------------------------------------------------- >
# < ---                         DATABASE SETUP                             --- >
# < -------------------------------------------------------------------------- >

class Episode < ActiveRecord::Base
  has_many :levels
  has_many :scores, as: :highscoreable
end

class Level < ActiveRecord::Base
  belongs_to :episode
  has_many :scores, as: :highscoreable

  def self.find(ep, lvl)
    Level.where(id: EPSIZE * ep + lvl)[0]
  end

  def ep
    episode.id
  end

  def lvl
    id % 5
  end

  def format
    "#{"%02d" % ep}-#{lvl}"
  end
end

class Score < ActiveRecord::Base
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  has_one :demo

  def demo
    decode(Demo.where(id: self.id).first.demo.to_s)
  end
end

class Player < ActiveRecord::Base
  has_many :scores
end

class Demo < ActiveRecord::Base
  belongs_to :score
end

class Config < ActiveRecord::Base
end

def setup_db
  puts("Initializing database...")
  ActiveRecord::Base.establish_connection(CONFIG)
  ActiveRecord::Base.connection.create_table :episodes do |t|
  end
  ActiveRecord::Base.connection.create_table :levels do |t|
    t.references :episode, index: true
  end
  ActiveRecord::Base.connection.create_table :scores do |t|
    t.integer :score_id
    t.references :player, index: true
    t.references :highscoreable, polymorphic: true, index: true
    t.integer :rank, index: true
    t.integer :score
  end
  ActiveRecord::Base.connection.create_table :players do |t|
    t.string :name
  end
  ActiveRecord::Base.connection.create_table :demos do |t|
    #t.references :score
    t.text :demo
  end
  ActiveRecord::Base.connection.create_table :configs do |t|
    t.string :key
    t.string :value
  end
  Config.find_or_create_by(key: "level_start",   value: LEVEL_S)
  Config.find_or_create_by(key: "level_end",     value: LEVEL_E)
  Config.find_or_create_by(key: "episode_start", value: EPISODE_S)
  Config.find_or_create_by(key: "episode_end",   value: EPISODE_E)
  (0..EPISODES - 1).each{ |ep|
    e = Episode.find_or_create_by(id: ep)
    (0..EPSIZE - 1).each{ |lvl|
      Level.find_or_create_by(id: EPSIZE * ep + lvl).update(
        episode: e
      )
    }
  }
  Config.find_or_create_by(key: "initialized", value: 1)
end

# < -------------------------------------------------------------------------- >
# < ---                          SCRAPING CODE                             --- >
# < -------------------------------------------------------------------------- >

def _pack(n, size)
  n.to_s(16).rjust(2 * size, "0").scan(/../).map{ |b|
    [b].pack('H*')[0]
  }.join.force_encoding("ascii-8bit")
end

def _unpack(bytes)
  if bytes.is_a?(Array) then bytes = bytes.join end
  bytes.unpack('H*')[0].scan(/../).join.to_i(16)
end

# This code is used to encode and decode demos in a compressed manner.
# We can manage a tenfold compression!
def demo_encode(demo)
  framecount = demo.split(':')[0]
  bytes = demo.split(':')[1].split('|').map(&:to_i).map{ |frame|
    7.times.map{ |p|
      _pack(((frame % 16 ** (p + 1) - frame % 16 ** p).to_f / 16 ** p).round, 1)
    }
  }.flatten
  Base64.strict_encode64(Zlib::Deflate.deflate(framecount + ":" + bytes.join, 9))
end

def demo_decode(code)
  bytes = Zlib::Inflate.inflate(Base64.strict_decode64(code))
  framecount = bytes.split(':')[0]
  bytes = bytes.split(':')[1].scan(/./m)
  frames = bytes.each_slice(7).to_a.map{ |chunk|
    chunk.each_with_index.map{ |frame, i|
      _unpack(frame) * 16 ** i
    }.sum
  }.join('|')
  framecount + ':' + frames
end

def encode(demo)
  if demo.class == String
    COMPRESS ? demo_encode(demo) : demo
  elsif demo.class == Array
    COMPRESS ? demo.map{ |d| demo_encode(d) }.join('&') : demo.join('&')
  end
end

def decode(code)
  if code.index('&').nil?
    COMPRESS ? demo_decode(code) : demo
  else
    COMPRESS ? code.split('&').map{ |c| demo_decode(c) } : code.split('&')
  end
end

def download(id)
  attempts ||= 0
  Net::HTTP.post_form(
    URI.parse("http://www.harveycartel.org/metanet/n/data13/get_#{$is_lvl ? "lv" : "ep"}_demo.php"),
    pk: id
  ).body
rescue
  if (attempts += 1) < ATTEMPTS
    retry
  else
    nil
  end
end

def parse(i, id)
  attempts ||= 0
  ret = nil
  begin
    Timeout::timeout(TIMEOUT) do
      ret = download(id)
    end
  rescue Timeout::Error
    if (attempts += 1) < ATTEMPTS
      retry
    end
  end

  empty = $is_lvl ? EMPTY_L : EMPTY_E
  if ret.nil? || ret.size < empty then raise end
  if ret.size == empty then return 0 end
  s = Score.find_or_create_by(score_id: id, highscoreable_type: $is_lvl ? Level : Episode)
  $player_mutex.synchronize do
    $players[i] = Player.find_or_create_by(name: ret[/&name=(.*?)&demo/,1].to_s)
  end
  s.update(
    score: ret[/&score=(\d+)/,1].to_i,
    highscoreable_type: $is_lvl ? Level : Episode,
    highscoreable_id: ($is_lvl ? EPSIZE : 1) * ret[/&epnum=(\d+)/,1].to_i + ret[/&levnum=(\d+)/,1].to_i,
    player: $players[i]
  )
  Demo.find_or_create_by(id: s.id).update(
    demo: $is_lvl ? encode(ret[/&demo=(.*)&epnum=/,1].to_s) : encode(ret.scan(/demo\d+=(.*?)&/).map(&:first))
  )
  $count_mutex.synchronize do
    $count += 1
  end
  return 0
rescue => e
  return e
end

def msg
  index = 0
  while true
    if $msg
      min = $indices.min
      if min != index
        index = min
        print("Parsing score with ID #{index} / #{$is_lvl ? LEVEL_E : EPISODE_E}...".ljust(80, " ") + "\r")
      end
      sleep(1.0 / REFRESH)
    end
  end
end

def _scrap(type)
  nstart = Config.find_by(key: "#{type.downcase}_start").value.to_i || ($is_lvl ? LEVEL_S : EPISODE_S)
  nend = Config.find_by(key: "#{type.downcase}_end").value.to_i || ($is_lvl ? LEVEL_E : EPISODE_E)
  if nstart == nend then return 0 end
  $indices = THREADS.times.map{ |t| nstart }
  $msg = true

  Thread.new{ msg }
  threads = THREADS.times.map{ |i|
    Thread.new do
      (nstart..nend).each{ |id|
        if id % THREADS == i
          ret = parse(i, id)
          $indices_mutex.synchronize do
            $indices[i] = id
          end
          Config.find_by(key: "#{type.downcase}_start").update(value: $indices.min + 1)
          if ret != 0
            open('LOG', 'a') { |f|
              f.puts "[ERROR] [#{Time.now}] Score with ID #{id} failed to download."
            }
            puts("[ERROR] When parsing score with ID #{id} / #{$is_lvl ? LEVEL_E : EPISODE_E}...".ljust(80, " "))
          end
        end
      }
    end
  }
  threads.each(&:join)
  $msg = false
  Config.find_by(key: "#{type.downcase}_start").update(value: nend)
  return 0
rescue
  return 1
end

def scrap
  $time = Time.now
  $count = 0
  error = false
  if SCRAPE_L
    puts("Scraping levels.".ljust(80, " "))
    $is_lvl = true
    ret = _scrap("level")
    if ret != 0 then error = true end
  end
  if SCRAPE_E
    puts("Scraping episodes.".ljust(80, " "))
    $is_lvl = false
    ret = _scrap("episode")
    if ret != 0 then error = true end
  end
  if error
    puts("\r[ERROR] Scraping failed at some point.".ljust(80, " "))
  else
    puts("\r[INFO] Scraped #{$count} scores successfully in #{(Time.now - $time).round(3)} seconds.".ljust(80, " "))
  end
rescue Interrupt
  puts("\r[INFO] Scraper interrupted. Scrapped #{$count} scores in #{(Time.now - $time).round(3)} seconds.".ljust(80, " "))
rescue Exception
end

# < -------------------------------------------------------------------------- >
# < ---                             ANALYSIS                               --- >
# < -------------------------------------------------------------------------- >

def export(filename, content)
  File.write(filename, content)
  puts "Exported to '#{filename}' (#{content.length} bytes)."
end

def scores
  ep  = nil
  lvl = nil

  while ep.nil?  
    print("Episode > ")
    ep = STDIN.gets.chomp.to_i
    if ep < 0 || ep > 99
      puts "Episode should be between 0 and 99."
      ep = nil
    end
  end

  while lvl.nil?
    print("Level > ")
    lvl = STDIN.gets.chomp.to_i
    if lvl < 0 || lvl > 4
      puts "Level should be between 0 and 4."
      lvl = nil
    end
  end

  scores = Level.find(ep, lvl).scores.sort_by{ |s| -s.score }
  pad_rank  = scores.size.to_s.length
  pad_score = (scores[0].score.to_f / 40).to_i.to_s.length + 4

  File.write(
    "#{"%02d" % ep}-#{lvl}.txt",
    scores.each_with_index.map{ |s, i|
      "#{"%0#{pad_rank}d" % i} #{"%#{pad_score}.3f" % (s.score.to_f / 40)} #{s.player.name}"
    }.join("\n")
  )
  puts "Exported to \"#{"%02d" % ep}-#{lvl}.txt\""
end

def completions
  values = Level.all.map{ |l|
    print("Parsing level #{l.format}...".ljust(80, " ") + "\r")
    [l.scores.size, l.format]
  }.sort_by{ |count, l| -count }
  pad = values[0][0].to_s.length
  content = values.map{ |count, l| "#{"%0#{pad}d" % count} #{l}" }.join("\n")
  export("count.txt", content)
end

# < -------------------------------------------------------------------------- >
# < ---                             STARTUP                                --- >
# < -------------------------------------------------------------------------- >

def setup
  ActiveRecord::Base.establish_connection(CONFIG)
  if Config.find_by(key: "initialized").value.to_i != 1 then setup_db end
  Config.find_or_create_by(key: "level_end").update(value: LEVEL_E)
  Config.find_or_create_by(key: "episode_end").update(value: EPISODE_E)
rescue ActiveRecord::ActiveRecordError
  setup_db
rescue
  return 1
end

def reset
  Config.find_or_create_by(key: "level_start").update(value: LEVEL_S)
  Config.find_or_create_by(key: "level_end").update(value: LEVEL_E)
  Config.find_or_create_by(key: "episode_start").update(value: EPISODE_S)
  Config.find_or_create_by(key: "episode_end").update(value: EPISODE_E)
end

def cls
  print("".ljust(80, " ") + "\r")
end

def help
  puts "DESCRIPTION: A tool to scrape N v1.4 scores and analyze them."
  puts "USAGE: ruby nscrap.rb [ARGUMENT]"
  puts "ARGUMENTS:"
  puts "  scrape - Scrapes the server and seeds the database."
  puts "   reset - Resets database config values (e.g. to scrape a-fresh)"
  puts "  scores - Show score leaderboard for a specific episode or level."
  puts "   count - Sorts levels by number of completions."
  puts "    exit - Exit the program."
  puts "NOTES:"
  puts "  * MySQL with a database named '#{CONFIG['database']}' is needed."
end

def main
  puts("[INFO] N Scraper initialized (Using #{THREADS} threads).")
  setup
  puts("[INFO] Connection to database established.")

  command = (ARGV.size == 0 ? nil : ARGV[0])

  loop do
    if command.nil?
      cls
      print("Command > ")
      command = STDIN.gets.chomp
    end
    if !["scrape", "reset", "scores", "count", "exit", "quit"].include?(command)
      help
      command = nil
      next
    end
    if ["exit", "quit"].include?(command)
      return
    end
    case command
      when "scrape"
        scrap
      when "scores"
        scores
      when "count"
        completions
      when "reset"
        reset
      else
        help
    end
    command = nil
  end
rescue Interrupt
rescue
end

main
