# Note: The ID of each score and demo is the pkey in Metanet's server.

# Modules
require 'net/http'
require 'timeout'
# Gems
require 'nokogiri'
require 'active_record'

NSTART    = 1
NEND      = 400000
EMPTYSIZE = 46
EPISODES  = 100
EPSIZE    = 5 # Per episode
ATTEMPTS  = 10
THREADS   = 10
TIMEOUT   = 5 # Seconds
REFRESH   = 100 # Hertz
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
end

class Score < ActiveRecord::Base
  belongs_to :player
  belongs_to :highscoreable, polymorphic: true
  has_one :demo

  def demo
    Demo.where(id: self.id).first.demo.to_s
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
  ActiveRecord::Base.establish_connection(CONFIG)
  ActiveRecord::Base.connection.create_table :episodes do |t|
  end
  ActiveRecord::Base.connection.create_table :levels do |t|
    t.references :episode, index: true
  end
  ActiveRecord::Base.connection.create_table :scores do |t|
    # We use the pkey as the ID
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
  Config.find_or_create_by(key: "start", value: NSTART)
  Config.find_or_create_by(key: "end", value: NEND)
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

def download(id)
  attempts ||= 0
  Net::HTTP.post_form(URI.parse("http://www.harveycartel.org/metanet/n/data13/get_lv_demo.php"), pk: id).body
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

  if ret.nil? || ret.size < EMPTYSIZE then raise end
  if ret.size == EMPTYSIZE then return 0 end
  s = Score.find_or_create_by(id: id)
  $player_mutex.synchronize do
    $players[i] = Player.find_or_create_by(name: ret[/&name=(.*)&demo=/,1].to_s)
  end
  s.update(
    score: ret[/&score=(\d+)/,1].to_i,
    highscoreable_type: Level,
    highscoreable_id: EPSIZE * ret[/&epnum=(\d+)/,1].to_i + ret[/&levnum=(\d+)/,1].to_i,
    player: $players[i]
  )
  Demo.find_or_create_by(id: id).update(
    demo: ret[/&demo=(.*)&epnum=/,1].to_s
  )
  $count_mutex.synchronize do
    $count += 1
  end
  return 0
rescue => e
  return e
end

# < -------------------------------------------------------------------------- >
# < ---                             STARTUP                                --- >
# < -------------------------------------------------------------------------- >

def setup
  ActiveRecord::Base.establish_connection(CONFIG)
  if Config.find_by(key: "initialized").value.to_i != 1 then setup_db end
  Config.find_or_create_by(key: "end").update(value: NEND)
rescue ActiveRecord::ActiveRecordError
  setup_db
end

def msg
  index = 0
  while true
    min = $indices.min
    if min != index
      index = min
      print("Parsing score with ID #{index} / #{NEND}...".ljust(80, " ") + "\r")
    end
    sleep(1.0 / REFRESH)
  end
end

def _scrap
  nstart = Config.find_by(key: "start").value.to_i || NSTART
  nend = Config.find_by(key: "end").value.to_i || NEND
  $indices = THREADS.times.map{ |t| nstart }

  Thread.new{ msg }
  threads = THREADS.times.map{ |i|
    Thread.new do
      (nstart..nend).each{ |id|
        if id % THREADS == i
          ret = parse(i, id)
          $indices_mutex.synchronize do
            $indices[i] = id
          end
          Config.find_by(key: "start").update(value: $indices.min + 1)
          if ret != 0
            open('LOG', 'a') { |f|
              f.puts "[ERROR] [#{Time.now}] Score with ID #{id} failed to download."
            }
            puts("[ERROR] When parsing score with ID #{id} / #{NEND}...".ljust(80, " "))
          end
        end
      }
    end
  }
  threads.each(&:join)
  return 0
rescue
  return 1
end

def scrap
  $time = Time.now
  ret = _scrap
  ret != 0 ? print("[ERROR] Scrapping failed at some point.".ljust(80, " ")) : print("[INFO] Scrapped #{$count} scores successfully.".ljust(80, " "))
rescue Interrupt
  puts("\r[INFO] Scrapper interrupted. Scrapped #{$count} scores in #{(Time.now - $time).round(3)} seconds.".ljust(80, " "))
rescue Exception
end

def startup
  puts("[INFO] N Scrapper initialized (Using #{THREADS} threads).")
  setup
  puts("[INFO] Connection to database established.")
  if ARGV.size == 0
    # Put command menu here
  else
    # Put a switch between the different commands here using ARGV[0]
    # If it doesn't exist, print help.
  end
end

def demo
  print Score.where(id: 42).first.demo
end

startup
scrap
#demo
