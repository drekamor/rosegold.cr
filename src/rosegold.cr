require "dotenv"
require "socket"
require "io/hexdump"

Dotenv.load

require "./rosegold/client"
require "./rosegold/bot"

# TODO: Write documentation for `Rosegold`
module Rosegold
  VERSION = "0.1.0"

  Log.setup_from_env

  # TODO: Put your code here
end
