require "../spec_helper"

Spectator.describe Rosegold::Bot do
  it "should fall due to gravity" do
    client.join_game do |client|
      Rosegold::Bot.new(client).try do |bot|
        sleep 2 # load chunks
        bot.chat "/tp 1 -58 1"
        sleep 1 # teleport
        until client.player.on_ground?
          bot.wait_tick
        end
        expect(bot.feet).to eq(Rosegold::Vec3d.new(1.5, -60, 1.5))
      end
    end
  end

  it "can move to location successfully" do
    client.join_game do |client|
      Rosegold::Bot.new(client).try do |bot|
        sleep 2 # load chunks
        bot.chat "/tp 1 -60 1"
        sleep 1 # teleport

        bot.move_to 2, 2
        expect(bot.feet).to eq(Rosegold::Vec3d.new(2, -60, 2))

        bot.move_to -1, -1
        expect(bot.feet).to eq(Rosegold::Vec3d.new(-1, -60, -1))
      end
    end
  end

  it "should change yaw and pitch" do
    client.join_game do |client|
      Rosegold::Bot.new(client).try do |bot|
        bot.chat "/tp 1 -60 1"

        bot.yaw = 45
        bot.pitch = 45
        expect(bot.yaw).to be_close(45, 0.1)
        expect(bot.pitch).to be_close(45, 0.1)

        bot.yaw = 90
        bot.pitch = 90
        expect(bot.yaw).to be_close(90, 0.1)
        expect(bot.pitch).to be_close(90, 0.1)
      end
    end
  end

  it "should jump and fall" do
    client.join_game do |client|
      Rosegold::Bot.new(client).try do |bot|
        sleep 2 # load chunks
        bot.chat "/tp 1 -60 1"
        sleep 1 # teleport

        initial_feet = bot.feet

        bot.start_jump
        sleep 0.5 # allow time for the jump

        expect(bot.feet.y).to be > initial_feet.y

        until client.player.on_ground?
          bot.wait_tick
        end

        expect(bot.feet.y).to be_close(initial_feet.y, 0.1)
      end
    end
  end

  it "should select a different hotbar slot" do
    client.join_game do |client|
      Rosegold::Bot.new(client).try do |bot|
        bot.chat "/tp 1 -60 1"

        bot.hotbar_selection = 4
        expect(bot.hotbar_selection).to eq 4

        bot.hotbar_selection = 7
        expect(bot.hotbar_selection).to eq 7
      end
    end
  end
end
