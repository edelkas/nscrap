# Modules
require 'net/http'
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
CONFIG    = {
  'adapter'   => 'mysql2',
  'database'  => 'n',
  'host'      => 'localhost',
  'username'  => 'root',
  'password'  => 'root',
  'encoding'  => 'utf8mb4',
  'collation' => 'utf8mb4_unicode_ci'
}

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
    t.references :score
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

def parse(id)
  ret = download(id)
  if ret.nil? || ret.size < EMPTYSIZE then raise end
  if ret.size == EMPTYSIZE then return 0 end
  s = Score.find_or_create_by(id: id)
  s.update(
    score: ret[/&score=(\d+)/,1].to_i,
    highscoreable_type: Level,
    highscoreable_id: EPSIZE * ret[/&epnum=(\d+)/,1].to_i + ret[/&levnum=(\d+)/,1].to_i,
    player: Player.find_or_create_by(name: ret[/&name=(.*)&demo=/,1].to_s)
  )
  Demo.find_or_create_by(id: id).update(
    score: s,
    demo: ret[/&demo=(.*)&epnum=/,1].to_s
  )
  return 0
#rescue
#  open('LOG', 'a') { |f|
#    f.puts "[ERROR] [#{Time.now}] Score with ID #{id} failed to download."
#  }
#  return 1
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

def scrap
  nstart = Config.find_by(key: "start").value.to_i || NSTART
  nend = Config.find_by(key: "end").value.to_i || NEND
  (nstart..nend).each{ |id|
    print("Parsing score with ID #{id} / #{NEND}...".ljust(80, " ") + "\r")
    ret = parse(id)
    Config.find_by(key: "start").update(value: id + 1)
    if ret == 1
      puts("[ERROR] When parsing score with ID #{id} / #{NEND}...".ljust(80, " ") + "\r")
    end
  }
  return nend - nstart
rescue
  return -2 # -1 means the scrap finished!
end

def startup
  puts("N Scrapper initialized.")
  setup
  puts("Connection to database established.")
  ret = scrap
  ret == -2 ? puts("Scrapping failed at some point.") : puts("Scrapped #{ret + 1} scores successfully.")
rescue Exception
end

startup
