require 'yaml'
require 'logger'
require 'rcon'
require 'csv'
require 'fileutils'

# RCON Call
def rcon_exec(command)
    begin
        if command == "ShowPlayers"
            $logger.debug("Sending command: '#{command}'")
        else
            $logger.info("Sending command: '#{command}'")
        end
        
        return $client.execute(command)
    rescue
        $logger.error("Failed to execute RCON Command: '#{command}'")
        $logger.warn("Attempting to reconnect to PalServer RCON.")
        rcon_reconnect
        return nil
    end
end

# Reconnect in case of connect failure
def rcon_reconnect
    begin
        $client.authenticate!(ignore_first_packet: false)
        $logger.info("Successfully connected to PalServer RCON.")
        return true
    rescue
        $logger.error("Failed to connect to PalServer")
        return false
    end
end

# Initialize logging
$logger = Logger.new("watchdog.log")
$logger.level = Logger::INFO

# Load Cofiguration
config = YAML.load_file('config.yml')
$logger.info("Loaded PalPal configuration.")

# Initialize RCON
$logger.info("Initializing RCON connection.")
$client = Rcon::Client.new(host: "127.0.0.1", port: config["RconPort"], password: config["RconPassword"])
while !rcon_reconnect
    sleep config["WatchdogInterval"]
end

# Watchdog loop
$logger.info("Entering Watchdog Loop.")
player_list = nil
# The \xA0\x80 stuff is a janky hack to work around the fact that you can't usually put spaces in broadcast messages
rcon_exec("Broadcast PalPal\xA0\x80is\xA0\x80now\xA0\x80watching\xA0\x80this\xA0\x80Server.")
loop do
    # Wait a bit so we don't blast the server
    unless player_list.nil?
        sleep config["WatchdogInterval"]
    end

    # Get player list
    player_response = rcon_exec("ShowPlayers")
    if player_response.nil?
        $logger.warn("Skipping watchdog run due to RCON connection failure.")
        next
    end

    new_player_list = CSV.parse(player_response.body, headers: true, encoding: "UTF-8")
    if player_list.nil?
        # Handle first loop run
        player_list = new_player_list
    else
        # Determine difference between player lists (bit janky this section, maybe refactor at some point)
        players_joined = []
        players_left = []

        player_list.each do |player|
            present = true
            new_player_list.each do |nplayer|
                if nplayer["steamid"] == player["steamid"]
                    present = false
                end
            end
            if present
                players_left.push(player)
            end
        end

        new_player_list.each do |nplayer|
            present = true
            player_list.each do |player|
                if nplayer["steamid"] == player["steamid"]
                    present = false
                end
            end
            if present
                players_joined.push(nplayer)
            end
        end

        # Broadcast join messages
        if config["JoinBroadcast"]
            players_joined.each do |jplayer|
                $logger.info("Detected Player Join: #{jplayer.inspect}")
                rcon_exec("Broadcast #{jplayer["name"].gsub(" ", "\xA0\x80")}\xA0\x80joined\xA0\x80the\xA0\x80world.")
            end
        end

        # Broadcast leave messages
        if config["LeaveBroadcast"]
            players_left.each do |lplayer|
                $logger.info("Detected Player Leave: #{lplayer.inspect}")
                rcon_exec("Broadcast #{lplayer["name"].gsub(" ", "\xA0\x80")}\xA0\x80left\xA0\x80the\xA0\x80world.")
            end
        end

        # Handle Whitelist
        if config["Whitelist"]["Enable"]
            compare_list = players_joined
            if config["Whitelist"]["RetroactiveKick"]
                # Check all players against whitelist instead of only recently joined players
                compare_list = new_player_list
            end

            compare_list.each do |player|
                is_whitelisted = false
                # Check Steam IDs
                config["Whitelist"]["SteamIDs"].each do |steamid|
                    if player["steamid"] == steamid
                        is_whitelisted = true
                    end
                end
                # Check Player UIDs (if UID list is defined)
                if defined? config["Whitelist"]["PlayerUIDs"]
                    config["Whitelist"]["PlayerUIDs"].each do |playeruid|
                        if player["playeruid"] == playeruid
                            is_whitelisted = true
                        end
                    end
                end
                # Kick player if they're not whitelisted
                unless is_whitelisted
                    rcon_exec("KickPlayer #{player["steamid"]}")
                    rcon_exec("Broadcast Kicked\xA0\x80non-whitelisted\xA0\x80player\xA0\x80#{player["name"].gsub(" ", "\xA0\x80")}.")
                    $logger.warn("Kicked non-whitelisted player: #{player.inspect}")
                end
            end
        end

        # Update Player List
        player_list = new_player_list
    end

