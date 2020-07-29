# Modules
require 'net/http'
# Gems
require 'nokogiri'
require 'active_record'

NSTART = 1
NEND = 400000
ATTEMPTS = 10
CONFIG = {
  'adapter'  => 'mysql2',
  'database' => 'n',
  'host' => 'localhost',
  'username' => 'root',
  'password' => 'root',
  'encoding' => 'utf8mb4',
  'collation' => 'utf8mb4_unicode_ci'
}

class Episode < ActiveRecord::Base
  has_many :levels
  has_many :scores, as :highscoreable
end

class Level < ActiveRecord::Base
  belongs_to :episode
  has_many :scores, as :highscoreable
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

def setup_db
  ActiveRecord::Base.establish_connection(
    :adapter  => CONFIG['adapter'],
    :database => CONFIG['database']
  )
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
  Config.create(key: "start", value: NSTART)
  Config.create(key: "end", value: NEND)
end

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

def setup
  if !File.file?(CONFIG['database'])
    setup_db
  else
    ActiveRecord::Base.establish_connection(
      :adapter  => CONFIG['adapter'],
      :database => CONFIG['database']
    )
  end
end

def parse
  parse_forums # Creates Forum and Topic objects
  parse_topics # Creates Topic, Post and User objects
  parse_users
end

setup

parse_forums

#parse
